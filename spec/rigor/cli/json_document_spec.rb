# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"

# ADR-126 WD2 / WD4 — the version marker on object-topped `--format=json` documents, and the stderr notice on
# `type-of`, `explain` and `trace`, whose top-level shape changes in the next minor.
RSpec.describe Rigor::CLI::JsonDocument do
  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.new(argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "code.rb"), "x = 1\nx.succ\n")
      Dir.chdir(dir) { example.run }
    end
  end

  describe ".stamp" do
    it "puts schema_version first, then mode, ahead of the payload" do
      expect(described_class.stamp({ "a" => 1 },
                                   mode: "m").to_a).to eq([["schema_version", 1], %w[mode m], ["a", 1]])
    end

    it "omits mode when the command has one document" do
      expect(described_class.stamp({ "a" => 1 }).keys).to eq(%w[schema_version a])
    end
  end

  it "stamps rigor check with schema_version 1" do
    _, out, = run("check", "--format=json", "code.rb")
    expect(JSON.parse(out).keys.first).to eq("schema_version")
    expect(JSON.parse(out).fetch("schema_version")).to eq(1)
  end

  it "stamps coverage with its mode" do
    _, out, = run("coverage", "--format=json", "code.rb")
    expect(JSON.parse(out).first(2)).to eq([["schema_version", 1], %w[mode precision]])
  end

  it "stamps plugins with its mode" do
    _, out, = run("plugins", "--format=json")
    expect(JSON.parse(out).first(2)).to eq([["schema_version", 1], %w[mode status]])
  end

  it "keeps type-of's single-result object unstamped and names the next shape on stderr" do
    _, out, err = run("type-of", "--format=json", "code.rb:2:1")
    expect(JSON.parse(out)).not_to have_key("schema_version")
    expect(err).to match(/type-of --format=json.*results/)
  end

  it "keeps explain's array on stdout and names the next shape on stderr" do
    _, out, err = run("explain", "--format=json")
    expect(JSON.parse(out)).to be_a(Array)
    expect(err).to match(/explain --format=json.*rules/)
  end

  it "keeps trace's array on stdout and names the next shape on stderr" do
    _, out, err = run("trace", "--format=json", "--delay=0", "code.rb")
    expect(JSON.parse(out)).to be_a(Array)
    expect(err).to match(/trace --format=json.*events/)
  end

  # ADR-126 WD2 — one row per document: the command line and the `mode` its flag selects (nil: one document).
  {
    "check" => [%w[check --format=json code.rb], nil],
    "annotate" => [%w[annotate --format=json code.rb], nil],
    "doctor" => [%w[doctor --format=json], nil],
    "type-scan" => [%w[type-scan --format=json code.rb], nil],
    "unused" => [%w[unused --format=json code.rb], nil],
    "show-bleedingedge" => [%w[show-bleedingedge --format=json], nil],
    "effects" => [%w[effects --format=json code.rb], nil],
    "triage" => [%w[triage --format=json code.rb], nil],
    "coverage precision" => [%w[coverage --format=json code.rb], "precision"],
    "coverage protection" => [%w[coverage --protection --format=json code.rb], "protection"],
    "plugins status" => [%w[plugins --format=json], "status"],
    "plugins capabilities" => [%w[plugins --capabilities --format=json], "capabilities"]
  }.each do |label, (argv, mode)|
    it "stamps #{label} with schema_version 1#{" and mode #{mode}" if mode}" do
      _, out, = run(*argv)
      doc = JSON.parse(out)
      expect(doc.keys.first).to eq("schema_version")
      expect(doc["schema_version"]).to eq(1)
      expect(doc["mode"]).to eq(mode)
    end
  end

  it "stamps coverage --protection --mutation with its mode" do
    _, out, = run("coverage", "--protection", "--mutation", "--format=json", "code.rb")
    expect(JSON.parse(out).first(2)).to eq([["schema_version", 1], %w[mode mutation]])
  end

  it "stamps the fused coverage report with its mode" do
    _, out, = run("coverage", "--protection", "--mutation", "--with-tests", "--test-command", "true",
                  "--format=json", "code.rb")
    expect(JSON.parse(out).first(2)).to eq([["schema_version", 1], %w[mode protection-fused]])
  end

  it "stamps effects diff" do
    File.write(".rigor.yml", "paths:\n  - \".\"\neffects:\n  snapshot:\n    reach: [\"*.rb\"]\n")
    run("effects", "update")
    File.write("code.rb", "def y = puts(1)\n")
    _, out, = run("effects", "diff", "--format=json")
    expect(JSON.parse(out).first(1)).to eq([["schema_version", 1]])
  end

  it "stamps sig-gen --check" do
    _, out, = run("sig-gen", "--check", "--format=json", "code.rb")
    expect(JSON.parse(out).first(1)).to eq([["schema_version", 1]])
  end

  it "stamps rigor diff, and reads a saved document that has no schema_version" do
    File.write("saved.json", JSON.generate({ "diagnostics" => [] }))
    File.write("current.json", JSON.generate({ "diagnostics" => [] }))
    _, out, = run("diff", "--format=json", "--current=current.json", "saved.json")
    expect(JSON.parse(out).first(1)).to eq([["schema_version", 1]])
  end
end
