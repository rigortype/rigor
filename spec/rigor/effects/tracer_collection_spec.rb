# frozen_string_literal: true

require "rigor"

# ADR-103 #379 — the tracer slice end to end: `rigor check`'s own analysis, with collection on, over the
# fixture app in `spec/integration/fixtures/effects/tracer`. Each example pins one shape the collector has
# to record; the CLI's rendering of the same table is `spec/rigor/cli/effects_command_spec.rb`.
RSpec.describe "effect collection over the tracer fixture" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def configuration(effects: true, workers: 0)
    data = { "paths" => [fixture], "parallel" => { "workers" => workers } }
    data["effects"] = {} if effects
    Rigor::Configuration.new(data)
  end

  def analyze(configuration)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    diagnostics = runner.run([fixture]).diagnostics
    [runner, diagnostics]
  end

  let(:table) { analyze(configuration).first.effect_table }

  it "colours a catalogued origin and keeps its bundle per origin" do
    entry = table["Tracer::Reporter#report"]

    expect(entry.proven.to_a).to eq(%w[io.output.stdout nondet.time])
    expect(entry.direct.bundles.keys.map(&:to_s)).to include("catalogue:Kernel#puts", "catalogue:Time.now")
  end

  it "propagates a callee's labels to its caller while the direct summary stays the caller's own" do
    entry = table["Tracer::Reporter#announce"]

    expect(entry.proven.to_a).to eq(%w[io.output.stdout nondet.time])
    expect(entry.direct.proven).to be_empty
    expect(entry.edges).to eq(["Tracer::Reporter#report"])
  end

  it "terminates on mutual recursion" do
    expect(table["Tracer::Reporter#ping"].proven).to be_empty
    expect(table["Tracer::Reporter#ping"]).to be_exhaustive
    expect(table["Tracer::Reporter#pong"].edges).to eq(["Tracer::Reporter#ping"])
  end

  it "colours the language constructs the catalogue does not cover" do
    expect(table["Tracer::Reporter#shell"].proven.to_a).to eq(["io.process"])
    expect(table["Tracer::Reporter#flag"].proven.to_a).to eq(["global.write"])
  end

  it "keys a literal-named define_method as a method of its class" do
    expect(table["Tracer::Reporter#generated"].proven.to_a).to eq(["io.output.stderr"])
  end

  it "synthesises an attr_reader as an exhaustive, effect-free method" do
    expect(table["Tracer::Reporter#label"].proven).to be_empty
    expect(table["Tracer::Reporter#label"]).to be_exhaustive
  end

  it "proves mutate.local for a frame-owned local and mutate.self for an ivar write" do
    expect(table["Tracer::Reporter#collect"].proven.to_a).to eq(["mutate.local"])
    expect(table["Tracer::Reporter#initialize"].proven.to_a).to eq(["mutate.self"])
  end

  it "joins every project-known override of a call's target, across files" do
    expect(table["Tracer::Dispatcher#run"].proven.to_a).to eq(["io.output.stdout"])
  end

  describe "taint causes" do
    {
      "Tracer::Gateway#fetch" => "dynamic-receiver",
      "Tracer::Gateway#dispatch" => "dynamic-send",
      "Tracer::Gateway#run_callback" => "opaque-callable",
      "Tracer::Gateway#missing_helper" => "unresolved-self-call",
      "Tracer::Gateway#unowned" => "unknown-ownership"
    }.each do |key, cause|
      it "records #{cause} and never a finding" do
        expect(table[key]).not_to be_exhaustive
        expect(table[key].causes.map(&:first)).to eq([cause])
      end
    end

    it "carries the DynamicOrigin cause name as the taint's detail" do
      expect(table["Tracer::Gateway#probe"].causes).to eq([%w[dynamic-receiver inferred_return_untyped]])
    end

    # An unprovable ownership is recorded as taint, never as a proven bare `mutate` (ADR-103 WD14): a
    # wrong parent label on a fresh-but-unproven receiver would put findings on correct code.
    it "never proves a mutate label it could not classify" do
      expect(table["Tracer::Gateway#unowned"].proven).to be_empty
    end

    # A write is a write whatever the receiver's type is, so the proven half survives the taint.
    it "proves mutate.instance on a parameter alongside the taint for the unknown callee" do
      entry = table["Tracer::Gateway#append"]

      expect(entry.proven.to_a).to eq(["mutate.instance"])
      expect(entry).not_to be_exhaustive
    end
  end

  # #381 — where each unit was written. The merged collection deliberately drops it (a summary is line-
  # and file-free), but the snapshot's `reach:` table names its entry points by FILE glob, so the key has
  # to be traceable back to the file.
  it "reports which file each unit was defined in" do
    sources = analyze(configuration).first.effect_sources

    expect(sources.fetch("Tracer::Loud#emit").map { |path| File.basename(path) }).to eq(["loud.rb"])
    expect(sources.fetch("Tracer::Reporter#report").map { |path| File.basename(path) }).to eq(["app.rb"])
  end

  # The active `workers > 0` backend is fork (ADR-15 Amendment); the per-file collections marshal back
  # with the file's diagnostics, so the graph a pooled run closes must be the sequential one.
  it "produces the same table pooled as sequentially" do
    sequential = analyze(configuration).first.effect_table
    pooled = analyze(configuration(workers: 2)).first.effect_table

    expect(pooled.keys).to eq(sequential.keys)
    expect(pooled.map { |entry| [entry.key, entry.proven.to_a, entry.exhaustive?, entry.causes] })
      .to eq(sequential.map { |entry| [entry.key, entry.proven.to_a, entry.exhaustive?, entry.causes] })
  end

  describe "with no effects: block" do
    it "never activates the collector and answers an empty table" do
      runner, = analyze(configuration(effects: false))

      expect(Rigor::Effects::Collector).not_to be_active
      expect(runner.effect_table).to be_empty
    end

    # The coexistence gate: collection is observational, so turning it on cannot move a diagnostic.
    it "produces byte-identical diagnostics either way" do
      off = analyze(configuration(effects: false)).last
      on = analyze(configuration).last

      expect(on.map(&:to_s)).to eq(off.map(&:to_s))
    end
  end

  # Fail-soft (ADR-103 WD13): an exception inside the collector drops that file's summaries and never
  # alters or fails the check that was running.
  it "keeps the run green when the collector raises" do
    allow(Rigor::Effects::Scanner).to receive(:scan).and_raise("boom")
    expected = analyze(configuration(effects: false)).last.map(&:to_s)

    runner, diagnostics = analyze(configuration)

    expect(diagnostics.map(&:to_s)).to eq(expected)
    expect(runner.effect_table).to be_empty
    expect(runner.effect_collection).to be_failed
  end
end
