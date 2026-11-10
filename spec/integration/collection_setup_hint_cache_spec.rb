# frozen_string_literal: true

# Issue #3030 — the `rbs.coverage.collection-not-installed` hint is a run-level row read off the working directory (an
# `rbs_collection.yaml` with no lockfile), so the run-result cache key and the `--incremental` fingerprint carry it:
# a warm run answers what a cold one would when the file comes or goes.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/run_cache_key"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "the rbs collection setup hint through the caches (#3030)" do
  around do |example|
    Dir.mktmpdir("rigor-collection-hint-cache-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:rule) { "rbs.coverage.collection-not-installed" }

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def hint_rules(cache_store)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store)
    guarded_run(runner, ["lib/a.rb"]).diagnostics.map(&:rule).select { |name| name == rule }
  end

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "1\n")
  end

  it "reports the hint warm as cold when rbs_collection.yaml appears, and drops it when the file goes" do
    root = File.join(Dir.pwd, ".rigor", "cache")
    expect(hint_rules(Rigor::Cache::Store.new(root: root))).to eq([])

    File.write("rbs_collection.yaml", "sources: []\n")
    expect(hint_rules(nil)).to eq([rule])
    expect(hint_rules(Rigor::Cache::Store.new(root: root))).to eq([rule])

    File.delete("rbs_collection.yaml")
    expect(hint_rules(Rigor::Cache::Store.new(root: root))).to eq([])
  end

  it "moves the incremental fingerprint with the hint, and keeps it without one" do
    before = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
    File.write("rbs_collection.yaml", "sources: []\n")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"]))
      .not_to eq(before)
    File.delete("rbs_collection.yaml")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])).to eq(before)
  end
end
