# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 recording runs serve three memos the recorder once forced them to bypass: the two
# `RbsDispatch` ancestor-dispatch memos, which store only answers whose computation recorded nothing,
# and `Reflection`'s constant-ancestor walk, which replays the walk's class edges on a hit. A memo that
# swallowed an edge would under-record, and a replay in the wrong order would change the snapshot, so
# this pins the recorded dependencies of a memoised run to those of a run that recomputes every answer,
# record for record, in order and byte for byte.
RSpec.describe "ADR-46 recording through the dispatch and constant-ancestor memos" do
  let(:dispatch) { Rigor::Inference::MethodDispatcher::RbsDispatch }

  # `Bag` reaches the core-ancestor arm and `Box` the included-module arm, each once with a declaration
  # (whose probes record an edge) and once without (which records nothing). `Child`'s core-constant reads
  # miss lexically and walk the constant ancestry. `consumer.rb` asks each question from two methods, so
  # two capture windows see it, and `consumer2.rb` replays one of them.
  let(:fixture) do
    {
      "bag.rb" => "class Bag < Hash\nend\n",
      "box.rb" => "class Box\n  include Comparable\n\n  def <=>(other) = 0\nend\n",
      "base.rb" => "class Base\n  LIMIT = 3\nend\n",
      "child.rb" => "class Child < Base\n  def a = [Integer, LIMIT]\n  def b = [String, LIMIT]\nend\n",
      "consumer.rb" => <<~RUBY,
        class Consumer
          def one
            Bag.new.fetch(:k)
            Bag.new.no_such_method_here
            Box.new.clamp(1, 2)
            Box.new.no_such_method_here
            Child.new.a
          end

          def two
            Bag.new.fetch(:k)
            Bag.new.no_such_method_here
            Box.new.clamp(1, 2)
            Box.new.no_such_method_here
            Child.new.b
          end
        end
        Consumer.new.one
        Consumer.new.two
      RUBY
      "consumer2.rb" => "Consumer.new.two\nChild.new.b\n"
    }
  end

  def run_recording(dir, memo:)
    counts = Hash.new(0)
    count_computations(counts)
    recompute_every_answer unless memo
    runner = Rigor::Analysis::Runner.new(
      configuration: Rigor::Configuration.new("paths" => [dir]), cache_store: nil, record_dependencies: true
    )
    result = guarded_run(runner)
    [runner, result, counts]
  end

  def count_computations(counts)
    targets = { dispatch => %i[compute_core_stdlib_ancestor_method compute_included_module_method],
                Rigor::Reflection => %i[compute_ancestor_constant_scopes] }
    targets.each do |owner, names|
      names.each do |name|
        allow(owner).to receive(name).and_wrap_original do |original, *args|
          counts[name] += 1
          original.call(*args)
        end
      end
    end
  end

  # What a recording run did before the memos were opened to it: every answer is recomputed.
  def recompute_every_answer
    allow(dispatch).to(receive(:store_unless_recorded).and_wrap_original { |_original, *, &block| block.call })
    allow(Rigor::Reflection).to receive(:recorded_ancestor_constant_scopes)
      .and_wrap_original do |_original, class_name, scope|
        Rigor::Reflection.send(:compute_ancestor_constant_scopes, class_name, scope)
      end
  end

  def recorded(runner)
    runner.file_dependencies.sort.to_h do |path, record|
      [path, [record.sources, record.symbol_sources, record.ancestry_sources, record.missing]]
    end
  end

  # Sets and Hashes as Arrays, so the comparison sees insertion order, which the snapshot keeps.
  def ordered(value)
    case value
    when Hash then value.map { |key, inner| [key, ordered(inner)] }
    when Set then value.to_a
    when Array then value.map { |inner| ordered(inner) }
    else value
    end
  end

  it "records what recomputing every answer records, in the same order" do
    Dir.mktmpdir do |dir|
      fixture.each { |name, source| File.write(File.join(dir, name), source) }
      memo_runner, memo_result, memo_counts = run_recording(dir, memo: true)
      bare_runner, bare_result, bare_counts = run_recording(dir, memo: false)

      # The memos served answers: each computation ran fewer times than without them.
      expect(memo_counts.keys).to contain_exactly(:compute_core_stdlib_ancestor_method,
                                                  :compute_included_module_method,
                                                  :compute_ancestor_constant_scopes)
      memo_counts.each { |name, count| expect(count).to be < bare_counts[name], name.to_s }

      # And the edges they guard were recorded: the ancestry probes read bag.rb and box.rb, and the
      # constant walk read base.rb, for the file that analysed them and for the one that replays `two`.
      consumer = memo_runner.file_dependencies.fetch(File.join(dir, "consumer.rb"))
      expect(consumer.ancestry_sources).to include(File.join(dir, "bag.rb"), File.join(dir, "box.rb"))
      replaying = memo_runner.file_dependencies.fetch(File.join(dir, "consumer2.rb"))
      expect(replaying.ancestry_sources).to include(File.join(dir, "bag.rb"), File.join(dir, "base.rb"))

      memo_recorded = recorded(memo_runner)
      bare_recorded = recorded(bare_runner)
      expect(ordered(memo_recorded)).to eq(ordered(bare_recorded))
      # And byte for byte, the form the snapshot stores them in.
      expect(Marshal.dump(memo_recorded)).to eq(Marshal.dump(bare_recorded))
      expect(memo_result.diagnostics.map(&:to_h)).to eq(bare_result.diagnostics.map(&:to_h))
    end
  end

  # The same two memos asked directly, where nothing else in the window files the edge the memo guards: a
  # project run nearly always reaches these answers after a user-side ancestry walk that already filed it,
  # so the run-level comparison above cannot tell a memo that swallows an edge from one that does not.
  describe "asked directly" do
    let(:recorder) { Rigor::Analysis::DependencyRecorder }
    let(:environment) do
      loader = Rigor::Environment::RbsLoader.new(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES, signature_paths: [],
        cache_store: RunnerHelpers.shared_cache_store
      )
      Rigor::Environment.new(rbs_loader: loader)
    end
    let(:scope) do
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        discovered_superclasses: { "SubHash" => "Hash", "Child" => "Base", "Base" => "Object" },
        discovered_class_sources: { "SubHash" => ["app/sub_hash.rb:1"], "Child" => ["app/child.rb:1"],
                                    "Base" => ["app/base.rb:1"] }
      )
      Rigor::Scope.empty(environment: environment).with_discovery(index)
    end

    def ask(method_name)
      dispatch.send(:core_stdlib_ancestor_method, environment, "SubHash", :instance, method_name, scope)
    end

    it "recomputes a dispatch answer that filed an edge, so a later window files it too" do
      allow(dispatch).to receive(:compute_core_stdlib_ancestor_method).and_call_original
      window = nil
      recorder.record_for("app/reader.rb") do
        expect(ask(:has_key?)).not_to be_nil
        _, window = recorder.capture { ask(:has_key?) }
      end

      expect(window.reads).to include(["app/sub_hash.rb", nil])
      expect(dispatch).to have_received(:compute_core_stdlib_ancestor_method).twice
    end

    it "serves a dispatch answer that filed nothing from the memo" do
      allow(dispatch).to receive(:compute_core_stdlib_ancestor_method).and_call_original
      window = nil
      recorder.record_for("app/reader.rb") do
        expect(ask(:no_such_method_anywhere)).to be_nil
        _, window = recorder.capture { ask(:no_such_method_anywhere) }
      end

      expect(window.reads).to be_empty
      expect(window.missing).to be_empty
      expect(dispatch).to have_received(:compute_core_stdlib_ancestor_method).once
    end

    it "replays the constant walk's class edges on a memo hit, in walk order" do
      allow(Rigor::Reflection).to receive(:compute_ancestor_constant_scopes).and_call_original
      window = nil
      recorder.record_for("app/reader.rb") do
        expect(Rigor::Reflection.send(:ancestor_constant_scopes, "Child", scope)).to eq(["Base"])
        _, window = recorder.capture { Rigor::Reflection.send(:ancestor_constant_scopes, "Child", scope) }
      end

      expect(window.reads.to_a).to eq([["app/child.rb", nil], ["app/base.rb", nil]])
      expect(Rigor::Reflection).to have_received(:compute_ancestor_constant_scopes).once
    end
  end
end
