# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 2 — the incremental step's pure core plus its soundness
# property. The body tier re-analyses `{changed} ∪ dependents[changed]`
# and serves every other file from the per-file cache; the property that
# makes that sound is that an edit whose declaration-structure fingerprint
# is unchanged never changes the diagnostics of a file OUTSIDE that
# closure. These specs assert the set algebra in isolation and then drive
# real runs to confirm the property end-to-end.
RSpec.describe Rigor::Analysis::Incremental do
  describe ".affected" do
    it "is the changed set plus the dependents of every changed file" do
      dependents = { "model.rb" => Set["a.rb", "b.rb"], "other.rb" => Set["c.rb"] }
      expect(described_class.affected(["model.rb"], dependents)).to eq(Set["model.rb", "a.rb", "b.rb"])
    end

    it "is just the changed set when nothing depends on it (the leaf case)" do
      expect(described_class.affected(["leaf.rb"], {})).to eq(Set["leaf.rb"])
    end
  end

  describe ".changed_files" do
    it "compares per-file diagnostics structurally, not by object identity" do
      diag = instance_double(Rigor::Analysis::Diagnostic, to_h: { "rule" => "x", "line" => 1 })
      same = instance_double(Rigor::Analysis::Diagnostic, to_h: { "rule" => "x", "line" => 1 })
      moved = instance_double(Rigor::Analysis::Diagnostic, to_h: { "rule" => "x", "line" => 2 })

      before = { "a.rb" => [diag], "b.rb" => [diag] }
      after = { "a.rb" => [same], "b.rb" => [moved] }

      # a.rb unchanged (structurally equal), b.rb changed (line moved).
      expect(described_class.changed_files(before, after)).to eq(Set["b.rb"])
    end

    it "treats a file gaining or losing all diagnostics as changed" do
      diag = instance_double(Rigor::Analysis::Diagnostic, to_h: { "rule" => "x" })
      expect(described_class.changed_files({}, { "a.rb" => [diag] })).to eq(Set["a.rb"])
      expect(described_class.changed_files({ "a.rb" => [diag] }, {})).to eq(Set["a.rb"])
    end
  end

  # End-to-end soundness: drive real runs, mutate one file, and confirm
  # the files whose diagnostics actually moved are a subset of the affected
  # closure the body tier would re-analyse.
  describe "soundness property (real runs)" do
    def baseline(dir)
      config = Rigor::Configuration.new("paths" => [dir])
      runner = Rigor::Analysis::Runner.new(
        configuration: config, cache_store: nil, record_dependencies: true
      )
      result = runner.run
      [result.diagnostics.group_by(&:path), runner.file_dependents]
    end

    def per_file(dir)
      config = Rigor::Configuration.new("paths" => [dir])
      Rigor::Analysis::Runner.new(configuration: config, cache_store: nil).run.diagnostics.group_by(&:path)
    end

    # A self-contained `def.override-visibility-reduced` (balanced profile
    # → :warning). `reduced:` toggles the `private` modifier that is the
    # diagnostic's cause; `prefix` keeps each file's class names distinct
    # so the cross-file index never merges two fixtures.
    def write_reduction(path, prefix:, reduced:)
      File.write(path, <<~RUBY)
        class #{prefix}Base
          def greet
            "hi"
          end
        end

        class #{prefix}Sub < #{prefix}Base
          #{"private\n" if reduced}
          def greet
            "hello"
          end
        end
      RUBY
    end

    it "confines a leaf body edit's diagnostic change to the affected closure" do
      Dir.mktmpdir do |dir|
        widget = File.join(dir, "widget.rb")
        gadget = File.join(dir, "gadget.rb")
        write_reduction(widget, prefix: "W", reduced: true)
        write_reduction(gadget, prefix: "G", reduced: true)

        per_file_before, dependents = baseline(dir)
        # Both files start with their own diagnostic.
        expect(per_file_before[widget]).not_to be_nil
        expect(per_file_before[gadget]).not_to be_nil

        # Body edit to widget that erases its diagnostic. No symbol
        # added/removed/moved → declaration fingerprint unchanged.
        write_reduction(widget, prefix: "W", reduced: false)

        changed = described_class.changed_files(per_file_before, per_file(dir))
        affected = described_class.affected([widget], dependents)

        # The soundness invariant: every file whose diagnostics moved is in
        # the closure the body tier re-analyses.
        expect(changed).to be_subset(affected)
        # The edit toggled widget's own diagnostic …
        expect(changed).to include(widget)
        # … and left gadget untouched — it is correctly served from cache,
        # demonstrating the leaf-edit pruning win.
        expect(changed).not_to include(gadget)
      end
    end

    it "re-analyses a cross-file caller on a model edit (conservative safety)" do
      Dir.mktmpdir do |dir|
        model = File.join(dir, "model.rb")
        caller_file = File.join(dir, "caller.rb")
        File.write(model, <<~RUBY)
          class Model
            def compute
              1
            end
          end
        RUBY
        File.write(caller_file, <<~RUBY)
          class Caller
            def go
              Model.new.compute
            end
          end
        RUBY

        _diagnostics, dependents = baseline(dir)
        affected = described_class.affected([model], dependents)

        # caller.rb resolved Model#compute through to its body, so a Model
        # edit re-analyses caller.rb even though Rigor's conservative
        # inferred-return handling means its diagnostics rarely actually
        # change — the body tier re-checks it to stay sound, not because a
        # ripple is guaranteed.
        expect(affected).to include(caller_file)
      end
    end
  end
end
