# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/coverage_command"

# Focused coverage for the `rigor coverage` command object: the ADR-63 Tier 2
# mutation-effectiveness mode (`--protection --mutation`) and its git-changed-
# files default, plus unit safety nets for the default type-precision mode and
# the static Tier 1 protection mode (`--protection`), which are otherwise only
# exercised through the dispatcher / `make coverage`.
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

    it "errors with a usage message when given no paths and no git changes" do
      status, _out, err = run([])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("at least one path is required")
    end

    it "exits 1 when the precision ratio is below --threshold, 0 when it meets it" do
      # An untyped-parameter receiver dispatch is imprecise (Dynamic),
      # so the ratio is below 1.0 and above 0.0.
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
  end

  # ADR-70 — the fused static∪dynamic overlay. The TestSuiteOracle is stubbed so
  # the orchestration / report / exit logic is exercised without shelling out.
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

    it "rejects --include-dynamic without --with-tests (usage error)" do
      File.write("a.rb", "x = 1\n")
      status, _out, err = run(["--protection", "--mutation", "--include-dynamic", "a.rb"])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--include-dynamic requires --with-tests")
    end

    it "mutates Dynamic-receiver sites under --include-dynamic, crediting the test axis (Seam 2)" do
      # `x.save` on an untyped param has no biteable site; --include-dynamic
      # mutates it anyway so the test axis can score it.
      File.write("dyn.rb", %(def f(x)\n  x.save\nend\n))
      stub_oracle(green: true, kills: true)

      status, out, = run(["--protection", "--mutation", "--with-tests", "--include-dynamic", "--format", "json",
                          "dyn.rb"])

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["type_killed"]).to eq(0)
      expect(payload["test_killed"]).to be >= 1
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
