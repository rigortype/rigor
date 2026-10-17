# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #1388 — `sig-gen --params=observed` observes the project's test roots (`test_paths:`, or whichever of `spec/` and
# `test/` exist) when no `--observe=PATH` is given, instead of a hard-coded `spec/`.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def run(*argv, config: "paths:\n  - lib\n")
    write(".rigor.yml", config)
    out = StringIO.new
    err = StringIO.new
    argv = ["--print", "--params=observed", *argv, "--config=#{File.join(root, '.rigor.yml')}"]
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  before do
    write("lib/calc.rb", "class Calc\n  def m(x) = 1\nend\n")
  end

  it "observes a Minitest-style test/ directory when test_paths: is unset" do
    write("test/calc_test.rb", "Calc.new.m(42)\n")

    status, out, err = run

    expect(status).to eq(0)
    expect(out).to include("def m: (42) -> 1")
    expect(err).not_to include("no test roots")
  end

  it "observes the declared test_paths: roots, and only those" do
    write("checks/calc_check.rb", "Calc.new.m(42)\n")
    write("spec/calc_spec.rb", "Calc.new.m(\"s\")\n")

    _status, out, = run(config: "paths:\n  - lib\ntest_paths:\n  - checks\n")

    expect(out).to include("def m: (42) -> 1")
  end

  it "lets --observe=PATH override the configured test roots for one run" do
    write("checks/calc_check.rb", "Calc.new.m(42)\n")
    write("spec/calc_spec.rb", "Calc.new.m(\"s\")\n")

    _status, out, = run("--observe=spec", config: "paths:\n  - lib\ntest_paths:\n  - checks\n")

    expect(out).to include(%(def m: ("s") -> 1))
  end

  it "says why every parameter stays untyped when there is no test root to observe" do
    status, out, err = run

    expect(status).to eq(0)
    expect(out).to include("def m: (untyped) -> 1")
    expect(err).to include("no test roots to observe").and include("test_paths:")
  end

  it "names a declared test root that does not exist instead of observing it silently" do
    write("spec/calc_spec.rb", "Calc.new.m(42)\n")

    _status, out, err = run(config: "paths:\n  - lib\ntest_paths:\n  - tests\n")

    expect(out).to include("def m: (untyped) -> 1")
    expect(err).to include("tests").and include("does not exist").and include("every parameter stays untyped")
  end

  it "names only the missing root when another declared root exists" do
    write("spec/calc_spec.rb", "Calc.new.m(42)\n")

    _status, out, err = run(config: "paths:\n  - lib\ntest_paths:\n  - spec\n  - tests\n")

    expect(out).to include("def m: (42) -> 1")
    expect(err).to include("tests").and include("does not exist")
    expect(err).not_to include("every parameter stays untyped")
  end

  it "names an explicit empty test_paths: as the reason" do
    write("spec/calc_spec.rb", "Calc.new.m(42)\n")

    _status, out, err = run(config: "paths:\n  - lib\ntest_paths: []\n")

    expect(out).to include("def m: (untyped) -> 1")
    expect(err).to include("`test_paths:` is empty")
  end

  # #1398 — the stderr notes are invisible to `--format=json` consumers (and to the MCP tool), so the same fact
  # is data: a top-level `observation` key, additive to `candidates`.
  describe "the JSON `observation` report" do
    def observation(*argv, config: "paths:\n  - lib\n")
      _status, out, err = run("--format=json", *argv, config: config)
      [JSON.parse(out), err]
    end

    it "lists the observed roots and no missing ones" do
      write("checks/calc_check.rb", "Calc.new.m(42)\n")

      payload, = observation(config: "paths:\n  - lib\ntest_paths:\n  - checks\n")

      expect(payload.fetch("observation")).to eq("paths" => [File.join(root, "checks")], "missing" => [])
      expect(payload.fetch("candidates")).not_to be_empty
    end

    it "splits a declared root that does not exist from the ones that do" do
      write("spec/calc_spec.rb", "Calc.new.m(42)\n")

      payload, = observation(config: "paths:\n  - lib\ntest_paths:\n  - spec\n  - tests\n")

      expect(payload.fetch("observation")).to eq("paths" => [File.join(root, "spec")],
                                                 "missing" => [File.join(root, "tests")])
    end

    it "reports an empty `paths` when there is no test root at all" do
      payload, err = observation

      expect(payload.fetch("observation")).to eq("paths" => [], "missing" => [])
      expect(err).to include("no test roots to observe")
    end

    it "reports an auto-detected root as an absolute path" do
      write("test/calc_test.rb", "Calc.new.m(42)\n")

      payload, = observation

      expect(payload.fetch("observation").fetch("paths")).to eq([File.join(File.realpath(root), "test")])
    end

    it "reports --observe=PATH as typed" do
      write("spec/calc_spec.rb", "Calc.new.m(42)\n")

      payload, = observation("--observe=spec", "--observe=nowhere")

      expect(payload.fetch("observation")).to eq("paths" => ["spec"], "missing" => ["nowhere"])
    end

    it "lists an existing root the collector would not read as missing" do
      write("README.md", "Calc.new.m(42)\n")
      write("spec/calc_spec.rb", "Calc.new.m(42)\n")

      payload, = observation("--observe=README.md", "--observe=spec")

      expect(payload.fetch("observation")).to eq("paths" => ["spec"], "missing" => ["README.md"])
    end

    it "lists a repeated root once" do
      write("spec/calc_spec.rb", "Calc.new.m(42)\n")

      payload, = observation("--observe=spec", "--observe=spec")

      expect(payload.fetch("observation")).to eq("paths" => ["spec"], "missing" => [])
    end

    it "is absent under --params=untyped" do
      write(".rigor.yml", "paths:\n  - lib\n")
      out = StringIO.new
      described_class.new(argv: ["--print", "--format=json", "--config=#{File.join(root, '.rigor.yml')}"],
                          out: out, err: StringIO.new).run

      expect(JSON.parse(out.string).keys).to eq(["candidates"])
    end

    it "keeps the stderr note in text mode" do
      _status, out, err = run

      expect(out).not_to include("observation")
      expect(err).to include("no test roots to observe")
    end
  end
end
