# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/run_cache_key"
require "rigor/analysis/runner"
require "rigor/cache/engine_source"
require "rigor/cache/store"
require "rigor/configuration"

# Issue #285, acceptance — the defect was not "the key string omits a slot", it was that a warm
# `rigor check` REPLAYS pre-edit diagnostics after an engine edit, which is what makes a before/after
# measurement of an engine change report a fabricated zero. So every example here drives the real
# {Analysis::Runner} against a real on-disk {Cache::Store} and asserts on whether the analysis actually
# RAN, using the cross-file discovery pass the warm path is known to skip (the same observable
# `runner_lazy_prepass_spec` uses).
#
# The engine tree is relocated to a temporary directory for the duration, because the alternative is
# editing this checkout's own `lib/` from a spec. `engine_source_spec.rb` pins the un-relocated default.
RSpec.describe "run-result cache invalidation on an engine-source edit" do
  # The engine file an example edits — the very path whose edits used to be invisible.
  def engine_source(root)
    File.join(root, "lib", "rigor", "inference", "narrowing.rb")
  end

  def write_engine(dir, body)
    root = File.join(dir, "engine")
    FileUtils.mkdir_p(File.dirname(engine_source(root)))
    File.write(engine_source(root), body)
    allow(Rigor::Cache::EngineSource).to receive(:root).and_return(root)
    root
  end

  def edit_engine(root, body)
    File.write(engine_source(root), body)
  end

  # Two files, so cross-file discovery genuinely runs on a miss.
  def write_project(dir)
    lib = File.join(dir, "project", "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
    File.write(File.join(lib, "b.rb"), "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
    lib
  end

  # A FRESH Runner and a FRESH Store every time, so a hit has to come off disk rather than out of the
  # Store's in-process memo — which is what the next `rigor check` process would face.
  #
  # #289 — and a fresh {Cache::EngineSource} memo for the same reason. `process_identity` computes the
  # engine digest once per process ON PURPOSE (the loaded engine cannot change under a running analysis),
  # so an example simulating three successive `rigor` processes has to start each one where a real process
  # starts: without the previous one's answer. Left memoised, the edit below is invisible and this spec
  # passes while asserting nothing.
  def analyse(dir, lib, cache_root)
    Rigor::Cache::EngineSource.reset_process_identity!
    Dir.chdir(dir) do
      Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: Rigor::Cache::Store.new(root: cache_root), collect_stats: false
      ).run
    end
  end

  before do
    allow(Rigor::Inference::ScopeIndexer)
      .to receive(:discovered_project_index_for_paths).and_call_original
  end

  it "RECOMPUTES a warm run after an engine-source edit, instead of replaying the stale diagnostics" do
    Dir.mktmpdir("rigor-engine-source-run-") do |dir|
      lib = write_project(dir)
      engine = write_engine(dir, "# v1\n")
      cache_root = File.join(dir, ".rigor", "cache")

      cold = analyse(dir, lib, cache_root)
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).once

      # No edit: the cache is useful — the second run is SERVED, not recomputed.
      warm = analyse(dir, lib, cache_root)
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).once
      expect(warm.diagnostics.map(&:to_h)).to eq(cold.diagnostics.map(&:to_h))

      # The acceptance criterion: an engine edit alone — no project file, no config, no `sig/` moved —
      # makes the next warm run analyse again.
      edit_engine(engine, "# v2\n")
      after = analyse(dir, lib, cache_root)
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).twice
      expect(after.diagnostics.map(&:to_h)).to eq(cold.diagnostics.map(&:to_h))

      # And the post-edit result is itself cacheable: the key moved, it did not stop working.
      analyse(dir, lib, cache_root)
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).twice
    end
  end

  it "DISABLES the cache when the engine cannot be identified, rather than weakening the key" do
    Dir.mktmpdir("rigor-engine-source-run-") do |dir|
      lib = write_project(dir)
      cache_root = File.join(dir, ".rigor", "cache")
      allow(Rigor::Cache::EngineSource)
        .to receive(:identity).and_raise(Rigor::Cache::EngineSource::Unavailable)

      2.times { analyse(dir, lib, cache_root) }

      # Neither run was served: an unidentifiable engine means no cache, never a version-only fallback.
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_project_index_for_paths).twice
      expect(
        Rigor::Analysis::RunCacheKey.descriptor(
          configuration: Rigor::Configuration.new("paths" => [lib]), files: [], explain: false,
          rbs_config_entries: []
        )
      ).to be_nil
    end
  end

  it "leaves a released gem's key composition exactly as it was" do
    configuration = Rigor::Configuration.new({})
    args = { configuration: configuration, files: ["a.rb"], explain: false, rbs_config_entries: [] }

    checkout = Rigor::Analysis::RunCacheKey.descriptor(**args)
    allow(Rigor::Cache::EngineSource).to receive(:identity).and_return(nil)
    Rigor::Cache::EngineSource.reset_process_identity! # the released gem is a SECOND process (#289)
    released = Rigor::Analysis::RunCacheKey.descriptor(**args)

    expect(released.configs.map(&:key)).to contain_exactly("configuration", "engine", "paths")
    expect(checkout.configs.map(&:key)).to include("engine-source")
    expect(released.to_canonical_hash).not_to eq(checkout.to_canonical_hash)
  end
end
