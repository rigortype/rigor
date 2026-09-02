# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/project_scan"
require "rigor/cache/engine_source"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"
require "rigor/inference/project_patched_methods"
require "rigor/inference/synthetic_method_index"
require "rigor/protection/mutation_cache"
require "rigor/protection/mutation_scanner"

# Issue #134 slice 2 — the per-file mutation-result cache. Every example drives the real {Cache::Store} over a
# real on-disk ADR-46 snapshot, because the whole class is an argument about cache IDENTITY: a test that
# stubbed the key would assert the stub.
#
# The snapshot is written directly rather than by running `rigor check --incremental`, so a spec can state the
# dependency edge it wants (`a.rb` reads from `dep.rb`) instead of arranging a project that happens to produce
# it. `IncrementalSnapshot#load_any` is the only thing being bypassed, and it is exercised on its own below.
RSpec.describe Rigor::Protection::MutationCache do
  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  let(:configuration) { Rigor::Configuration.new({}) }
  let(:project_scan) do
    Rigor::Analysis::ProjectScan.new(
      plugin_registry: nil,
      dependency_source_index: nil,
      synthetic_method_index: Rigor::Inference::SyntheticMethodIndex.new,
      project_patched_methods: Rigor::Inference::ProjectPatchedMethods::EMPTY,
      plugin_prepare_diagnostics: [],
      pre_eval_diagnostics: []
    )
  end
  let(:sampling) { described_class::Sampling.new(limit: nil, seed: 1, site_selector: :biteable) }
  let(:result) do
    Rigor::Protection::MutationScanner::FileResult.new(path: "a.rb", killed: 2, survived: 1, sites: [])
  end

  # Writes the measured file + the file it depends on, and persists a snapshot recording exactly that edge.
  def write_project(config = configuration)
    File.write("a.rb", %(def m\n  "x".upcase\nend\n))
    File.write("dep.rb", "class Dep\nend\n")
    save_snapshot(config)
  end

  def save_snapshot(config, roots: nil)
    Rigor::Cache::IncrementalSnapshot.new(root: config.cache_path).save(
      fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(
        configuration: config, roots: roots || config.paths
      ),
      payload: payload
    )
  end

  def payload
    Rigor::Cache::IncrementalSnapshot::Payload.new(
      cache: {}, sources: { "a.rb" => Set["dep.rb"], "dep.rb" => Set.new },
      digests: {}, analyzed: ["a.rb", "dep.rb"],
      symbol_sources: {}, ancestry_sources: {}, symbol_fingerprints: {},
      missing: {}, class_decls: {}, constant_decls: {}, seed_bundles: {}, plugin_fact_digest: nil,
      return_summaries: {}, param_table: {},
      effect_collections: {}, effects_identity: nil
    )
  end

  # A FRESH cache instance every time: an entry must survive to disk and be re-validated there, which is what
  # the next `rigor coverage` process will do. Sharing one instance could pass on the Store's in-process memo.
  # #289 — each `cache` is a distinct simulated measurement process, so it starts with a fresh
  # {Cache::EngineSource} memo the way a real one does. `process_identity` computes the engine digest once
  # per process deliberately (the loaded engine cannot change under a running measurement); carried across
  # the calls below it would hide the engine edit — and, since `write_project` now populates the memo
  # through the snapshot fingerprint, it would also outrank a stub installed after it.
  def cache(config: configuration, sampling: self.sampling, feature_ids: [], seed_inputs: nil,
            bypass_reason: nil)
    Rigor::Cache::EngineSource.reset_process_identity!
    described_class.build(
      configuration: config, roots: config.paths, project_scan: project_scan, sampling: sampling,
      feature_ids: feature_ids, seed_inputs: seed_inputs, bypass_reason: bypass_reason
    )
  end

  def store_result(**)
    cache(**).store("a.rb", result)
  end

  it "serves a stored result back on an unchanged re-run" do
    write_project
    expect(cache.enabled?).to be(true)
    expect(store_result).to be(true)

    warm = cache
    expect(warm.fetch("a.rb")).to eq(result)
    expect(warm.hits).to eq(1)
  end

  it "misses after the measured file itself is edited" do
    write_project
    store_result
    File.write("a.rb", %(def m\n  "x".downcase\nend\n))

    expect(cache.fetch("a.rb")).to be_nil
  end

  it "misses after a file in deps[A] is edited" do
    write_project
    store_result
    File.write("dep.rb", "class Dep\n  def extra = 1\nend\n")

    expect(cache.fetch("a.rb")).to be_nil
  end

  it "misses a file the snapshot never analysed (no deps entry means 'depends on everything')" do
    write_project
    File.write("b.rb", %(def n\n  "y".upcase\nend\n))
    warm = cache

    expect(warm.store("b.rb", result)).to be(false)
    expect(warm.fetch("b.rb")).to be_nil
  end

  it "disables itself when no snapshot is reusable" do
    File.write("a.rb", %(def m\n  "x".upcase\nend\n))
    cold = cache

    expect(cold.enabled?).to be(false)
    expect(cold.reason).to eq(described_class::NO_SNAPSHOT)
    expect(cold.fetch("a.rb")).to be_nil
  end

  it "misses after a configuration change, under the snapshot the re-warmed session writes" do
    write_project
    store_result

    edited = Rigor::Configuration.new({ "target_ruby" => "3.4" })
    save_snapshot(edited)

    expect(cache(config: edited).fetch("a.rb")).to be_nil
  end

  it "misses after a `sig/` edit, under the snapshot the re-warmed session writes" do
    signed = Rigor::Configuration.new({ "signature_paths" => ["sig"] })
    FileUtils.mkdir_p("sig")
    File.write("sig/a.rbs", "class Foo\nend\n")
    write_project(signed)
    store_result(config: signed)

    File.write("sig/a.rbs", "class Foo\n  def bar: () -> Integer\nend\n")
    save_snapshot(signed)

    expect(cache(config: signed).fetch("a.rb")).to be_nil
  end

  it "misses after --seed or --limit changes" do
    write_project
    store_result

    reseeded = described_class::Sampling.new(limit: nil, seed: 7, site_selector: :biteable)
    capped = described_class::Sampling.new(limit: 5, seed: 1, site_selector: :biteable)

    expect(cache(sampling: reseeded).fetch("a.rb")).to be_nil
    expect(cache(sampling: capped).fetch("a.rb")).to be_nil
    # Non-vacuity: the unchanged sampling still hits, so the two misses are the sampling slot and not a
    # blanket invalidation.
    expect(cache.fetch("a.rb")).to eq(result)
  end

  # #255's principle — a behaviour feature's id is part of the cache identity of everything it changes.
  # `discovery-seeded-mutation-sites` moves both the denominator and the kills, so a result measured without
  # it must never be served to a run that adopted it.
  it "misses after a bleeding-edge behaviour feature is adopted" do
    write_project
    store_result

    adopted = cache(feature_ids: ["discovery-seeded-mutation-sites"], seed_inputs: ["a.rb", "dep.rb"])
    expect(adopted.fetch("a.rb")).to be_nil
  end

  it "misses when the discovery seed's inputs move, while the feature stays adopted" do
    write_project
    ids = ["discovery-seeded-mutation-sites"]
    seed_inputs = ["a.rb", "dep.rb"]
    store_result(feature_ids: ids, seed_inputs: seed_inputs)
    expect(cache(feature_ids: ids, seed_inputs: seed_inputs).fetch("a.rb")).to eq(result)

    # The seed spans the whole measured set, so a sibling file's edit is an input change for EVERY file —
    # including one whose own `deps` never named it.
    File.write("dep.rb", "class Dep\n  def extra = 2\nend\n")
    expect(cache(feature_ids: ids, seed_inputs: seed_inputs).fetch("a.rb")).to be_nil
  end

  # #285 — `Rigor::VERSION` identifies the engine's bytes only for a released gem, and a mutation score is
  # measured almost exclusively FROM a checkout, by someone who just changed the analyzer. Serving the
  # pre-edit kill counts back would invert the exact signal the measurement exists to produce.
  describe "the engine's own source" do
    def with_engine_tree(body)
      root = File.join(Dir.pwd, "engine")
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "narrowing.rb"), body)
      allow(Rigor::Cache::EngineSource).to receive(:root).and_return(root)
      root
    end

    # The engine tree is relocated BEFORE `write_project`, which since #289 is load-bearing: the snapshot
    # fingerprint folds in the engine identity too, so a snapshot saved against the real checkout would not
    # match a `build` that sees the stand-in tree, and the example would pass on NO_SNAPSHOT without ever
    # reaching the key it means to test.
    it "misses after the engine is edited, with every other input unmoved" do
      root = with_engine_tree("# v1\n")
      write_project
      store_result
      expect(cache.fetch("a.rb")).to eq(result)

      # #289 — the snapshot fingerprint now moves on this edit as well, so the outer gate fires first and
      # the miss arrives as a disabled cache rather than a key miss. Asserted on the property either way:
      # an engine edit never serves pre-edit kill counts back.
      File.write(File.join(root, "lib", "narrowing.rb"), "# v2\n")
      expect(cache.fetch("a.rb")).to be_nil
    end

    it "disables itself when the engine cannot be identified, rather than keying on VERSION alone" do
      write_project
      allow(Rigor::Cache::EngineSource)
        .to receive(:identity).and_raise(Rigor::Cache::EngineSource::Unavailable)
      cold = cache

      expect(cold.enabled?).to be(false)
      expect(cold.reason).to eq(described_class::UNIDENTIFIED_ENGINE)
      expect(cold.store("a.rb", result)).to be(false)
      expect(cold.fetch("a.rb")).to be_nil
    end

    it "adds no slot for a released gem, leaving its key composition unchanged" do
      allow(Rigor::Cache::EngineSource).to receive(:identity).and_return(nil)

      expect(described_class.engine_source_entries).to eq([])
    end
  end

  # #254 — the dependent-closure oracle makes a file's verdict depend on its DEPENDENTS' diagnostics, which
  # `deps[A]` cannot validate. The caller passes a bypass reason rather than a key.
  it "runs uncached under a caller-supplied bypass" do
    write_project
    bypassed = cache(bypass_reason: "dependent-closure-kill-oracle")

    expect(bypassed.enabled?).to be(false)
    expect(bypassed.reason).to eq("dependent-closure-kill-oracle")
    expect(bypassed.store("a.rb", result)).to be(false)
    expect(bypassed.fetch("a.rb")).to be_nil
    # And nothing was written behind the bypass: a later un-bypassed run still misses.
    expect(cache.fetch("a.rb")).to be_nil
  end

  # #267 — a run where mutants blew up inside the measurement harness measured the harness, not the code.
  # Freezing it into a warm hit would make a transient failure permanent and invisible.
  it "never persists a result carrying harness errors" do
    write_project
    degraded = Rigor::Protection::MutationScanner::FileResult.new(
      path: "a.rb", killed: 2, survived: 1, sites: [], harness_errors: 1
    )

    expect(cache.store("a.rb", degraded)).to be(false)
    expect(cache.fetch("a.rb")).to be_nil
    # The clean result for the same file still stores, so the refusal is about the degradation and not the
    # file.
    expect(store_result).to be(true)
  end

  # A snapshot is keyed to the roots its writing run was invoked with, and a measurement of a SUBDIRECTORY
  # shares none of them. The configured `paths:` are offered as a candidate for exactly this case — the
  # dependency edges are per-file, so a wider snapshot is usable and a narrower one just yields misses.
  it "accepts the snapshot a whole-project warm-up wrote while measuring a subdirectory" do
    write_project
    subdirectory = described_class.build(
      configuration: configuration, roots: ["lib/rigor/protection"], project_scan: project_scan,
      sampling: sampling, feature_ids: []
    )

    expect(subdirectory.enabled?).to be(true)
  end

  it "declines a snapshot written under unrelated roots" do
    write_project
    save_snapshot(configuration, roots: ["some/other/tree"])

    expect(cache.reason).to eq(described_class::NO_SNAPSHOT)
  end
end
