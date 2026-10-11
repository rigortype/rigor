# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/run_cache_key"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

# Issue #1814 — a walked gem's source (its method catalogue, its refinement table, which modules it read in full)
# reaches every file's checks, and no analysed file records it. The lockfile digest covers a `bundle update` and
# nothing else, so a project with no lockfile would replay a gem's previous version out of a warm cache. The run's
# cache key and the incremental snapshot's fingerprint therefore carry the `(name, version, mode)` rows of the gems
# `dependencies.source_inference` lists (ADR-10 slice 3), and a project that lists none keeps the key it had.
# `spec/integration/gem_source_refinement_spec.rb` drives the same bump through a real cached run.
RSpec.describe "cache identity of dependencies.source_inference gems" do
  let(:resolver) { Rigor::Analysis::DependencySourceInference::GemResolver }

  def configuration(*gems)
    entries = gems.map { |name| { "gem" => name, "mode" => "when_missing" } }
    Rigor::Configuration.new("paths" => ["lib"], "dependencies" => { "source_inference" => entries })
  end

  def stub_version(name, version)
    allow(resolver).to receive(:locate_gem_spec).with(name).and_return(
      instance_double(Gem::Specification, version: Gem::Version.new(version), full_gem_path: "/gems/#{name}")
    )
  end

  def key(configuration)
    Rigor::Analysis::RunCacheKey.descriptor(configuration: configuration, files: ["lib/app.rb"], explain: false,
                                            rbs_config_entries: [])
  end

  def fingerprint(configuration)
    Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
  end

  it "keys the run-result cache on a listed gem's version" do
    stub_version("shouty", "1.0.0")
    before = key(configuration("shouty"))
    stub_version("shouty", "1.1.0")
    after = key(configuration("shouty"))

    expect(before.dependencies.map { |row| [row.gem_name, row.gem_version, row.mode] })
      .to eq([["shouty", "1.0.0", :when_missing]])
    expect(after.cache_key_for(producer_id: "analysis.run-diagnostics"))
      .not_to eq(before.cache_key_for(producer_id: "analysis.run-diagnostics"))
  end

  it "keeps the key a repeated run with the same version had" do
    stub_version("shouty", "1.0.0")
    first = key(configuration("shouty")).cache_key_for(producer_id: "p")
    second = key(configuration("shouty")).cache_key_for(producer_id: "p")

    expect(second).to eq(first)
  end

  it "keys the incremental snapshot's fingerprint on a listed gem's version" do
    stub_version("shouty", "1.0.0")
    before = fingerprint(configuration("shouty"))
    stub_version("shouty", "1.1.0")

    expect(fingerprint(configuration("shouty"))).not_to eq(before)
    stub_version("shouty", "1.0.0")
    expect(fingerprint(configuration("shouty"))).to eq(before)
  end

  # A project that lists no gem has no row to add, and a gem the bundle lacks has no version to key on.
  it "adds nothing for a project that lists no gem, and for a gem the bundle lacks" do
    allow(resolver).to receive(:locate_gem_spec).with("ghost").and_return(nil)

    expect(key(configuration).dependencies).to eq([])
    expect(key(configuration("ghost")).dependencies).to eq([])
  end
end
