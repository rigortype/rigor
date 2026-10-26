# frozen_string_literal: true

# Issue #2104 — the callee-chain census is memoised across evaluators, keyed by the def table and the class self-calls
# resolve in (`StatementEvaluator#resolved_census`). A run builds hundreds of thousands of evaluators, and with only a
# per-evaluator memo #2295 recomputed each closure about thirty times over. While a dependency recorder is active the
# memo is bypassed, so a resolution the closure makes still records its ADR-46 read in the file being analysed.

require "spec_helper"
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
  RSpec.describe "the callee-chain census memo's discovery key and lifetime (#2330)" do
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
    let(:override_source) { "class Mut\n  def stripes(acc) = 1\nend\n" }

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

    it "answers the second per-file discovery's override, not the first discovery's memoised callee" do
      first = floored_for(caller_source)
      second = floored_for("#{caller_source}\n#{override_source}")

      expect(first.map(&:name)).to eq([:acc])
      expect(second).to eq([])
    end

    it "freezes the per-file def table and its per-class tables" do
      scope, = per_file("#{caller_source}\n#{override_source}")

      expect(scope.discovered_def_nodes).to be_frozen
      expect(scope.discovered_def_nodes.values).to all(be_frozen)
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
