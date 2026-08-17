# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/effects_command"

# ADR-103 #379 — `rigor effects`, the bare report. The table it prints is pinned in
# `spec/rigor/effects/tracer_collection_spec.rb`; this file pins the command surface: the two formats,
# the omission rule, the exit codes, and the ad-hoc opt-in that lets the command run against a project
# whose configuration carries no `effects:` block.
RSpec.describe Rigor::CLI::EffectsCommand do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  # `Configuration.load(nil)` discovers the repository's own `.rigor.yml`, which has no `effects:` block;
  # running from an empty directory proves the command's implicit `effects: {}` is what turns collection
  # on rather than any project setting.
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "prints one line per method, sorted by key, with the proven labels" do
    status, out, = run([fixture])

    expect(status).to eq(0)
    expect(out).to include("Tracer::Reporter#report: [io.output.stdout, nondet.time]\n")
    expect(out.lines.grep(/^Tracer/).map { |line| line.split(":").first }).to eq(out.lines.grep(/^Tracer/)
      .map { |line| line.split(":").first }.sort)
  end

  it "suffixes a non-exhaustive method and lists the causes under it" do
    _, out, = run([fixture])

    expect(out).to include("Tracer::Gateway#dispatch: [] …?\n    dynamic-send\n")
    expect(out).to include("Tracer::Gateway#probe: [] …?\n    dynamic-receiver (inferred_return_untyped)\n")
  end

  # Omission rule: exhaustive AND proving nothing beyond `mutate.local`, which every envelope tolerates.
  it "omits a pure method by default and lists it under --full" do
    _, default, = run([fixture])
    _, full, = run(["--full", fixture])

    expect(default).not_to include("Tracer::Reporter#collect")
    expect(default).not_to include("Tracer::Reporter#label")
    expect(full).to include("Tracer::Reporter#collect: [mutate.local]\n")
    expect(full).to include("Tracer::Reporter#label: []\n")
  end

  it "emits the methods table under --format json" do
    status, out, = run(["--format", "json", fixture])
    payload = JSON.parse(out)

    expect(status).to eq(0)
    expect(payload.dig("methods", "Tracer::Reporter#report")).to eq(
      "effects" => %w[io.output.stdout nondet.time],
      "declared" => [],
      "exhaustive" => true,
      "causes" => [],
      "direct" => { "catalogue:Kernel#puts" => ["io.output.stdout"], "catalogue:Time.now" => ["nondet.time"] }
    )
  end

  it "reports the taint causes as [cause, detail] pairs in JSON" do
    _, out, = run(["--format", "json", fixture])

    expect(JSON.parse(out).dig("methods", "Tracer::Gateway#probe", "causes"))
      .to eq([%w[dynamic-receiver inferred_return_untyped]])
  end

  it "rejects an unsupported format with the documented usage status" do
    status, _out, err = run(["--format=xml", fixture])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("unsupported format: xml")
  end

  it "is registered as a CLI subcommand" do
    expect(Rigor::CLI::HANDLERS).to include("effects" => :run_effects)
    expect(Rigor::CLI.new([], out: StringIO.new, err: StringIO.new).send(:help)).to include("effects")
  end
end
