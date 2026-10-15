# frozen_string_literal: true

# Issue #1559 — the ADR-45 run-result key named the analysed FILES but not the roots they came from, so
# `check lib extra` (with `extra` missing) and `check lib` shared a slot: one was served the other's
# `extra: no such file or directory (skipped)` row, or lost it, and `--fail-on=warning` flipped with it.
# Both readers are exercised against a real `Cache::Store`: the runner's own read-through slot and the
# engine-free {RunCacheProbe}, and a served answer is judged against a cold run of the same roots.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/run_cache_probe"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "the run-result key and the analysis roots (#1559)" do
  around do |example|
    Dir.mktmpdir("rigor-run-key-roots-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }
  let(:configuration) do
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  let(:skipped) { [["extra", :warning, "no such file or directory (skipped)"]] }

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "x = 1\n")
  end

  def rows(diagnostics)
    diagnostics.map { |d| [d.path, d.severity, d.message] }
  end

  def cold(roots)
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), roots).diagnostics)
  end

  # The runner's own slot. A fresh `Cache::Store` per call, as a fresh process would have.
  def through_runner(roots)
    store = Rigor::Cache::Store.new(root: cache_root)
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store), roots).diagnostics)
  end

  def probe(roots)
    result = Rigor::Analysis::RunCacheProbe.new(
      configuration: configuration, cache_root: cache_root, explain: false
    ).serve(roots)
    result && rows(result.diagnostics)
  end

  it "does not serve the missing-root warning to the run without that root" do
    expect(through_runner(%w[lib extra])).to eq(skipped)

    expect(through_runner(%w[lib])).to eq(cold(%w[lib]))
    expect(through_runner(%w[lib])).to eq([])
    expect(through_runner(%w[lib extra])).to eq(skipped)
  end

  it "does not drop the missing-root warning when the run without that root went first" do
    expect(through_runner(%w[lib])).to eq([])

    expect(through_runner(%w[lib extra])).to eq(cold(%w[lib extra]))
    expect(through_runner(%w[lib extra])).to eq(skipped)
  end

  it "keeps the engine-free probe from answering one root set out of the other's slot" do
    through_runner(%w[lib extra])

    expect(probe(%w[lib])).to be_nil
    expect(probe(%w[lib extra])).to eq(skipped)

    through_runner(%w[lib])
    expect(probe(%w[lib])).to eq([])
    expect(probe(%w[lib extra])).to eq(skipped)
  end

  it "still serves a warm run over identical roots, with no recomputation" do
    through_runner(%w[lib extra])

    expect(probe(%w[lib extra])).to eq(skipped)
    runner = Rigor::Analysis::Runner.new(configuration: configuration,
                                         cache_store: Rigor::Cache::Store.new(root: cache_root))
    guarded_run(runner, %w[lib extra])
    expect(runner.instance_variable_get(:@run_served_from_cache)).to be(true)
  end

  it "serves the configured roots when no path argument is given" do
    through_runner(configuration.paths)

    expect(probe(configuration.paths)).to eq([])
    expect(probe(%w[lib extra])).to be_nil
  end

  # The roots are keyed as written. A spelling or an order that could change the printed rows (a missing root
  # is reported as written; the roots list their files in the order given) must not share a slot.
  it "keeps a respelled or reordered root set in a slot of its own" do
    File.write("lib/b.rb", "y = 2\n")
    through_runner(%w[lib extra])

    expect(probe(%w[extra lib])).to be_nil
    expect(probe(%w[./lib extra])).to be_nil
    expect(probe(%w[lib/ extra])).to be_nil
    expect(probe(%w[lib ./extra])).to be_nil
    expect(probe([File.expand_path("lib"), "extra"])).to be_nil
  end

  it "keys a file root apart from the directory holding it" do
    through_runner(%w[lib])

    expect(probe(%w[lib/a.rb])).to be_nil
    expect(through_runner(%w[lib/a.rb])).to eq(cold(%w[lib/a.rb]))
    expect(probe(%w[lib])).to eq([])
  end
end
