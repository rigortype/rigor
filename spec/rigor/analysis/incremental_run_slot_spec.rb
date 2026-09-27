# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/analysis/incremental_run_slot"
require "rigor/analysis/run_cache_probe"

# ADR-45 WD2 (#1507) — the run-result slot `rigor check --incremental` writes after each run, and the engine-free
# probe that serves a later null run from it. Each example drives the real session over a real on-disk store
# and snapshot, one session per simulated process, and asks the probe the question the CLI asks before it
# loads the engine. The CLI half — that a served run never requires `rigor/inference` — is pinned in
# `spec/rigor/cli/run_cache_probe_spec.rb`.
#
# The oracle for "the answer is right" is a fresh `Runner` with no cache store, the analysis a cold
# `rigor check --no-cache` runs.
RSpec.describe Rigor::Analysis::IncrementalRunSlot do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir("rigor-incremental-slot-") do |raw|
      # Realpath'd so a plugin's `IoBoundary` read of a project file stays inside the trusted-read root
      # (`Dir.pwd`, which macOS resolves through the `/tmp` alias; see #959).
      Dir.chdir(File.realpath(raw)) { example.run }
    end
  end

  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # `a.rb` defines what `b.rb` calls, so an edit to one has a dependent; `c.rb` stands alone.
  def write_project
    write("lib/a.rb", "class Widget\n  def price\n    10\n  end\nend\n")
    write("lib/b.rb", "class Shop\n  def total\n    Widget.new.price.upcase\n  end\nend\n")
    write("lib/c.rb", "class Other\n  def go\n    1\n  end\nend\n")
  end

  def configuration(extra = {})
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge({ "paths" => ["lib"] }.merge(extra)))
  end

  def requirer_for(plugin)
    return nil if plugin.nil?

    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  # One `rigor check --incremental` process: a fresh store, a fresh session, the real snapshot on disk. `paths`
  # stands for the path arguments (`rigor check --incremental lib extra`); nil runs over the configuration's.
  def incremental_run(config = configuration, plugin: nil, paths: nil)
    session = Rigor::Analysis::IncrementalSession.new(
      configuration: config, paths: paths, cache_store: Rigor::Cache::Store.new(root: cache_root),
      plugin_requirer: requirer_for(plugin)
    )
    guarded_run_incremental(
      session,
      snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root),
      fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: paths || config.paths)
    )
  end

  def served(config = configuration, paths: nil)
    described_class.serve(configuration: config, cache_root: cache_root, paths: paths || config.paths)
  end

  def cold(config = configuration, plugin: nil)
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil,
                                         plugin_requirer: requirer_for(plugin))
    guarded_run(runner).diagnostics
  end

  def rows(diagnostics)
    diagnostics.map(&:to_h)
  end

  def slot_entries
    Dir.glob(File.join(cache_root, described_class::PRODUCER_ID, "**", "*.entry"))
  end

  it "serves the run's own answer after a cold baseline, and its file count for the banner" do
    write_project
    diagnostics, warm = incremental_run

    hit = served
    expect(warm).to be(false)
    expect(hit).not_to be_nil
    expect(rows(hit.result.diagnostics)).to eq(rows(diagnostics))
    expect(rows(hit.result.diagnostics).map { |row| row["path"] }).to include("lib/b.rb")
    expect(hit.file_count).to eq(3)
  end

  it "after an edit recheck, serves the new answer, which is a cold run's of the new tree" do
    write_project
    incremental_run
    # A hit in between touches no snapshot, so the edit run below restores the one the baseline wrote.
    expect(served).not_to be_nil
    write("lib/a.rb", "class Widget\n  def price\n    \"ten\"\n  end\nend\n")
    diagnostics, warm = incremental_run

    hit = served
    expect(warm).to be(true)
    expect(hit).not_to be_nil
    expect(rows(hit.result.diagnostics)).to eq(rows(diagnostics))
    expect(rows(hit.result.diagnostics)).to eq(rows(cold))
    expect(rows(hit.result.diagnostics).map { |row| row["path"] }).not_to include("lib/b.rb")
  end

  describe "declining once an input the answer depends on changes" do
    before do
      write_project
      incremental_run
    end

    # Each arm: the probe declines, and the full path then answers as a cold run does and writes a slot the
    # next null run is served from.
    def expect_declined_then_recovered(config = configuration)
      expect(served(config)).to be_nil
      diagnostics, = incremental_run(config)
      expect(rows(diagnostics)).to eq(rows(cold(config)))
      expect(rows(served(config).result.diagnostics)).to eq(rows(diagnostics))
    end

    it "serves while nothing changed (the control for every arm below)" do
      expect(served).not_to be_nil
    end

    it "declines for an edited analysed file" do
      write("lib/c.rb", "class Other\n  def go\n    1.upcase\n  end\nend\n")
      expect_declined_then_recovered
    end

    it "declines for an added file, and for a removed one" do
      write("lib/d.rb", "class Added\n  def x\n    :y.upcase\n  end\nend\n")
      expect_declined_then_recovered
      FileUtils.rm_f("lib/d.rb")
      expect_declined_then_recovered
    end

    it "declines for an edited signature file" do
      write("sig/widget.rbs", "class Widget\n  def price: () -> Integer\nend\n")
      config = configuration("signature_paths" => ["sig"])
      incremental_run(config)
      expect(served(config)).not_to be_nil
      write("sig/widget.rbs", "class Widget\n  def price: () -> String\nend\n")
      expect_declined_then_recovered(config)
    end

    it "declines for a configuration change" do
      expect_declined_then_recovered(configuration("severity_profile" => "strict"))
    end

    it "declines for an analysis root that appears after the run reported it missing" do
      config = configuration("paths" => %w[lib extra])
      incremental_run(config)
      expect(served(config)).not_to be_nil
      FileUtils.mkdir_p("extra")
      expect_declined_then_recovered(config)
    end
  end

  # The roots are part of the key: `lib extra` with `extra` missing analyses the files `lib` does, and only the
  # first reports `extra` as missing. Keyed by the files alone, each run was served the other's answer.
  describe "keying by the analysis roots" do
    def missing_root_rows(diagnostics)
      rows(diagnostics).select { |row| row["path"] == "extra" }
    end

    before { write_project }

    it "does not serve a run over `lib` the answer of a run over `lib extra`" do
      diagnostics, = incremental_run(paths: %w[lib extra])
      expect(missing_root_rows(diagnostics)).not_to be_empty
      expect(served(paths: %w[lib extra])).not_to be_nil

      expect(served(paths: %w[lib])).to be_nil
      diagnostics, = incremental_run(paths: %w[lib])
      expect(missing_root_rows(diagnostics)).to be_empty
      expect(rows(served(paths: %w[lib]).result.diagnostics)).to eq(rows(diagnostics))
    end

    it "does not serve a run over `lib extra` the answer of a run over `lib`" do
      incremental_run(paths: %w[lib])
      expect(served(paths: %w[lib])).not_to be_nil

      expect(served(paths: %w[lib extra])).to be_nil
      diagnostics, = incremental_run(paths: %w[lib extra])
      expect(missing_root_rows(diagnostics)).not_to be_empty
      expect(rows(served(paths: %w[lib extra]).result.diagnostics)).to eq(rows(diagnostics))
    end
  end

  # Inputs a recheck does not re-derive ride the chain from the full run that recorded them. Recomputing them on a
  # recheck would vouch for the tree the recheck saw while its answer still carries rows computed before the
  # change, so the probe declines until the next full run: each arm checks it still declines after a full-path
  # run over the changed tree.
  describe "declining until the next full run, for an input a recheck does not re-derive" do
    def expect_declined_through_a_recheck(config = configuration, paths: nil)
      expect(served(config, paths: paths)).to be_nil
      _, warm = incremental_run(config, paths: paths)
      expect(warm).to be(true)
      expect(served(config, paths: paths)).to be_nil
    end

    it "a discovered-not-analysed file (a run over `lib` with `ext` among the configured paths)" do
      write_project
      write("ext/helper.rb", "class Helper\n  def go\n    1\n  end\nend\n")
      config = configuration("paths" => %w[lib ext])
      incremental_run(config, paths: %w[lib])
      expect(served(config, paths: %w[lib])).not_to be_nil
      write("ext/helper.rb", "class Helper\n  def go\n    2\n  end\nend\n")
      expect_declined_through_a_recheck(config, paths: %w[lib])
    end

    it "an auto-detected signature root that appears" do
      write_project
      incremental_run
      expect(served).not_to be_nil
      write("sig/widget.rbs", "class Widget\n  def price: () -> String\nend\n")
      expect_declined_through_a_recheck
    end

    it "a `pre_eval:` file outside the analysed set" do
      write_project
      write("boot/constants.rb", "LIMIT = 3\n")
      config = configuration("pre_eval" => ["boot/constants.rb"])
      incremental_run(config)
      expect(served(config)).not_to be_nil
      write("boot/constants.rb", "LIMIT = \"three\"\n")
      expect_declined_through_a_recheck(config)
    end
  end

  # The ADR-45 Pundit shape: a plugin that reads a file which is not analysed, while ANALYSING another file,
  # and whose answer depends on the bytes.
  describe "a plugin read made while analysing a file" do
    let(:reader_plugin) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "slot-reader", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          return [] unless File.basename(path) == "c.rb"

          said = io_boundary.read_file("policy.txt").lines.first.to_s.strip
          [diagnostic(root, path: path, message: "policy says #{said}", severity: :warning, rule: "policy")]
        end
      end
    end

    def plugin_config
      configuration("plugins" => ["rigor-slot-reader"])
    end

    def policy_messages(diagnostics)
      rows(diagnostics).filter_map { |row| row["message"] if row["rule"].to_s.end_with?("policy") }
    end

    before do
      stub_const("SlotReaderPlugin", reader_plugin)
      write_project
      write("policy.txt", "allow\n")
      incremental_run(plugin_config, plugin: reader_plugin)
    end

    it "declines when the file the plugin read changes" do
      expect(policy_messages(served(plugin_config).result.diagnostics)).to eq(["policy says allow"])
      write("policy.txt", "deny\n")
      expect(served(plugin_config)).to be_nil
    end

    it "still declines after a recheck that served the reading file from cache (the carried row)" do
      # `c.rb` is the reader and does not depend on `a.rb`, so this recheck re-analyses `a.rb` and `b.rb` and
      # serves `c.rb` from cache: the plugin reads nothing this run, and the row guarding `policy.txt` is the
      # one carried forward from the baseline's slot.
      write("lib/a.rb", "class Widget\n  def price\n    \"ten\"\n  end\nend\n")
      diagnostics, warm = incremental_run(plugin_config, plugin: reader_plugin)
      expect(warm).to be(true)
      expect(policy_messages(diagnostics)).to eq(["policy says allow"])
      expect(policy_messages(served(plugin_config).result.diagnostics)).to eq(["policy says allow"])

      write("policy.txt", "deny\n")
      expect(served(plugin_config)).to be_nil
    end

    it "drops a removed reader's rows, so the file it read no longer guards the slot" do
      FileUtils.rm_f("lib/c.rb")
      incremental_run(plugin_config, plugin: reader_plugin)
      write("policy.txt", "deny\n")
      expect(served(plugin_config)).not_to be_nil
    end
  end

  # A plugin producer served from its own record-and-validate entry reads nothing, so its inputs reach neither this
  # slot nor the plain one; the full path revalidates the producer, recomputes it, and moves the ADR-88 fact
  # surface. Pending until #1558 replays a producer hit's recorded rows into the plugin's boundary.
  describe "a plugin producer's input" do
    let(:table_plugin) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "slot-table", version: "0.1.0")

        producer :table do |_params|
          io_boundary.read_file("schema.txt").strip
        end

        def prepare(_services)
          @table = producer_value(:table)
        end

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          return [] unless File.basename(path) == "c.rb"

          [diagnostic(root, path: path, message: "table #{@table}", severity: :warning, rule: "table")]
        end
      end
    end

    def table_config
      configuration("plugins" => ["rigor-slot-table"])
    end

    before do
      stub_const("SlotTablePlugin", table_plugin)
      write_project
      write("schema.txt", "v1\n")
    end

    it "declines once the file a producer read changes, after a recheck the producer answered from its cache" do
      pending "#1558: a producer cache hit replays none of the rows it recorded"
      incremental_run(table_config, plugin: table_plugin)
      write("lib/a.rb", "class Widget\n  def price\n    11\n  end\nend\n")
      _, warm = incremental_run(table_config, plugin: table_plugin)
      expect(warm).to be(true)
      write("schema.txt", "v2\n")
      expect(served(table_config)).to be_nil
    end
  end

  describe "the chain a recheck carries forward" do
    before do
      write_project
      incremental_run
    end

    it "writes no slot when the previous one is gone, rather than guess what the served files read" do
      FileUtils.rm_rf(File.join(cache_root, described_class::PRODUCER_ID))
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      incremental_run
      expect(slot_entries).to be_empty
      expect(served).to be_nil
    end

    it "writes no slot when another run rewrote the snapshot after the previous slot was written" do
      snapshot = File.join(cache_root, "incremental", "snapshot.bin")
      bytes = File.binread(snapshot)
      FileUtils.rm_f(snapshot)
      File.binwrite(snapshot, bytes) # the same payload, but not the write the previous slot recorded
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      incremental_run
      expect(served).to be_nil
    end

    it "keeps one slot per project across a change of the analysed-path set" do
      write("lib/d.rb", "class Added\nend\n")
      incremental_run
      expect(slot_entries.size).to eq(1)
      expect(served).not_to be_nil
    end
  end

  it "writes no slot with effect collection on, whose configuration the key does not carry" do
    write_project
    write(".rigor.yml", "paths:\n  - lib\neffects: {}\n")
    config = Rigor::Configuration.load(".rigor.yml")
    expect(config.effects_enabled?).to be(true)
    incremental_run(config)
    expect(slot_entries).to be_empty
    expect(served(config)).to be_nil
  end

  # Two things keep them apart, each enough alone: the producer id, and the roots entry the plain key does not
  # carry. The plain run must neither read nor replace the incremental entry, nor the reverse.
  it "keeps the plain and the incremental slots apart" do
    write_project
    incremental, = incremental_run
    plain = Rigor::Analysis::RunCacheProbe.new(configuration: configuration, cache_root: cache_root, explain: false)
    expect(plain.serve(configuration.paths)).to be_nil

    plain_run = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: Rigor::Cache::Store.new(root: cache_root))
    )
    expect(rows(plain_run.diagnostics)).to eq(rows(cold))
    expect(rows(plain.serve(configuration.paths).diagnostics)).to eq(rows(cold))
    expect(rows(served.result.diagnostics)).to eq(rows(incremental))
  end

  it "does not serve an incremental run from the plain slot" do
    write_project
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: Rigor::Cache::Store.new(root: cache_root))
    )
    expect(served).to be_nil
  end
end
