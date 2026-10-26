# frozen_string_literal: true

# Issue #2104 — the callee-chain census is memoised across evaluators, keyed by the def table and the class self-calls
# resolve in (`StatementEvaluator#resolved_census`). A run builds hundreds of thousands of evaluators, and with only a
# per-evaluator memo #2295 recomputed each closure about thirty times over. While a dependency recorder is active the
# memo is bypassed, so a resolution the closure makes still records its ADR-46 read in the file being analysed.

require "spec_helper"
require "weakref"
require "rigor/analysis/dependency_recorder"

RSpec.describe "the callee-chain census memo (#2104)" do
  # `run` hands `acc` to `stripes`, which hands it on to `ghost`, which no file defines: the closure over `stripes`
  # resolves `ghost` and finds nothing, which a recorder files as a missing method.
  let(:source) do
    <<~RUBY
      class Mut
        def run(acc)
          stripes(acc)
        end

        def stripes(acc) = ghost(acc)
      end
    RUBY
  end
  let(:program) { Prism.parse(source).value }
  let(:index) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty) }
  let(:call) do
    found = nil
    Rigor::Source::NodeWalker.each(program) do |node|
      found ||= node if node.is_a?(Prism::CallNode) && node.name == :stripes
    end
    found
  end

  def floored_arguments
    Rigor::Inference::StatementEvaluator.new(scope: index[call]).content_mutated_arguments(call)
  end

  it "closes a def once for every evaluator that reads it" do
    allow(Rigor::Inference::CalleeMutationChain).to receive(:close).and_call_original

    expect(floored_arguments).to eq([])
    expect(floored_arguments).to eq([])
    expect(Rigor::Inference::CalleeMutationChain).to have_received(:close).once
  end

  it "still records the closure's resolutions in a recording window after the memo was filled outside one" do
    expect(floored_arguments).to eq([])

    record = Rigor::Analysis::DependencyRecorder.record_for("lib/mut.rb") { floored_arguments }

    expect(record.missing).to include("method:Mut#ghost")
  end

  # Issue #2330 — the memo is keyed by the whole `DiscoveryIndex`, and the slot it fills is released when a run ends.
  describe "discovery key and lifetime (#2330)" do
    let(:caller_source) do
      <<~RUBY
        class Mut
          def run(acc)
            stripes(acc)
          end
        end
      RUBY
    end
    let(:seed_source) { "class Mut\n  def stripes(acc) = acc << 1\nend\n" }
    let(:override_source) { "class Mut\n  def stripes(acc) = 1\n  def self.helper = 1\nend\n" }

    def seed_scope
      program = Prism.parse(seed_source).value
      Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)[program]
    end

    def per_file(source)
      program = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: seed_scope)
      call = nil
      Rigor::Source::NodeWalker.each(program) do |node|
        call ||= node if node.is_a?(Prism::CallNode) && node.name == :stripes
      end
      [index[call], call]
    end

    def floored_for(source)
      scope, call = per_file(source)
      Rigor::Inference::StatementEvaluator.new(scope: scope).content_mutated_arguments(call)
    end

    it "answers each discovery's own callee for one shared caller" do
      program = Prism.parse(<<~RUBY).value
        class Mut
          def run(acc) = fwd(acc)
          def fwd(acc) = stripes(acc)
        end
      RUBY
      call = nil
      Rigor::Source::NodeWalker.each(program) do |node|
        call ||= node if node.is_a?(Prism::CallNode) && node.name == :stripes
      end
      fwd_call = nil
      Rigor::Source::NodeWalker.each(program) do |node|
        fwd_call ||= node if node.is_a?(Prism::CallNode) && node.name == :fwd
      end
      answers = ["def stripes(acc) = acc << 1", "def stripes(acc) = 1"].map do |seed_def|
        seed_program = Prism.parse("class Mut\n  #{seed_def}\nend\n").value
        seed = Rigor::Inference::ScopeIndexer.index(seed_program, default_scope: Rigor::Scope.empty)[seed_program]
        index = Rigor::Inference::ScopeIndexer.index(program, default_scope: seed)
        Rigor::Inference::StatementEvaluator.new(scope: index[fwd_call]).content_mutated_arguments(fwd_call)
                                            .map(&:name)
      end

      expect(answers).to eq([[:acc], []])
    end

    it "does not keep a discovery alive through the memo it filled, whichever entry point filled it" do
      probe = lambda do
        scope, call = per_file(caller_source)
        supers = scope.discovery.discovered_superclasses.dup
        derived = scope.with_discovery(scope.discovery.with(discovered_superclasses: supers))
        Rigor::Inference::StatementEvaluator.new(scope: derived).content_mutated_arguments(call)
        WeakRef.new(derived.discovery)
      end
      ref = probe.call
      expect(Thread.current[:rigor_callee_resolved_census]).to be_a(ObjectSpace::WeakKeyMap)

      # The other per-thread memos key on the index too (one slot each); drop them so only the census can hold it.
      Thread.current.keys.grep(/rigor/).each do |key|
        Thread.current[key] = nil unless key == :rigor_callee_resolved_census
      end
      5.times { GC.start }

      expect(ref).not_to be_weakref_alive
    end

    it "freezes the per-file def table and its per-class tables" do
      scope, = per_file("#{caller_source}\n#{override_source}")

      expect(scope.discovered_def_nodes).to be_frozen
      expect(scope.discovered_def_nodes.values).to all(be_frozen)
      expect(scope.discovered_singleton_def_nodes).to be_frozen
      expect(scope.discovered_singleton_def_nodes.values).to all(be_frozen)
    end

    it "empties the thread slot when a run ends" do
      floored_for(caller_source)
      expect(Thread.current[:rigor_callee_resolved_census]).not_to be_nil

      Dir.mktmpdir do |dir|
        path = File.join(dir, "mut.rb")
        File.write(path, "#{seed_source}#{caller_source}")
        runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => [path]),
                                             cache_store: nil)
        guarded_run(runner, [path])
      end

      expect(Thread.current[:rigor_callee_resolved_census]).to be_nil
    end
  end
end
