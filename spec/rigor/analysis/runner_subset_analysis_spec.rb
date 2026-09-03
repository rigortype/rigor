# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 2 — the subset-analysis hook (`Runner.new(analyze_only:)`). The body tier re-analyses only the affected
# closure, so the runner must analyze a subset of files while still running the whole-project pre-pass (the cross-file
# index must stay complete or a subset analysis would lose resolutions and drift from a full run).
RSpec.describe "Rigor::Analysis::Runner analyze_only" do
  # A file carrying its own self-contained `def.override-visibility-reduced` (balanced profile → :warning) plus a class
  # other files can reference, so each file has a diagnostic of its own and a cross-file symbol.
  def write_unit(path, prefix:)
    File.write(path, <<~RUBY)
      class #{prefix}Base
        def tag
          "x"
        end
      end

      class #{prefix}Sub < #{prefix}Base
        private

        def tag
          "y"
        end
      end

      class #{prefix}Model
        def compute
          1
        end
      end
    RUBY
  end

  def run(dir, analyze_only: nil)
    config = Rigor::Configuration.new("paths" => [dir])
    runner = Rigor::Analysis::Runner.new(
      configuration: config, cache_store: nil, analyze_only: analyze_only
    )
    guarded_run(runner).diagnostics
  end

  it "analyzes only the requested subset, keeping the cross-file pre-pass complete" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      full = run(dir)
      subset = run(dir, analyze_only: [a])

      # Both files carry a diagnostic in the full run.
      expect(full.map(&:path)).to include(a, b)

      # The subset run emits diagnostics for a.rb and none for b.rb.
      expect(subset.map(&:path)).to include(a)
      expect(subset.map(&:path)).not_to include(b)

      # a.rb's diagnostics are byte-identical to the full run's — the pre-pass context is intact, so a subset analysis
      # matches a full one for the files it does analyze.
      expect(subset.select { |d| d.path == a }.map(&:to_h))
        .to eq(full.select { |d| d.path == a }.map(&:to_h))
    end
  end

  it "analyzes nothing per-file when the subset is empty" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      write_unit(a, prefix: "A")

      expect(run(dir, analyze_only: []).map(&:path)).not_to include(a)
    end
  end
end
