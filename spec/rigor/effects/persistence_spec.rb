# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor"
require "rigor/cli/check_command"
require "rigor/cli/effects_command"

# ADR-103 WD13 / issue #382 — "one cache, two identities, one extra slot" end to end.
#
# The property under test is not "effects are faster warm"; it is that the two identities are genuinely
# independent. A diagnostics entry is valid whichever way `effects:` is set, and an effects entry is a miss
# for effects consumers *only* — so every example below asserts what happened to BOTH slots, not just the
# one it is about.
RSpec.describe "effect-summary persistence" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def configuration(effects: true, root: fixture)
    data = { "paths" => [root] }
    data["effects"] = {} if effects
    Rigor::Configuration.new(data)
  end

  # One analysis against `cache_root`, through a fresh `Store` so its counters describe exactly this run
  # (the Store memoises in-process, which would otherwise make a second run in one example a memo hit
  # rather than the disk hit the slot exists to provide).
  def analyze(cache_root, effects: true, root: fixture)
    store = Rigor::Cache::Store.new(root: cache_root)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(effects: effects, root: root),
      cache_store: store, collect_stats: false, workers: 0
    )
    diagnostics = runner.run([root]).diagnostics
    [runner, store, diagnostics]
  end

  def producer_counts(store, producer)
    store.stats[:by_producer][producer] || { hits: 0, misses: 0, writes: 0 }
  end

  def diagnostics_counts(store)
    producer_counts(store, Rigor::Analysis::RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID)
  end

  def units(table)
    table.keys.to_h { |symbol| [symbol, table[symbol].proven.to_a] }
  end

  around do |example|
    Dir.mktmpdir do |cache|
      @cache = cache
      example.run
    end
  end

  attr_reader :cache

  it "serves a second collecting run's summaries from the sidecar and re-runs only the fixpoint" do
    cold, _cold_store, = analyze(cache)
    warm, warm_store, = analyze(cache)

    expect(cold.effects_served_from_cache?).to be(false)
    expect(warm.effects_served_from_cache?).to be(true)
    # The whole point: a warm run's table is the cold run's table. The fixpoint ran; the collection did not.
    expect(units(warm.effect_table)).to eq(units(cold.effect_table))
    expect(warm.effect_sources).to eq(cold.effect_sources)
    expect(diagnostics_counts(warm_store)[:hits]).to eq(1)
  end

  it "treats a diagnostics-only warm entry as an effects miss and leaves the diagnostics slot untouched" do
    analyze(cache, effects: false)
    runner, store, = analyze(cache)

    # The diagnostics entry was written by a run with collection OFF and still validates for a run with it
    # ON — the diagnostics identity does not know effects exist.
    expect(diagnostics_counts(store)[:hits]).to eq(1)
    expect(diagnostics_counts(store)[:writes]).to eq(0)
    # …and the effects consumer got a real table anyway, by re-running the analysis for its own slot.
    expect(runner.effects_served_from_cache?).to be(false)
    expect(runner.effect_table["Tracer::Reporter#report"].proven.to_a).to eq(%w[io.output.stdout nondet.time])
  end

  it "ignores the sidecar entirely when collection is off" do
    analyze(cache)
    runner, store, = analyze(cache, effects: false)

    expect(diagnostics_counts(store)[:hits]).to eq(1)
    expect(runner.effects_served_from_cache?).to be(false)
    expect(runner.effect_table).to be_empty
  end

  it "invalidates the effects slot on a vocabulary bump and not the diagnostics slot" do
    analyze(cache)

    real = Rigor::Effects::Registry.default
    bumped = Rigor::Effects::Registry.new(vocabulary_version: real.vocabulary_version + 1, labels: real.labels)
    allow(Rigor::Effects::Registry).to receive(:default).and_return(bumped)
    runner, store, = analyze(cache)

    expect(runner.effects_served_from_cache?).to be(false)
    expect(diagnostics_counts(store)[:hits]).to eq(1)
    expect(diagnostics_counts(store)[:writes]).to eq(0)
  end

  it "keys the effects slot on the `effects:` block, so a policy edit re-collects" do
    analyze(cache)

    store = Rigor::Cache::Store.new(root: cache)
    edited = Rigor::Configuration.new("paths" => [fixture], "effects" => { "tolerated" => ["nondet.time"] })
    runner = Rigor::Analysis::Runner.new(
      configuration: edited, cache_store: store, collect_stats: false, workers: 0
    )
    runner.run([fixture])

    expect(runner.effects_served_from_cache?).to be(false)
    expect(diagnostics_counts(store)[:hits]).to eq(1)
  end

  it "reads a corrupt sidecar as a miss and completes the run" do
    analyze(cache)
    entries = Dir.glob(File.join(cache, Rigor::Analysis::RunCacheKey::RUN_EFFECTS_PRODUCER_ID, "**", "*.entry"))
    expect(entries.size).to eq(1)
    File.binwrite(entries.first, "not an entry")

    runner, store, diagnostics = analyze(cache)

    expect(runner.effects_served_from_cache?).to be(false)
    expect(runner.effect_table["Tracer::Reporter#report"].proven.to_a).to eq(%w[io.output.stdout nondet.time])
    expect(diagnostics).not_to be_nil
    expect(diagnostics_counts(store)[:hits]).to eq(1)
  end

  # The acceptance case ADR-103 WD13 names: the snapshot verbs go through the same cache `rigor check` does,
  # so a job that checks and then gates on the snapshot pays for one analysis.
  describe "through the CLI" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.cp(Dir.glob(File.join(fixture, "*.rb")), dir)
        Dir.chdir(dir) do
          File.write(".rigor.yml", "paths:\n  - \".\"\neffects:\n  snapshot:\n    reach: [\"*.rb\"]\n")
          example.run
        end
      end
    end

    def effects(*argv)
      out = StringIO.new
      err = StringIO.new
      status = Rigor::CLI::EffectsCommand.new(argv: argv, out: out, err: err).run
      [status, out.string, err.string]
    end

    # A warm collecting run never activates the collector: that is what "served from the sidecar" means
    # from the outside, and it is observable without reaching into the runner.
    def collected_files
      seen = []
      allow(Rigor::Effects::Collector).to receive(:collect_for).and_wrap_original do |original, path, &block|
        seen << path
        original.call(path, &block)
      end
      seen
    end

    it "writes a byte-identical snapshot warm and cold, without re-collecting" do
      expect(effects("update").first).to eq(0)
      cold = File.read(".rigor-effects.yml")
      FileUtils.rm_f(".rigor-effects.yml")

      seen = collected_files
      expect(effects("update").first).to eq(0)

      expect(File.read(".rigor-effects.yml")).to eq(cold)
      expect(seen).to be_empty
    end

    # WD13's acceptance sentence, in the order a CI job runs it: `rigor check` under a configured `effects:`
    # block warms BOTH slots, and everything the snapshot verbs do afterwards is a hit plus the fixpoint.
    it "serves the snapshot verbs from the entry `rigor check` warmed in the same job" do
      status = Rigor::CLI::CheckCommand.new(
        argv: ["--no-stats"], out: StringIO.new, err: StringIO.new
      ).run
      expect(status).to be_a(Integer)

      seen = collected_files
      expect(effects("update").first).to eq(0)
      expect(effects("check").first).to eq(0)

      expect(seen).to be_empty
    end
  end
end
