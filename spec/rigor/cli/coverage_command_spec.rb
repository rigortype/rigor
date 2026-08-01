# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/coverage_command"

# Focused coverage for the `rigor coverage` command object: the ADR-63 Tier 2 mutation-effectiveness mode (`--protection
# --mutation`) and its git-changed- files default, plus unit safety nets for the default type-precision mode and the
# static Tier 1 protection mode (`--protection`), which are otherwise only exercised through the dispatcher / `make
# coverage`.
RSpec.describe Rigor::CLI::CoverageCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "rejects --mutation without --protection (usage error)" do
    File.write("a.rb", "x = 1\n")
    status, _out, err = run(["--mutation", "a.rb"])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("--mutation requires --protection")
  end

  it "measures mutation effectiveness for an explicit file and reports the ratio" do
    File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))

    status, out, = run(["--protection", "--mutation", "greet.rb"])

    expect(status).to eq(0)
    expect(out).to include("Type-protection effectiveness")
    expect(out).to include("caught breakages:")
  end

  it "emits the structured Tier 2 fields under --format json" do
    File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))

    status, out, = run(["--protection", "--mutation", "--format", "json", "greet.rb"])

    expect(status).to eq(0)
    payload = JSON.parse(out)
    expect(payload["mode"]).to eq("mutation")
    expect(payload).to have_key("effectiveness_ratio")
    expect(payload["killed"]).to be >= 1
  end

  # Issue #134 slice 1 — the Tier 2 fork pool is a pure performance change, exactly as P3-10 was for Tier 1:
  # the accumulator's per-file list and per-method examples are absorption-ordered, so the parent absorbs in
  # original `paths` order and the JSON must come out byte-identical.
  it "produces byte-identical mutation JSON under --workers as sequential (multi-file)" do
    FileUtils.mkdir_p("lib")
    4.times { |i| File.write("lib/f#{i}.rb", %(def m#{i}(x)\n  "hello#{i}".upcase\n  x.thing#{i}\nend\n)) }

    _, sequential, = run(["--protection", "--mutation", "--workers", "0", "--format", "json", "lib"])
    _, forked, = run(["--protection", "--mutation", "--workers", "4", "--format", "json", "lib"])

    expect(JSON.parse(sequential)["killed"]).to be >= 1
    expect(forked).to eq(sequential)
  end

  # Issue #253 — the `discovery-seeded-mutation-sites` bleeding-edge feature. Tier 2 site selection judged a
  # receiver against a bare `Scope.empty`, so a call on a project class declared in a *sibling* file read
  # Dynamic and never entered the denominator. Seeded, it resolves as Tier 1 already resolves it.
  #
  # The fixture is deliberately two files: with `Account` declared in the file under measurement the seed
  # would be vacuous (the single-file indexer finds it either way), and the spec would pass on master.
  describe "Tier 2 discovery seed (--protection --mutation)" do
    def write_cross_file_fixture
      FileUtils.mkdir_p("lib")
      File.write("lib/account.rb", "class Account\n  def self.find(id)\n    id\n  end\nend\n")
      File.write("lib/service.rb", "def lookup\n  Account.find(1)\nend\n")
    end

    def adopt_feature
      File.write(".rigor.yml", "bleeding_edge:\n  - discovery-seeded-mutation-sites\n")
    end

    def measured_sites(json)
      payload = JSON.parse(json)
      payload.fetch("killed") + payload.fetch("survived")
    end

    it "leaves the report byte-identical when the feature is not adopted" do
      write_cross_file_fixture
      _, unconfigured, = run(["--protection", "--mutation", "--format", "json", "lib"])

      File.write(".rigor.yml", "bleeding_edge: false\n")
      _, declined, = run(["--protection", "--mutation", "--format", "json", "lib"])

      expect(measured_sites(unconfigured)).to eq(0) # the cross-file site is dropped, as it always was
      expect(declined).to eq(unconfigured)
    end

    it "admits the cross-file project-class dispatch site once adopted" do
      write_cross_file_fixture
      _, off, = run(["--protection", "--mutation", "--format", "json", "lib"])

      adopt_feature
      _, on, = run(["--protection", "--mutation", "--format", "json", "lib"])

      # Non-vacuity: the seed must have RESOLVED `Account`, which shows up as sites appearing under the very
      # file that only references it, attributed to the method it dispatches.
      expect(measured_sites(on)).to be > measured_sites(off)
      payload = JSON.parse(on)
      service = payload.fetch("files").find { |f| f.fetch("path") == "lib/service.rb" }
      expect(service.fetch("killed") + service.fetch("survived")).to be >= 1
      expect(payload.fetch("add_a_type_here").map { |m| m.fetch("method") }).to include("find")
    end

    # The seed is built ONCE on the parent and copy-on-write inherited by {MutationForkScan}'s children (only
    # the per-file results cross the marshal boundary). It must therefore introduce no order- or fork-sensitivity.
    it "stays byte-identical across worker counts with the feature on" do
      FileUtils.mkdir_p("lib")
      File.write("lib/account.rb", "class Account\n  def self.find(id)\n    id\n  end\nend\n")
      3.times { |i| File.write("lib/service#{i}.rb", "def lookup#{i}\n  Account.find(#{i})\nend\n") }
      adopt_feature

      _, sequential, = run(["--protection", "--mutation", "--workers", "0", "--format", "json", "lib"])
      _, forked, = run(["--protection", "--mutation", "--workers", "2", "--format", "json", "lib"])

      expect(measured_sites(sequential)).to be >= 3
      expect(forked).to eq(sequential)
    end
  end

  it "reports nothing to measure when no paths are given and nothing changed" do
    # An empty git work tree → no changed Ruby files → vacuous success.
    system("git", "init", "--quiet", out: File::NULL, err: File::NULL)

    status, out, = run(["--protection", "--mutation"])

    expect(status).to eq(0)
    expect(out).to include("No changed Ruby files")
  end

  describe "type-precision mode (the default)" do
    it "renders a precision report and exits 0 with no threshold" do
      File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))

      status, out, = run(["greet.rb"])

      expect(status).to eq(0)
      expect(out).not_to be_empty
    end

    it "falls back to the configured paths: when given no paths (parity with `rigor check`)" do
      # The default config `paths:` is `["lib"]`; a real lib/ file is scanned instead of erroring.
      FileUtils.mkdir_p("lib")
      File.write("lib/greet.rb", %(def greet\n  "hello".upcase\nend\n))

      status, out, = run([])

      expect(status).to eq(0)
      expect(out).not_to be_empty
    end

    it "usage-errors when no paths are given and the configured paths do not exist" do
      # No argv → falls back to the default config `paths:` (`["lib"]`), which is absent in this tmpdir.
      status, _out, err = run([])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("not a file or directory: lib")
    end

    it "exits 1 when the precision ratio is below --threshold, 0 when it meets it" do
      # An untyped-parameter receiver dispatch is imprecise (Dynamic), so the ratio is below 1.0 and above 0.0.
      File.write("dyn.rb", "def f(x)\n  x.whatever\nend\n")

      below, = run(["--threshold", "1.0", "dyn.rb"])
      meets, = run(["--threshold", "0.0", "dyn.rb"])

      expect(below).to eq(1)
      expect(meets).to eq(0)
    end
  end

  describe "static protection mode (--protection without --mutation)" do
    it "renders the Tier 1 protection report and exits 0" do
      File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))

      status, out, = run(["--protection", "greet.rb"])

      expect(status).to eq(0)
      expect(out).not_to be_empty
    end

    it "exits 1 when the protection ratio is below --threshold, 0 when it meets it" do
      File.write("dyn.rb", "def f(x)\n  x.whatever\nend\n")

      below, = run(["--protection", "--threshold", "1.0", "dyn.rb"])
      meets, = run(["--protection", "--threshold", "0.0", "dyn.rb"])

      expect(below).to eq(1)
      expect(meets).to eq(0)
    end

    it "omits dynamic_origin in JSON output when nil" do
      # A global-variable read has no propagated cause (unlike an undeclared parameter or an unbound
      # instance variable, which route to `inferred_return_untyped`), so its hole exercises the
      # omit-when-nil path.
      File.write("dyn.rb", "def f\n  $x.whatever\nend\n")

      status, out, = run(["--protection", "--format", "json", "dyn.rb"])

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["add_a_type_here"]).to be_an(Array)
      entry = payload["add_a_type_here"].first
      expect(entry).to have_key("method")
      expect(entry).not_to have_key("dynamic_origin")
    end

    # P3-10 — the fork pool is a pure performance change: its output MUST be byte-identical to the
    # sequential path (the accumulator's per-method examples / per-file list are order-sensitive, so the
    # parent absorbs worker results in original path order).
    it "produces byte-identical JSON under --workers as sequential (multi-file)" do
      FileUtils.mkdir_p("lib")
      6.times do |i|
        File.write("lib/f#{i}.rb", "def m#{i}(x)\n  x.thing#{i}\n  \"s\".upcase\nend\n")
      end

      _, sequential, = run(["--protection", "--format", "json", "lib"])
      _, forked, = run(["--protection", "--workers", "3", "--format", "json", "lib"])

      expect(forked).to eq(sequential)
    end
  end

  # ADR-70 — the fused static∪dynamic overlay. The TestSuiteOracle is stubbed so the orchestration / report / exit logic
  # is exercised without shelling out.
  describe "--with-tests (fused protection)" do
    def fake_oracle(green:, kills:)
      oracle = Object.new
      oracle.define_singleton_method(:green?) { green }
      oracle.define_singleton_method(:killed?) { |**| kills }
      oracle
    end

    def stub_oracle(green:, kills:)
      allow(Rigor::Protection::TestSuiteOracle).to receive(:new).and_return(fake_oracle(green: green, kills: kills))
    end

    it "rejects --with-tests without --mutation (usage error)" do
      File.write("a.rb", "x = 1\n")
      status, _out, err = run(["--protection", "--with-tests", "a.rb"])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--with-tests requires --mutation")
    end

    it "aborts when the test suite is not green on clean code" do
      File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))
      stub_oracle(green: false, kills: false)

      status, _out, err = run(["--protection", "--mutation", "--with-tests", "greet.rb"])

      expect(status).to eq(1)
      expect(err).to include("test suite must pass on clean code")
    end

    it "reports the fused map and credits a type-survivor to the test axis" do
      File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))
      stub_oracle(green: true, kills: true)

      status, out, = run(["--protection", "--mutation", "--with-tests", "joins.rb"])

      expect(status).to eq(0)
      expect(out).to include("Fused protection")
      expect(out).to include("by test:")
    end

    it "emits the fused JSON shape" do
      File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))
      stub_oracle(green: true, kills: false)

      status, out, = run(["--protection", "--mutation", "--with-tests", "--format", "json", "joins.rb"])

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["mode"]).to eq("protection-fused")
      expect(payload).to have_key("protected_ratio")
      expect(payload["unprotected"]).to be >= 1
    end

    # Issue #134 slice 1 — the fused tier stays sequential (the suite oracle shells out; parallel runs would
    # race), so an explicit --workers is announced as ignored rather than silently dropped.
    it "keeps the fused path sequential and says so when --workers is given explicitly" do
      File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))
      stub_oracle(green: true, kills: true)
      allow(Rigor::CLI::MutationForkScan).to receive(:run).and_raise("the fused path must not fork")

      status, _out, err = run(["--protection", "--mutation", "--with-tests", "--workers", "4", "joins.rb"])

      expect(status).to eq(0)
      expect(err).to include("--workers is ignored with --with-tests")
    end

    it "rejects --include-dynamic without --with-tests (usage error)" do
      File.write("a.rb", "x = 1\n")
      status, _out, err = run(["--protection", "--mutation", "--include-dynamic", "a.rb"])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--include-dynamic requires --with-tests")
    end

    it "mutates Dynamic-receiver sites under --include-dynamic, crediting the test axis (Seam 2)" do
      # `x.save` on an untyped param has no biteable site; --include-dynamic mutates it anyway so the test axis can
      # score it.
      File.write("dyn.rb", %(def f(x)\n  x.save\nend\n))
      stub_oracle(green: true, kills: true)

      status, out, = run(["--protection", "--mutation", "--with-tests", "--include-dynamic", "--format", "json",
                          "dyn.rb"])

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["type_killed"]).to eq(0)
      expect(payload["test_killed"]).to be >= 1
    end

    # Issue #253 — the seed reaches `Mutator#dispatch_site_mutations` too, through the same parameter and the
    # same gate. There it only *annotates* the receiver type (every dispatch site is kept regardless), so the
    # bucket counts are unchanged; what must hold is that the fused path still runs, and sequentially.
    it "seeds the fused site selector too when the feature is adopted" do
      FileUtils.mkdir_p("lib")
      File.write(".rigor.yml", "bleeding_edge:\n  - discovery-seeded-mutation-sites\n")
      File.write("lib/account.rb", "class Account\n  def self.find(id)\n    id\n  end\nend\n")
      File.write("lib/service.rb", "def lookup\n  Account.find(1)\nend\n")
      stub_oracle(green: true, kills: true)
      allow(Rigor::CLI::MutationForkScan).to receive(:run).and_raise("the fused path must not fork")

      status, out, = run(["--protection", "--mutation", "--with-tests", "--include-dynamic", "--format", "json",
                          "lib"])

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload.fetch("type_killed") + payload.fetch("test_killed")).to be >= 1
    end
  end

  it "samples under --limit and keeps JSON stdout clean (the note goes to stderr)" do
    File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))

    status, out, err = run(["--protection", "--mutation", "--limit", "2", "--format", "json", "greet.rb"])

    expect(status).to eq(0)
    expect { JSON.parse(out) }.not_to raise_error
    expect(err).to include("sampling at most 2 mutations")
  end

  describe "#changed_path (git porcelain line parsing)" do
    def parse(line)
      described_class.new(argv: []).send(:changed_path, line)
    end

    it "extracts a modified Ruby path" do
      expect(parse(" M lib/foo.rb\n")).to eq("lib/foo.rb")
    end

    it "extracts the destination of a rename" do
      expect(parse("R  lib/old.rb -> lib/new.rb\n")).to eq("lib/new.rb")
    end

    it "strips surrounding quotes git adds for unusual paths" do
      expect(parse(%(?? "spaced name.rb"\n))).to eq("spaced name.rb")
    end

    it "ignores non-Ruby paths" do
      expect(parse(" M README.md\n")).to be_nil
    end
  end
end
