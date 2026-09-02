# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #644, incremental half — a cross-file value constant is a cross-file FACT, so every ADR-46 edge that
# keeps a warm `--incremental` run honest has to carry it: the reader must be re-checked when the assignment
# APPEARS (the new `constant:` negative kind), when the LITERAL MOVES (the declaration signature), and when
# the declaring file is DELETED (the positive edge).
#
# The oracle in every example is a full `--no-cache` run of the same tree: a stale answer here is a
# manufactured false positive or negative, which is the failure mode the whole incremental design exists to
# prevent. `--verify-incremental` cannot see this class of gap (its even-indexed subset re-analyses the
# consumer itself), so the discriminating driver is `IncrementalSession` — baseline → edit → recheck — exactly
# as ADR-46 § "Structural tier" records for the #622 constant-absence gap.
#
# The observable is a REAL diagnostic rather than a `dump_type` info: `FOO.upcase` is silent while `FOO` is a
# Symbol and fires `call.undefined-method` while it is an Integer, so each step's expectation is a must-fire
# paired with a must-not-fire on the same site.
RSpec.describe "cross-file value constants — incremental" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [dir], environment: shared_environment
    )
  end

  def rules(diagnostics)
    diagnostics.reject { |d| d.severity == :info }.map { |d| "#{File.basename(d.path)}:#{d.rule}" }.sort
  end

  def full_run(dir)
    rules(
      Rigor::Analysis::Runner.new(
        configuration: configuration(dir), cache_store: nil, environment: shared_environment
      ).run.diagnostics
    )
  end

  # The reader is untouched throughout; only the declaring file appears, moves, and vanishes.
  def reader_source
    "def probe\n  FOO.upcase\nend\n"
  end

  it "re-checks the reader through an add / edit / delete sequence, matching a full run at every step" do
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      declaring = File.join(dir, "b.rb")
      File.write(reader, reader_source)

      session = session_for(dir)
      expect(rules(session.baseline)).to eq([])
      expect(full_run(dir)).to eq([])

      # ADD — the `constant:FOO` negative edge the baseline recorded now resolves.
      File.write(declaring, "FOO = 42\n")
      recheck = session.recheck
      expect(recheck.affected).to include(reader)
      expect(rules(recheck.diagnostics)).to eq(["a.rb:call.undefined-method"])
      expect(full_run(dir)).to eq(["a.rb:call.undefined-method"])

      # EDIT — the literal moves to a Symbol; the reader's diagnostic must disappear. The file's declaration
      # signature carries its published constants, so the reader is not dropped as declaration-stable.
      File.write(declaring, "FOO = :sym\n")
      recheck = session.recheck
      expect(recheck.affected).to include(reader)
      expect(rules(recheck.diagnostics)).to eq([])
      expect(full_run(dir)).to eq([])

      # EDIT BACK — and it must come back.
      File.write(declaring, "FOO = 42\n")
      expect(rules(session.recheck.diagnostics)).to eq(["a.rb:call.undefined-method"])

      # DELETE — the constant is gone, the reader is `Dynamic[top]` again, and the positive edge is what puts
      # it back in the closure (a removed file re-checks its positive dependents).
      FileUtils.rm(declaring)
      recheck = session.recheck
      expect(recheck.affected).to include(reader)
      expect(rules(recheck.diagnostics)).to eq([])
      expect(full_run(dir)).to eq([])
    end
  end

  it "records the positive edge to the DECLARING file, not merely to any file" do
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      declaring = File.join(dir, "b.rb")
      unrelated = File.join(dir, "c.rb")
      File.write(reader, reader_source)
      File.write(declaring, "FOO = :sym\n")
      File.write(unrelated, "class Unrelated\n  def z\n    1\n  end\nend\n")

      session = session_for(dir)
      session.baseline

      # Editing the UNRELATED file must not pull the reader in — the paired must-not-fire that proves the
      # edge above is attributed and not a blanket "re-check everything".
      File.write(unrelated, "class Unrelated\n  def z\n    2\n  end\nend\n")
      expect(session.recheck.affected).not_to include(reader)

      # ...while editing the declaring file's literal does.
      File.write(declaring, "FOO = 42\n")
      expect(session.recheck.affected).to include(reader)
    end
  end

  describe "Incremental.appeared_constants" do
    it "reports a constant present only in the after-state, and nothing for an unchanged one" do
      before = { "b.rb" => Set["KEPT"] }
      after  = { "b.rb" => Set["KEPT", "NEW"] }
      expect(Rigor::Analysis::Incremental.appeared_constants(["b.rb"], before, after)).to eq(Set["NEW"])
    end

    it "treats an added file (no before-state) as declaring all of its constants" do
      after = { "b.rb" => Set["A", "B"] }
      expect(Rigor::Analysis::Incremental.appeared_constants(["b.rb"], {}, after)).to eq(Set["A", "B"])
    end

    it "reports nothing for a file outside the changed set" do
      after = { "other.rb" => Set["NEW"] }
      expect(Rigor::Analysis::Incremental.appeared_constants(["b.rb"], {}, after)).to eq(Set.new)
    end
  end
end
