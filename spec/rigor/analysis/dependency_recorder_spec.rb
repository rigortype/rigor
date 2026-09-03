# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 1 — the cross-file dependency recorder. Verifies that analysing a file records the OTHER files its
# inference read from; `Incremental.invert` builds the `dependents` index from these records and the body tier
# re-analyses only the affected closure.
RSpec.describe Rigor::Analysis::DependencyRecorder do
  def run_recording(dir)
    configuration = Rigor::Configuration.new("paths" => [dir])
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil, record_dependencies: true
    )
    guarded_run(runner)
    runner
  end

  it "records the defining file as a dependency of the calling file" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), <<~RUBY)
        class Widget
          def price
            100
          end
        end
      RUBY
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "caller.rb")]

      expect(record).not_to be_nil
      # caller.rb's inference resolved Widget#price through to its body in model.rb, so model.rb is a recorded
      # dependency.
      expect(record.sources).to include(File.join(dir, "model.rb"))
      # A file does not depend on itself.
      expect(record.sources).not_to include(File.join(dir, "caller.rb"))
    end
  end

  it "records the superclass-defining file as a dependency (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), <<~RUBY)
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "child.rb"), <<~RUBY)
        class Child < Base
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "child.rb")]

      # Resolving Child's `greet` walks the superclass chain through `superclass_of(Child)` and reads Base#greet's body
      # — both edges attribute to base.rb.
      expect(record.sources).to include(File.join(dir, "base.rb"))
    end
  end

  it "records a mixed-in module's file as a dependency (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "mixin.rb"), <<~RUBY)
        module Greeter
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "host.rb"), <<~RUBY)
        class Host
          include Greeter
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "host.rb")]

      # Resolving `greet` against the include chain reads `includes_of(Host)` and Greeter#greet's body — both attribute
      # to mixin.rb.
      expect(record.sources).to include(File.join(dir, "mixin.rb"))
    end
  end

  it "records every reopening file of a class whose ancestry is read (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      # `Account` is declared empty in one file and reopened with its superclass in another. A consumer that resolves an
      # inherited method depends on BOTH files — removing the superclass in the reopening must re-check the consumer, so
      # `superclass_of(Account)` records the full declaring-file set, not just the first declaration.
      File.write(File.join(dir, "account_decl.rb"), "class Account\nend\n")
      File.write(File.join(dir, "account_super.rb"), <<~RUBY)
        class Base
          def role
            "member"
          end
        end
        class Account < Base
        end
      RUBY
      File.write(File.join(dir, "consumer.rb"), <<~RUBY)
        class Account
          def whoami
            role
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "consumer.rb")]

      # The reopening that carries the superclass edge is a recorded source.
      expect(record.sources).to include(File.join(dir, "account_super.rb"))
      # And the empty earlier declaration, surfaced by the class-source set.
      expect(record.sources).to include(File.join(dir, "account_decl.rb"))
    end
  end

  it "inverts recorded sources into a dependents index (ADR-46 §2)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), <<~RUBY)
        class Widget
          def price
            100
          end
        end
      RUBY
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      dependents = runner.file_dependents

      # An edit to model.rb must re-check caller.rb (it read Widget#price's body from there), so caller.rb is a
      # dependent of model.rb.
      expect(dependents[File.join(dir, "model.rb")]).to include(File.join(dir, "caller.rb"))
      # A file no one reads from has no dependents entry (nil, not a mutable default — the frozen index dropped its
      # default proc).
      expect(dependents[File.join(dir, "caller.rb")]).to be_nil
    end
  end

  it "records a negative edge for an unresolved cross-class method call" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Widget\nend\n")
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "caller.rb")]

      expect(record.missing).to include("method:Widget#price")
    end
  end

  # ADR-46 slice 4 — symbol-granularity tracking.
  it "records method-call deps in symbol_sources (not ancestry_sources)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), <<~RUBY)
        class Widget
          def price
            100
          end
        end
      RUBY
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "caller.rb")]

      model = File.join(dir, "model.rb")
      expect(record.symbol_sources[model]).to include("Widget#price")
      expect(record.ancestry_sources).not_to include(model)
    end
  end

  it "records superclass-of reads in ancestry_sources (file-level)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), <<~RUBY)
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "child.rb"), <<~RUBY)
        class Child < Base
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "child.rb")]

      base = File.join(dir, "base.rb")
      # The superclass ancestry read is file-level; the method body read is symbol-level.
      expect(record.ancestry_sources).to include(base)
      expect(record.symbol_sources[base]).to include("Base#greet")
    end
  end

  it "records runner#symbol_fingerprints keyed by path and symbol" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), <<~RUBY)
        class Widget
          def price
            100
          end
        end
      RUBY
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      fps = runner.symbol_fingerprints

      model = File.join(dir, "model.rb")
      expect(fps[model]).to be_a(Hash)
      expect(fps[model].keys).to include("Widget#price")
      expect(fps[model]["Widget#price"]).to be_a(String).and have_attributes(length: 64)
    end
  end

  # ADR-57 / ADR-84 return-memo recording-soundness pin — the recorder must capture a callee's TRANSITIVE
  # (deep) reads for EVERY consumer, not just the shallow consumer→callee edge. `infer_user_method_return`
  # records the deep edge only as a side effect of evaluating the callee body, and the return memo serves
  # prior results without re-running it. Since ADR-84 WD2 made the bucket run-scoped, c2.rb's infer of
  # `Mid#relay` HITS the entry c1.rb's analysis stored, and soundness rests on cache-and-replay: the entry
  # carries the read-set captured during c1.rb's body walk, and the hit replays it into c2.rb's accumulator
  # — so deep.rb (which `relay`'s body reads through `Deep.new.leaf`) is recorded for both consumers. If a
  # cross-file hit ever stops replaying, this example breaks — c2.rb would inherit c1.rb's computed return
  # and never see deep.rb.
  it "records a callee's transitive deep-read file for every consumer under recording" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "deep.rb"), "class Deep\n  def leaf\n    1\n  end\nend\n")
      File.write(File.join(dir, "mid.rb"), <<~RUBY)
        class Mid
          def relay
            Deep.new.leaf
          end
        end
      RUBY
      File.write(File.join(dir, "c1.rb"), "Mid.new.relay\n")
      File.write(File.join(dir, "c2.rb"), "Mid.new.relay\n")

      runner = run_recording(dir)

      deep = File.join(dir, "deep.rb")
      %w[c1.rb c2.rb].each do |consumer|
        record = runner.file_dependencies[File.join(dir, consumer)]
        # The consumer transitively reads Deep#leaf through Mid#relay's body — deep.rb is a recorded source
        # even for the second consumer, whose Mid#relay return the memo could otherwise serve from a hit.
        expect(record.sources).to include(deep), "#{consumer} should depend on deep.rb (transitive deep edge)"
      end
      # And it inverts: an edit to deep.rb must re-check both consumers.
      expect(runner.file_dependents[deep]).to include(File.join(dir, "c1.rb"), File.join(dir, "c2.rb"))
    end
  end

  it "records nothing when dependency recording is off (the default)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Widget\n  def price\n    1\n  end\nend\n")
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      configuration = Rigor::Configuration.new("paths" => [dir])
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      guarded_run(runner)

      expect(runner.file_dependencies).to be_empty
    end
  end

  # ADR-84 WD2 — the observe-and-forward capture / replay seam the return memo's cache-and-replay uses.
  describe ".capture / .replay" do
    let(:recorder) { described_class }

    it "captures reads without disturbing the active consumer's record (observe-and-forward)" do
      read_set = nil
      record = recorder.record_for("/app/consumer.rb") do
        recorder.read_site("/app/other.rb:3", "Other#used_before")
        _, read_set = recorder.capture do
          recorder.read_site("/app/dep.rb:10", "Dep#leaf")
          recorder.read_missing(:method, "Ghost#gone")
          :computed
        end
        recorder.read_site("/app/late.rb:1", "Late#after")
      end

      # Forwarding: everything (before / during / after the window) landed on the consumer's record.
      expect(record.sources).to include("/app/other.rb", "/app/dep.rb", "/app/late.rb")
      expect(record.missing).to include("method:Ghost#gone")
      # Observing: the capture holds exactly the window's events.
      expect(read_set.reads).to eq(Set[["/app/dep.rb", "Dep#leaf"]])
      expect(read_set.missing).to eq(Set["method:Ghost#gone"])
    end

    it "captures the capturing consumer's own self-reads (they are cross-file for a replay target)" do
      read_set = nil
      record = recorder.record_for("/app/mid.rb") do
        _, read_set = recorder.capture do
          recorder.read_site("/app/mid.rb:5", "Mid#sibling")
        end
      end

      # The self-read is filtered from mid.rb's own record, per read_site's contract...
      expect(record.sources).not_to include("/app/mid.rb")
      # ...but the capture keeps it: replayed under another consumer it is a genuine cross-file edge.
      expect(read_set.reads).to eq(Set[["/app/mid.rb", "Mid#sibling"]])
    end

    it "replays a read-set into another consumer with the self-read filter re-applied" do
      read_set = nil
      recorder.record_for("/app/mid.rb") do
        _, read_set = recorder.capture do
          recorder.read_site("/app/mid.rb:5", "Mid#sibling")
          recorder.read_site("/app/deep.rb:2", "Deep#leaf")
          recorder.read_site("/app/other.rb:8")
          recorder.read_missing(:class, "Ghost")
        end
      end

      record = recorder.record_for("/app/consumer.rb") { recorder.replay(read_set) }
      expect(record.sources).to contain_exactly("/app/mid.rb", "/app/deep.rb", "/app/other.rb")
      expect(record.symbol_sources["/app/deep.rb"]).to include("Deep#leaf")
      expect(record.symbol_sources["/app/mid.rb"]).to include("Mid#sibling")
      expect(record.ancestry_sources).to include("/app/other.rb")
      expect(record.missing).to include("class:Ghost")

      # Replaying into the read-set's ORIGIN consumer re-applies the self-read filter.
      own = recorder.record_for("/app/mid.rb") { recorder.replay(read_set) }
      expect(own.sources).to contain_exactly("/app/deep.rb", "/app/other.rb")
    end

    it "keeps nested captures transitive: the outer window sees inner events and replayed sets" do
      inner_set = nil
      outer_set = nil
      recorder.record_for("/app/consumer.rb") do
        _, outer_set = recorder.capture do
          _, inner_set = recorder.capture do
            recorder.read_site("/app/deep.rb:2", "Deep#leaf")
          end
          # A memo hit inside the outer window replays a stored set — the outer capture must absorb it,
          # or the outer entry's read-set would drop the nested callee's edges.
          recorder.replay(recorder::ReadSet.new(reads: Set[["/app/stored.rb", "Stored#edge"]].freeze,
                                                missing: Set["method:Stored#missing"].freeze))
        end
      end

      expect(inner_set.reads).to eq(Set[["/app/deep.rb", "Deep#leaf"]])
      expect(outer_set.reads).to include(["/app/deep.rb", "Deep#leaf"], ["/app/stored.rb", "Stored#edge"])
      expect(outer_set.missing).to include("method:Stored#missing")
    end
  end
end
