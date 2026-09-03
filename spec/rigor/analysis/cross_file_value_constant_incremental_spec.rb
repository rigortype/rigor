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

  def described_module = Rigor::Analysis::Incremental

  def rules(diagnostics)
    diagnostics.reject { |d| d.severity == :info }.map { |d| "#{File.basename(d.path)}:#{d.rule}" }.sort
  end

  def messages(diagnostics) = messages_of(diagnostics)

  def messages_of(diagnostics)
    diagnostics.reject { |d| d.severity == :info }.map(&:message).sort
  end

  def full_diagnostics(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    guarded_run(runner).diagnostics
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    rules(guarded_run(runner).diagnostics)
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

  # The three sequences the review found stale. Each turns on a change to the PUBLICATION of a name that is
  # not an appearance of the name, which is why a producer diffing assigned names alone could not see any of
  # them, and why `changed_constant_publications` diffs the census descriptor over changed + added + REMOVED.
  describe "publication changes that are not name appearances" do
    it "re-checks the reader when a SECOND declarer appears and drops the name to Dynamic" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, reader_source)
        File.write(File.join(dir, "b.rb"), "FOO = 42\n")
        session = session_for(dir)
        expect(rules(session.baseline)).to eq(["a.rb:call.undefined-method"])

        # The reader RESOLVED at baseline, so it recorded no miss; only the hit-side name edge reaches it.
        File.write(File.join(dir, "c.rb"), "FOO = \"forty-two\"\n")
        recheck = session.recheck
        expect(recheck.affected).to include(a)
        expect(rules(recheck.diagnostics)).to eq([])
        expect(full_run(dir)).to eq([])
      end
    end

    it "re-checks the reader when the conflicting declarer is DELETED and the precise answer returns" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        c = File.join(dir, "c.rb")
        File.write(a, reader_source)
        File.write(File.join(dir, "b.rb"), "FOO = 42\n")
        File.write(c, "FOO = \"forty-two\"\n")
        session = session_for(dir)
        expect(rules(session.baseline)).to eq([])

        # A removed file appears in no scan summary, so its whole before-census is what carries the change.
        FileUtils.rm(c)
        recheck = session.recheck
        expect(recheck.affected).to include(a)
        expect(rules(recheck.diagnostics)).to eq(["a.rb:call.undefined-method"])
        expect(full_run(dir)).to eq(["a.rb:call.undefined-method"])
      end
    end

    it "re-checks the reader across an UNPUBLISHABLE intermediate state" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, reader_source)
        File.write(b, "FOO = 42\n")
        session = session_for(dir)
        expect(rules(session.baseline)).to eq(["a.rb:call.undefined-method"])

        # Step 1 leaves the reader recording only a MISS; the name never appears or vanishes across step 2,
        # so only a descriptor diff can see it come back.
        File.write(b, "FOO = \"str\"\n")
        expect(rules(session.recheck.diagnostics)).to eq([])

        File.write(b, "FOO = 42\n")
        recheck = session.recheck
        expect(recheck.affected).to include(a)
        expect(rules(recheck.diagnostics)).to eq(["a.rb:call.undefined-method"])
        expect(full_run(dir)).to eq(["a.rb:call.undefined-method"])
      end
    end
  end

  it "re-checks a reader whose constant resolved through RBS when the project shadows it" do
    # The name edge is recorded once per reference, BEFORE the resolver ladder, so it covers a reference the
    # RBS environment answered. Without that, a project file that later assigns `Math::PI` leaves the reader
    # serving the RBS value — the same staleness as a second declarer, with a different baseline resolver,
    # and NEW with the publication (on master a project value write never won at a reader).
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      File.write(a, "def probe\n  Math::PI.upcase\nend\n")
      session = session_for(dir)
      expect(messages(session.baseline)).to eq(["undefined method `upcase' for 3.141592653589793"])

      File.write(File.join(dir, "b.rb"), "module Math\n  PI = 3\nend\n")
      recheck = session.recheck
      expect(recheck.affected).to include(a)
      expect(messages(recheck.diagnostics)).to eq(["undefined method `upcase' for 3"])
      expect(messages_of(full_diagnostics(dir))).to eq(["undefined method `upcase' for 3"])
    end
  end

  describe "Incremental.changed_constant_publications" do
    it "reports a name whose descriptor moved, and nothing for one that did not" do
      before = { "b.rb" => { "KEPT" => [1], "MOVED" => [1] } }
      after  = { "b.rb" => { "KEPT" => [1], "MOVED" => [2] } }
      expect(described_module.changed_constant_publications(["b.rb"], before, after)).to eq(Set["MOVED"])
    end

    it "reports a name whose write became unpublishable, which is no change of NAME at all" do
      before = { "b.rb" => { "X" => [1] } }
      after  = { "b.rb" => { "X" => :unpublishable } }
      expect(described_module.changed_constant_publications(["b.rb"], before, after)).to eq(Set["X"])
    end

    it "treats an added file's whole census as changed, and a removed file's as changed too" do
      expect(described_module.changed_constant_publications(["b.rb"], {}, { "b.rb" => { "A" => [1] } }))
        .to eq(Set["A"])
      expect(described_module.changed_constant_publications(["c.rb"], { "c.rb" => { "A" => [1] } }, {}))
        .to eq(Set["A"])
    end

    it "reports nothing for a file outside the diffed set" do
      after = { "other.rb" => { "NEW" => [1] } }
      expect(described_module.changed_constant_publications(["b.rb"], {}, after)).to eq(Set.new)
    end

    it "distinguishes an Integer literal from the equal Float, which `==` would not" do
      # `[1] == [1.0]` is true, so a `==` comparison would call `LIMIT = 1` -> `LIMIT = 1.0` unchanged while
      # the published type moved from `Constant[1]` to `Constant[1.0]`.
      before = { "b.rb" => { "LIMIT" => [1] } }
      after  = { "b.rb" => { "LIMIT" => [1.0] } }
      expect(described_module.changed_constant_publications(["b.rb"], before, after)).to eq(Set["LIMIT"])
    end
  end
end
