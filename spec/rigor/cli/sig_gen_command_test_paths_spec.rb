# frozen_string_literal: true

require "fileutils"
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

  it "names an explicit empty test_paths: as the reason" do
    write("spec/calc_spec.rb", "Calc.new.m(42)\n")

    _status, out, err = run(config: "paths:\n  - lib\ntest_paths: []\n")

    expect(out).to include("def m: (untyped) -> 1")
    expect(err).to include("`test_paths:` is empty")
  end
end
