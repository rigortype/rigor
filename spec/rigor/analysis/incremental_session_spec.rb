# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 2 — the in-memory incremental orchestrator. The acceptance
# property (the `--verify-incremental` gate, here without disk persistence
# or CLI wiring): after a real on-disk edit, `#recheck` re-analyzes only
# the affected closure and serves the rest from cache, yet its merged
# diagnostics are byte-identical — as a sorted set — to a full re-analysis
# of the edited tree.
RSpec.describe Rigor::Analysis::IncrementalSession do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def full_run(dir)
    Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil).run.diagnostics
  end

  def sorted(diagnostics)
    diagnostics.map(&:to_h).sort_by { |hash| [hash["path"], hash["line"], hash["column"], hash["rule"]] }
  end

  # A self-contained `def.override-visibility-reduced` (balanced profile →
  # :warning) plus a referenceable class. `reduced:` toggles the diagnostic.
  def write_unit(path, prefix:, reduced: true)
    File.write(path, <<~RUBY)
      class #{prefix}Base
        def tag
          "x"
        end
      end

      class #{prefix}Sub < #{prefix}Base
        #{"private\n" if reduced}
        def tag
          "y"
        end
      end
    RUBY
  end

  it "matches a full re-analysis after a leaf body edit while re-checking one file" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = described_class.new(configuration: configuration(dir))
      session.baseline

      # Body edit to a.rb only — erase its diagnostic. b.rb is untouched.
      write_unit(a, prefix: "A", reduced: false)

      recheck = session.recheck

      # Only a.rb was re-analyzed; b.rb was served from cache.
      expect(recheck.changed).to eq(Set[a])
      expect(recheck.affected).to eq(Set[a])
      expect(recheck.reused).to include(b)

      # The merged result equals a full re-analysis of the edited tree.
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "matches a full re-analysis when nothing changed (all served from cache)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      write_unit(a, prefix: "A")

      session = described_class.new(configuration: configuration(dir))
      session.baseline
      recheck = session.recheck

      expect(recheck.changed).to be_empty
      expect(recheck.affected).to be_empty
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "stays correct across two successive edits (multi-round state)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = described_class.new(configuration: configuration(dir))
      session.baseline

      # Round 1: erase a.rb's diagnostic.
      write_unit(a, prefix: "A", reduced: false)
      r1 = session.recheck
      expect(sorted(r1.diagnostics)).to eq(sorted(full_run(dir)))

      # Round 2: erase b.rb's diagnostic too. The session's cache for a.rb
      # must already reflect round 1, so the merge stays correct.
      write_unit(b, prefix: "B", reduced: false)
      r2 = session.recheck
      expect(r2.changed).to eq(Set[b])
      expect(sorted(r2.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end
end
