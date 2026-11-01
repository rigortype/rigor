# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #2392 — `PoolCoordinator` accumulates run-scoped tables (run disclosures, trust refusals, the
# dependency / analysis-read / analysis-disclosure / effect graphs) through `merge_*` and `collect_*`, and
# `Runner` keeps its sequential per-file dependency and effect tables the same way. Only `#initialize`
# cleared them, so a reused Runner re-emitted run N's rows in run N+1 and kept files run N+1 no longer
# analyses. No shipped caller reuses a Runner (each builds a fresh one per run), but a reused Runner must
# report what a fresh one would. `Runner#run_analysis` resets these tables once at the top of each run, in
# both modes.
RSpec.describe "a reused pool-mode Runner reports each run as a fresh Runner would (#2392)" do
  def write_files(dir)
    %w[a b trigger].to_h do |name|
      path = File.join(dir, "#{name}.rb")
      File.write(path, "#{name} = 1\n")
      [name, path]
    end
  end

  # Every file reads one refused path (a trust refusal per analysed file), and `trigger.rb` also registers a
  # run-scoped disclosure. Both are reached only through per-file analysis, so the rows arrive from the
  # workers' payloads and are merged on the coordinator.
  let(:probe_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "pool-run-reset-probe", version: "0.1.0")

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        if File.basename(path) == "trigger.rb"
          disclose_once(:trigger_seen, message: "trigger file analysed",
                                       severity: :info)
        end
        begin
          io_boundary.read_file("/rigor-refused-#{File.basename(path)}")
        rescue Rigor::Plugin::AccessDeniedError
          nil
        end
        []
      end
    end
  end

  before do
    skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
    Rigor::Plugin.unregister!
    stub_const("PoolRunResetProbe", probe_class)
  end

  after { Rigor::Plugin.unregister! }

  def runner_for(dir, workers:, record_dependencies: false, effects: false, cache: false)
    settings = { "paths" => [dir], "plugins" => ["rigor-pool-run-reset-probe"] }
    settings["effects"] = {} if effects
    configuration = Rigor::Configuration.new(settings)
    requirer = lambda do |_name|
      Rigor::Plugin.register(probe_class)
      true
    end
    Rigor::Analysis::Runner.new(
      configuration: configuration, workers: workers,
      cache_store: (cache ? Rigor::Cache::Store.new(root: File.join(dir, ".rigor")) : nil), plugin_requirer: requirer,
      record_dependencies: record_dependencies
    )
  end

  def disclosure_rows(diagnostics)
    diagnostics.select { |d| d.message == "trigger file analysed" }.map(&:to_h)
  end

  def refusal_rows(diagnostics)
    diagnostics.select { |d| d.rule == "plugin_trust.read-refused" }.map(&:to_h)
  end

  def read_count(row)
    Integer(row["message"][/had (\d+) read\(s\)/, 1])
  end

  it "does not re-emit a run-scoped disclosure from a file the second run no longer analyses" do
    Dir.mktmpdir do |dir|
      files = write_files(dir)
      runner = runner_for(dir, workers: 2)

      first = guarded_run(runner, [files["a"], files["trigger"]], allow_plugin_crash: true).diagnostics
      second = guarded_run(runner, [files["a"], files["b"]], allow_plugin_crash: true).diagnostics
      fresh = guarded_run(runner_for(dir, workers: 2), [files["a"], files["b"]], allow_plugin_crash: true).diagnostics

      expect(disclosure_rows(first).size).to eq(1)
      expect(disclosure_rows(second)).to be_empty
      expect(refusal_rows(second)).to eq(refusal_rows(fresh))
    end
  end

  it "does not sum a trust refusal across runs on the same Runner" do
    Dir.mktmpdir do |dir|
      files = write_files(dir)
      runner = runner_for(dir, workers: 2)
      paths = files.values

      first = refusal_rows(guarded_run(runner, paths, allow_plugin_crash: true).diagnostics)
      second = refusal_rows(guarded_run(runner, paths, allow_plugin_crash: true).diagnostics)

      expect(first.size).to eq(1)
      expect(read_count(first.first)).to eq(3)
      expect(second).to eq(first)
    end
  end

  describe "sequential (--workers 0)" do
    it "drops a file's dependency record when the next run on the same Runner no longer analyses it" do
      Dir.mktmpdir do |dir|
        files = write_files(dir)
        runner = runner_for(dir, workers: 0, record_dependencies: true)
        guarded_run(runner, files.values, allow_plugin_crash: true)
        guarded_run(runner, [files["trigger"]], allow_plugin_crash: true)
        fresh = runner_for(dir, workers: 0, record_dependencies: true)
        guarded_run(fresh, [files["trigger"]], allow_plugin_crash: true)

        expect(runner.file_dependencies.keys).to eq(fresh.file_dependencies.keys)
        expect(runner.file_dependencies.size).to eq(1)
      end
    end

    it "keeps only this run's effect collections when the next run no longer analyses a file" do
      Dir.mktmpdir do |dir|
        files = write_files(dir)
        runner = runner_for(dir, workers: 0, effects: true)
        guarded_run(runner, files.values, allow_plugin_crash: true)
        guarded_run(runner, [files["trigger"]], allow_plugin_crash: true)
        fresh = runner_for(dir, workers: 0, effects: true)
        guarded_run(fresh, [files["trigger"]], allow_plugin_crash: true)

        expect(runner.effect_collections_by_path.keys).to eq(fresh.effect_collections_by_path.keys)
        expect(runner.effect_collections_by_path.size).to eq(1)
      end
    end

it "does not hand a later analysing run the collections of an earlier run served from the effect cache" do
  Dir.mktmpdir do |dir|
    files = write_files(dir)
    runner = runner_for(dir, workers: 0, effects: true, cache: true)
    guarded_run(runner, files.values, allow_plugin_crash: true)
    guarded_run(runner, files.values, allow_plugin_crash: true)
    expect(runner.effects_served_from_cache?).to be(true)

    guarded_run(runner, [files["trigger"]], allow_plugin_crash: true)
    fresh = runner_for(dir, workers: 0, effects: true, cache: true)
    guarded_run(fresh, [files["trigger"]], allow_plugin_crash: true)

    expect(runner.effects_served_from_cache?).to be(false)
    expect(runner.effect_collections_by_path.keys).to eq(fresh.effect_collections_by_path.keys)
  end
end

    it "does not re-emit a run-scoped disclosure from a file the second run no longer analyses" do
      Dir.mktmpdir do |dir|
        files = write_files(dir)
        runner = runner_for(dir, workers: 0)

        guarded_run(runner, [files["a"], files["trigger"]], allow_plugin_crash: true)
        second = guarded_run(runner, [files["a"], files["b"]], allow_plugin_crash: true).diagnostics
        fresh = guarded_run(runner_for(dir, workers: 0), [files["a"], files["b"]], allow_plugin_crash: true).diagnostics

        expect(disclosure_rows(second)).to be_empty
        expect(refusal_rows(second)).to eq(refusal_rows(fresh))
      end
    end
  end
end
