# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/analysis/run_cache_probe"

# Issue #1558 — a plugin producer served from its own disk cache must hand the rows its entry recorded to
# the run, as though it had read them again. Before the fix `Plugin::Base#cache_for` returned the hit and
# nothing else, so the producer's inputs dropped out of the ADR-45 run-result descriptor and out of the
# entry of any producer recomputed around it. Both then validated fresh after those inputs changed.
#
# The sequence is the one that exposed it. Prime; edit an ANALYSED file, so the run re-analyses while the
# producer, whose inputs did not move, is served from its entry; then edit `schema.txt`, the producer's
# input, which is not analysed and is not under any `watch:`. Each mode then has to agree with
# `--no-cache`. Every mode runs in its own project with its own `.rigor/cache`, as a user's would.
#
# - plain `rigor check`: the ADR-87 boot-slim probe, then the full runner, both reading the ADR-45 run
#   slot the edit run stored;
# - `--workers 1`: no run slot (a pool run is not result-cacheable), so only a producer's own entry can
#   serve a stale value;
# - `--incremental`: the ADR-88 fact-surface fingerprint asks every producer for its value.
#
# The single-producer shapes fail on master through the run slot. The chained shape — rigor-activerecord's
# `:model_index` recomputed after a model edit while `:schema_table` was served — failed in every mode,
# because the stale value sat in the chained producer's own entry.
RSpec.describe "plugin producer cache hit replays its dependency rows (#1558)" do
  before do
    Rigor::Plugin.unregister!
    # The loader names each plugin by its class, which an anonymous `Class.new` lacks.
    stub_const("HitReplayFixturePlugin", plugin)
  end

  after { Rigor::Plugin.unregister! }

  # The producer is asked while `c.rb` is analysed, and its value is reported there.
  let(:file_hook_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "hit-replay", version: "0.1.0")

      producer(:table) { |_params| io_boundary.read_file("schema.txt").strip }

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless File.basename(path) == "c.rb"

        [diagnostic(root, path: path, message: "table #{producer_value(:table)}", severity: :warning,
                          rule: "table")]
      end
    end
  end

  # The producer is asked once, from `#prepare`.
  let(:prepare_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "hit-replay", version: "0.1.0")

      producer(:table) { |_params| io_boundary.read_file("schema.txt").strip }

      def prepare(_services)
        @table = producer_value(:table)
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless File.basename(path) == "c.rb"

        [diagnostic(root, path: path, message: "table #{@table}", severity: :warning, rule: "table")]
      end
    end
  end

  # `:index` consumes `:table` and reads the analysed `lib/a.rb` itself, so an edit to `a.rb` recomputes
  # `:index` while `:table` is served. `:table` is asked first: a producer's entry records every row its
  # plugin's boundary holds when the block returns, so asked after the `a.rb` read, `:table` would carry
  # that row too and recompute beside `:index` instead of being served.
  let(:chained_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "hit-replay", version: "0.1.0")

      producer(:table) { |_params| io_boundary.read_file("schema.txt").strip }

      producer(:index) do |_params|
        table = producer_value(:table)
        "#{io_boundary.read_file('lib/a.rb').lines.size} lines/#{table}"
      end

      def prepare(_services)
        @index = producer_value(:index)
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless File.basename(path) == "c.rb"

        [diagnostic(root, path: path, message: "index #{@index}", severity: :warning, rule: "index")]
      end
    end
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"], "plugins" => ["rigor-hit-replay"])
    )
  end

  def cache_root
    File.join(Dir.pwd, ".rigor", "cache")
  end

  def requirer(plugin)
    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  def runner(plugin, store, workers: 0)
    Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store, plugin_requirer: requirer(plugin),
                                workers: workers)
  end

  # `rigor check`: the boot-slim probe serves the run slot when it validates, else the full runner runs.
  def plain_check(plugin, store)
    served = Rigor::Analysis::RunCacheProbe.new(configuration: configuration, cache_root: cache_root, explain: false)
                                           .serve(configuration.paths)
    return served.diagnostics if served

    guarded_run(runner(plugin, store)).diagnostics
  end

  def pooled_check(plugin, store)
    guarded_run(runner(plugin, store, workers: 1)).diagnostics
  end

  def incremental_check(plugin, store)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, cache_store: store,
                                                      plugin_requirer: requirer(plugin))
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration,
                                                                roots: configuration.paths)
    diagnostics, = guarded_run_incremental(session, snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root),
                                                    fingerprint: fingerprint)
    diagnostics
  end

  def no_cache_check(plugin)
    guarded_run(runner(plugin, nil)).diagnostics
  end

  def normalized(diagnostics)
    diagnostics.map(&:to_h).sort_by { |row| [row["path"].to_s, row["line"].to_i, row["rule"].to_s, row["message"]] }
  end

  def plugin_messages(diagnostics)
    diagnostics.select { |d| d.source_family.to_s == "plugin.hit-replay" }.map(&:message)
  end

  # Runs the three-step sequence in a fresh project for one mode. A fresh Store per run, so a hit comes off
  # disk as it does for the next `rigor check` process. Returns the last run's diagnostics, the `--no-cache`
  # answer for the same tree, and the edit run's Store, whose stats show whether `:table` was served.
  def sequence(plugin, mode)
    Dir.mktmpdir("rigor-1558-") do |raw|
      Dir.chdir(File.realpath(raw)) do
        write("lib/a.rb", "class Widget\n  def price\n    10\n  end\nend\n")
        write("lib/b.rb", "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
        write("lib/c.rb", "class Other\n  def go\n    1\n  end\nend\n")
        write("schema.txt", "v1\n")

        check = ->(store) { send(:"#{mode}_check", plugin, store) }
        check.call(Rigor::Cache::Store.new(root: cache_root))
        write("lib/a.rb", "class Widget\n  def price\n    11\n  end\nend\n")
        edit_store = Rigor::Cache::Store.new(root: cache_root)
        check.call(edit_store)
        write("schema.txt", "v2\n")
        final = check.call(Rigor::Cache::Store.new(root: cache_root))
        [final, no_cache_check(plugin), edit_store]
      end
    end
  end

  def table_hits(store)
    store.stats.fetch(:by_producer).fetch("plugin.hit-replay.table", {}).fetch(:hits, 0)
  end

  shared_examples "agrees with --no-cache after the served producer's input changes" do |expected|
    it "in every mode", :aggregate_failures do
      %i[plain pooled incremental].each do |mode|
        final, cold, edit_store = sequence(plugin, mode)
        # Positive control: the uncached answer has moved, so a mode that kept the old one is caught.
        expect(plugin_messages(cold)).to eq([expected])
        # The edit run exercised the hit (only a sequential run's Store sees the producer's stats).
        expect(table_hits(edit_store)).to be_positive unless mode == :pooled
        expect(normalized(final)).to eq(normalized(cold)), "#{mode} diverged from --no-cache"
      end
    end
  end

  context "when the producer is asked while a file is analysed" do
    let(:plugin) { file_hook_plugin }

    it_behaves_like "agrees with --no-cache after the served producer's input changes", "table v2"
  end

  context "when the producer is asked from #prepare" do
    let(:plugin) { prepare_plugin }

    it_behaves_like "agrees with --no-cache after the served producer's input changes", "table v2"
  end

  context "when a recomputed producer consumes the served one" do
    let(:plugin) { chained_plugin }

    it_behaves_like "agrees with --no-cache after the served producer's input changes", "index 5 lines/v2"
  end
end
