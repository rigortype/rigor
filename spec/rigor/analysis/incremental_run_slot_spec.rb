# frozen_string_literal: true

require "spec_helper"
require "delegate"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/analysis/incremental_run_slot"
require "rigor/analysis/run_cache_probe"
require_relative "../../fixtures/template_units/view_demo_plugin"

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

  def cold(config = configuration, plugin: nil, paths: nil)
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil,
                                         plugin_requirer: requirer_for(plugin))
    guarded_run(runner, paths).diagnostics
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

    # A missing root is reported as the run was given it, so `./extra` and `extra/` print a different row.
    it "does not serve a run over `lib ./extra` or `lib extra/` the answer of a run over `lib extra`" do
      incremental_run(paths: %w[lib extra])
      expect(served(paths: %w[lib ./extra])).to be_nil
      expect(served(paths: %w[lib extra/])).to be_nil

      diagnostics, = incremental_run(paths: %w[lib ./extra])
      expect(rows(diagnostics).map { |row| row["path"] }).to include("./extra")
      expect(rows(served(paths: %w[lib ./extra]).result.diagnostics)).to eq(rows(diagnostics))
      expect(served(paths: %w[lib extra])).to be_nil
    end
  end

  # Inputs a recheck does not re-derive ride the chain from the full run that recorded them. Recomputing them on a
  # recheck would vouch for the tree the recheck saw while its answer still carries rows computed before the
  # change, so the probe declines until the next full run: each arm checks it still declines after a full-path
  # run over the changed tree.
  describe "declining until the next full run, for an input a recheck does not re-derive" do
    # `closure` makes the recheck also re-analyse an analysed file: an empty closure builds no environment and
    # leaves the runner's baseline rows nil, so only a non-empty one would catch a recheck re-deriving them.
    def expect_declined_through_a_recheck(config = configuration, paths: nil, closure: false)
      expect(served(config, paths: paths)).to be_nil
      write("lib/c.rb", "class Other\n  def go\n    3\n  end\nend\n") if closure
      _, warm = incremental_run(config, paths: paths)
      expect(warm).to be(true)
      expect(served(config, paths: paths)).to be_nil
    end

    [false, true].each do |closure|
      context(closure ? "through a recheck that re-analyses a file" : "through a recheck with an empty closure") do
        it "a discovered-not-analysed file (a run over `lib` with `ext` among the configured paths)" do
          write_project
          write("ext/helper.rb", "class Helper\n  def go\n    1\n  end\nend\n")
          config = configuration("paths" => %w[lib ext])
          incremental_run(config, paths: %w[lib])
          expect(served(config, paths: %w[lib])).not_to be_nil
          write("ext/helper.rb", "class Helper\n  def go\n    2\n  end\nend\n")
          expect_declined_through_a_recheck(config, paths: %w[lib], closure: closure)
        end

        it "an auto-detected signature root that appears" do
          write_project
          incremental_run
          expect(served).not_to be_nil
          write("sig/widget.rbs", "class Widget\n  def price: () -> String\nend\n")
          expect_declined_through_a_recheck(closure: closure)
        end

        it "a `pre_eval:` file outside the analysed set" do
          write_project
          write("boot/constants.rb", "LIMIT = 3\n")
          config = configuration("pre_eval" => ["boot/constants.rb"])
          incremental_run(config)
          expect(served(config)).not_to be_nil
          write("boot/constants.rb", "LIMIT = \"three\"\n")
          expect_declined_through_a_recheck(config, closure: closure)
        end
      end
    end
  end

  # A save landing while the run reads: the slot is written when the run ends, so every row and the key must
  # still describe the tree the run analysed, or the probe serves the pre-save answer against the post-save
  # tree. The save is made just before the first file's analysis, after the environment is built.
  describe "a save during the run" do
    def during_first_analysis(&edit)
      fired = false
      allow_any_instance_of(Rigor::Analysis::Runner).to receive(:analyze_file).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
        unless fired
          fired = true
          edit.call
        end
        original.call(*args)
      end
    end

    def after_the_run
      RSpec::Mocks.space.reset_all
    end

    it "writes no slot when a configured signature file is saved while the run reads" do
      config = configuration("signature_paths" => ["sig"])
      write("sig/gadget.rbs", "class Gadget\n  def price: () -> Integer\nend\n")
      write("lib/b.rb", "class Shop\n  def total\n    Gadget.new.price.upcase\n  end\nend\n")
      during_first_analysis { write("sig/gadget.rbs", "class Gadget\n  def price: () -> String\nend\n") }
      incremental_run(config)
      after_the_run

      expect(served(config)).to be_nil
      diagnostics, = incremental_run(config)
      expect(rows(diagnostics)).to eq(rows(cold(config)))
      expect(rows(served(config).result.diagnostics)).to eq(rows(diagnostics))
    end

    it "writes no slot when the lockfile is rewritten while the run reads" do
      lock = "GEM\n  remote: https://rubygems.org/\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\n" \
             "BUNDLED WITH\n   2.6.0\n"
      write("Gemfile", "source 'https://rubygems.org'\n")
      write("Gemfile.lock", lock)
      write("lib/a.rb", "class A\n  def x\n    1.nope\n  end\nend\n")
      during_first_analysis { write("Gemfile.lock", lock.sub("   2.6.0", "   2.6.1")) }
      incremental_run
      after_the_run

      expect(slot_entries).to be_empty
      expect(served).to be_nil
    end

    it "writes no slot when a served file is replaced while the run reads, its mtime kept" do
      write("lib/a.rb", "class Widget\n  def price\n    10\n  end\nend\n")
      write("lib/c.rb", "class Other\n  def go\n    1\n  end\nend\n")
      incremental_run
      FileUtils.touch("lib/c.rb", mtime: Time.now - 5) # the tuple moves, the bytes do not
      kept = File.mtime("lib/c.rb")
      write("lib/a.rb", "class Widget\n  def price\n    11\n  end\nend\n") # something to re-analyse
      during_first_analysis do
        File.write("lib/c.rb", "class Other\n  def go\n    1.nope_c\n  end\nend\n")
        File.utime(kept, kept, "lib/c.rb") # as `cp -p` or `rsync -t` would
      end
      incremental_run
      after_the_run

      expect(served).to be_nil
    end

    # An existence row is taken when the run ends: the root's creation or removal must not be recorded over an
    # answer that reported the other state. The root is nested, so the project directory the absent lockfiles'
    # rows watch does not change with it.
    it "writes no slot when a missing analysis root is created while the run reads" do
      write_project
      FileUtils.mkdir_p("pkg")
      during_first_analysis { FileUtils.mkdir_p("pkg/extra") }
      diagnostics, = incremental_run(paths: %w[lib pkg/extra])
      after_the_run

      expect(rows(diagnostics).map { |row| row["path"] }).to include("pkg/extra")
      expect(served(paths: %w[lib pkg/extra])).to be_nil
    end

    it "writes no slot when an analysis root is removed while the run reads" do
      write_project
      FileUtils.mkdir_p("pkg/extra")
      during_first_analysis { FileUtils.rm_rf("pkg/extra") }
      diagnostics, = incremental_run(paths: %w[lib pkg/extra])
      after_the_run

      expect(rows(diagnostics).map { |row| row["path"] }).not_to include("pkg/extra")
      expect(served(paths: %w[lib pkg/extra])).to be_nil
    end

    # The snapshot fingerprint reads only `./Gemfile.lock`; a configured lockfile is the key's alone.
    it "writes no slot when a configured lockfile is rewritten while the run reads" do
      lock = "GEM\n  remote: https://rubygems.org/\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\n" \
             "BUNDLED WITH\n   2.6.0\n"
      write("locks/Gemfile.lock", lock)
      config = configuration("bundler" => { "lockfile" => "locks/Gemfile.lock" })
      write("lib/a.rb", "class A\n  def x\n    1.nope\n  end\nend\n")
      during_first_analysis { write("locks/Gemfile.lock", lock.sub("   2.6.0", "   2.6.1")) }
      incremental_run(config)
      after_the_run

      expect(slot_entries).to be_empty
      expect(served(config)).to be_nil
    end

    # The signature rows are listed when the run ends, so the removed file has no row, and its directory's
    # listing row is the only one that moved: the root `sig` itself did not.
    it "writes no slot when a signature file is removed from a nested directory while the run reads" do
      write_project
      write("sig/shop/widget.rbs", "class Widget\n  def price: () -> Integer\nend\n")
      write("sig/shop/gadget.rbs", "class Gadget\nend\n")
      during_first_analysis { FileUtils.rm_f("sig/shop/gadget.rbs") }
      incremental_run
      after_the_run

      expect(served).to be_nil
    end

    # A recheck with a non-empty closure rebuilds its environment from the signature tree it carries rows for. A
    # save reverted before the run ends leaves every carried row fresh.
    it "writes no slot when a carried signature file is saved and reverted while a recheck reads" do
      write_project
      original = "class Widget\n  def price: () -> Integer\nend\n"
      write("sig/widget.rbs", original)
      incremental_run
      expect(served).not_to be_nil
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      during_first_analysis do
        write("sig/widget.rbs", "class Widget\n  def price: () -> String\nend\n")
        write("sig/widget.rbs", original)
      end
      _, warm = incremental_run
      after_the_run

      expect(warm).to be(true)
      expect(served).to be_nil
    end

    # An editor's lock file is created and removed beside the file it edits. Neither an absent lockfile nor an
    # analysis root is read for its directory's entries, so neither may refuse the write for one: a recheck that
    # writes no slot leaves the chain broken until the next full run.
    it "writes the slot when an unrelated file comes and goes in the project root while a recheck reads" do
      write_project
      incremental_run
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      during_first_analysis do
        File.write(".#editor-lock", "")
        FileUtils.rm_f(".#editor-lock")
      end
      diagnostics, warm = incremental_run
      after_the_run

      expect(warm).to be(true)
      expect(rows(served.result.diagnostics)).to eq(rows(diagnostics))
    end

    it "writes the slot when an unrelated file comes and goes in an analysis root while a recheck reads" do
      write_project
      incremental_run
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      during_first_analysis do
        File.write("lib/.#c.rb", "")
        FileUtils.rm_f("lib/.#c.rb")
      end
      diagnostics, warm = incremental_run
      after_the_run

      expect(warm).to be(true)
      expect(rows(served.result.diagnostics)).to eq(rows(diagnostics))
    end

    it "writes no slot when the lockfile is rewritten and restored while the run reads" do
      lock = "GEM\n  remote: https://rubygems.org/\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\n" \
             "BUNDLED WITH\n   2.6.0\n"
      write("Gemfile", "source 'https://rubygems.org'\n")
      write("Gemfile.lock", lock)
      write("lib/a.rb", "class A\n  def x\n    1.nope\n  end\nend\n")
      during_first_analysis do
        write("Gemfile.lock", lock.sub("   2.6.0", "   2.6.1"))
        write("Gemfile.lock", lock)
      end
      incremental_run
      after_the_run

      expect(served).to be_nil
    end

    it "writes no slot when a template is saved while the run reads" do
      write_project
      write("app/views/users/show.rbx", "\"x\".upcasee\n")
      config = configuration("plugins" => ["rigor-view-demo"])
      during_first_analysis { write("app/views/users/show.rbx", "\"x\".downcasee\n") }
      incremental_run(config, plugin: RigorViewDemoPlugin)
      after_the_run

      expect(served(config)).to be_nil
    end
  end

  # The write guard's clock is the filesystem's own, read off a stamp in the store. A change time on another
  # filesystem comes from another clock, or another granularity, and cannot be compared with it.
  describe Rigor::Analysis::IncrementalRunSlot::WriteGuard do
    def start
      described_class.start(
        configuration: configuration, roots: ["lib"], cache_root: cache_root,
        fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
      )
    end

    def rows_for(path)
      Rigor::Cache::Descriptor.new(
        files: [Rigor::Cache::Descriptor::FileEntry.stat(path: path, digest: Rigor::Cache::FileDigest.hexdigest(path))]
      )
    end

    # `File.stat` answering for `path` with a device other than its own.
    def on_another_device(path)
      allow(File).to receive(:stat).and_wrap_original do |original, asked|
        stat = original.call(asked)
        next stat unless File.expand_path(asked.to_s) == File.expand_path(path)

        instance_double(File::Stat, dev: stat.dev + 1, ctime: stat.ctime, mtime: stat.mtime)
      end
    end

    before { write_project }

    it "admits a row whose file did not change since the mark" do
      expect(start.admits?(rows_for("lib/a.rb"))).to be(true)
    end

    it "refuses a row whose file is on another filesystem than the mark" do
      guard = start
      here = rows_for("lib/a.rb")
      there = rows_for("lib/c.rb")
      on_another_device("lib/c.rb")
      expect(guard.admits?(here)).to be(true)
      expect(guard.admits?(there)).to be(false)
    end

    it "passes over a row the key pins on another filesystem, and checks one on the mark's" do
      guard = start
      pinned = rows_for("lib/c.rb")
      on_another_device("lib/c.rb")
      expect(guard.admits?(rows_for("lib/a.rb"), pinned: pinned)).to be(true)

      RSpec::Mocks.space.reset_all
      write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
      expect(guard.admits?(rows_for("lib/a.rb"), pinned: pinned)).to be(false)
    end

    it "takes no mark when the store is on another filesystem than the project" do
      on_another_device(Dir.pwd)
      expect(start).to be_nil
    end

    # The caller computes the fingerprint before the run starts; a lockfile rewritten in between leaves the snapshot
    # the run restores keyed by one tree while the run reads another.
    it "takes no mark when the fingerprint the run was given no longer describes the tree" do
      write("Gemfile.lock", "GEM\n  specs:\n")
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
      write("Gemfile.lock", "GEM\n  specs:\n\n")
      expect(described_class.start(configuration: configuration, roots: ["lib"], cache_root: cache_root,
                                   fingerprint: fingerprint)).to be_nil
    end

    it "refuses the write once a lockfile appears" do
      guard = start
      write("Gemfile.lock", "GEM\n  specs:\n")
      expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
    end

    it "refuses the write once a lockfile is removed" do
      write("Gemfile.lock", "GEM\n  specs:\n")
      guard = start
      FileUtils.rm_f("Gemfile.lock")
      expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
    end
  end

  # The signature files the key pins live wherever the engine and the gems are installed, which a container or a
  # Nix store puts on another filesystem than the project; the project's own signatures do not.
  describe "signature files on another filesystem" do
    let(:engine_root) { File.expand_path("../../..", __dir__) }

    # `File.stat` answering with another device for every path under one of `prefixes`, for the run only.
    def elsewhere(*prefixes)
      allow(File).to receive(:stat).and_wrap_original do |original, asked|
        stat = original.call(asked)
        next stat unless prefixes.any? { |prefix| File.join(File.expand_path(asked.to_s), "").start_with?(prefix) }

        moved = SimpleDelegator.new(stat)
        moved.define_singleton_method(:dev) { stat.dev + 1 }
        moved
      end
    end

    def bundle_config
      configuration("bundler" => { "bundle_path" => "bundle", "auto_detect" => false })
    end

    def previous_entry(config)
      described_class.previous_entry(
        store: Rigor::Cache::Store.new(root: cache_root), configuration: config,
        target: described_class::Target.new(files: %w[lib/a.rb lib/b.rb lib/c.rb], roots: config.paths)
      )
    end

    before do
      write_project
      write("bundle/ruby/4.0.0/gems/gadget-1.0/sig/gadget.rbs", "class Gadget\nend\n")
    end

    it "writes the slot when the engine's and a gem's signature files are elsewhere" do
      elsewhere(File.join(engine_root, "data", ""), File.join(Dir.pwd, "bundle", ""))
      incremental_run(bundle_config)
      RSpec::Mocks.space.reset_all

      expect(served(bundle_config)).not_to be_nil
      pinned = previous_entry(bundle_config).pinned.files.map(&:path)
      expect(pinned).to include(a_string_starting_with(File.join(engine_root, "data", "")))
      expect(pinned).to include(a_string_ending_with("gadget-1.0/sig/gadget.rbs"))
    end

    it "writes no slot when the project's own signature files are elsewhere" do
      write("sig/widget.rbs", "class Widget\n  def price: () -> Integer\nend\n")
      elsewhere(File.join(Dir.pwd, "sig", "widget.rbs", "")) # the file, not the root its existence row names
      incremental_run(bundle_config)
      RSpec::Mocks.space.reset_all

      expect(served(bundle_config)).to be_nil
    end
  end

  # rigor-actionpack's shape: a plugin that claims template globs and compiles each template into a unit the run
  # analyses. The key carries no `template-units` slot, which only a run can compute; the template files and one
  # listing row per claimed glob validate what it would have keyed.
  describe "a project whose plugin claims template globs" do
    def view_config
      configuration("plugins" => ["rigor-view-demo"])
    end

    def run_views
      incremental_run(view_config, plugin: RigorViewDemoPlugin)
    end

    def paths_of(diagnostics)
      rows(diagnostics).map { |row| row["path"] }
    end

    before do
      write_project
      write("app/views/users/show.rbx", "\"x\".upcasee\n")
    end

    it "serves its answer, and declines once a template changes, appears or goes" do
      diagnostics, = run_views
      expect(paths_of(diagnostics)).to include("app/views/users/show.rbx")
      expect(rows(served(view_config).result.diagnostics)).to eq(rows(diagnostics))

      write("app/views/users/show.rbx", "\"x\".downcasee\n")
      expect(served(view_config)).to be_nil
      diagnostics, warm = run_views
      expect(warm).to be(true)
      expect(rows(diagnostics)).to eq(rows(cold(view_config, plugin: RigorViewDemoPlugin)))
      expect(rows(served(view_config).result.diagnostics)).to eq(rows(diagnostics))

      write("app/views/users/edit.rbx", "1.nope\n")
      expect(served(view_config)).to be_nil
      diagnostics, = run_views
      expect(paths_of(diagnostics)).to include("app/views/users/edit.rbx")
      expect(served(view_config)).not_to be_nil

      FileUtils.rm_f("app/views/users/edit.rbx")
      expect(served(view_config)).to be_nil
    end
  end

  # The key holds the roots as a set, so a run that reorders them still carries the previous chain; the entry
  # keeps the order, because `a b` lists `a`'s files first and `b a` lists `b`'s.
  describe "the order of the analysis roots" do
    before do
      write("a/a.rb", "class Aa\n  def go\n    1.nope_a\n  end\nend\n")
      write("b/b.rb", "class Bb\n  def go\n    1.nope_b\n  end\nend\n")
    end

    def order_of(diagnostics)
      rows(diagnostics).map { |row| row["path"] }
    end

    it "serves each order only its own answer, and keeps the chain across a reorder" do
      forward, = incremental_run(paths: %w[a b])
      expect(order_of(forward)).to eq(%w[a/a.rb b/b.rb])
      expect(rows(served(paths: %w[a b]).result.diagnostics)).to eq(rows(forward))
      expect(served(paths: %w[b a])).to be_nil

      backward, warm = incremental_run(paths: %w[b a])
      expect(warm).to be(true)
      expect(order_of(backward)).to eq(%w[b/b.rb a/a.rb])
      expect(rows(backward)).to eq(rows(cold(paths: %w[b a])))
      expect(rows(served(paths: %w[b a]).result.diagnostics)).to eq(rows(backward))
      expect(served(paths: %w[a b])).to be_nil
    end

    it "serves a root only under the spelling the run was given" do
      incremental_run(paths: %w[a b])
      expect(served(paths: %w[a b])).not_to be_nil
      expect(served(paths: %w[a/ b])).to be_nil
      expect(served(paths: %w[./a b])).to be_nil
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

  # A plugin producer served from its own record-and-validate entry reads nothing; since #1558 the hit replays the
  # rows its entry recorded into the plugin's boundary, which is how its inputs reach this slot (and the plain
  # one). The full path revalidates the producer, recomputes it, and moves the ADR-88 fact surface.
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

    # The rigor-actionpack `:controller_index` shape: no `#prepare`, the producer first asked from a node rule, so
    # its reads — and, since #1558, the rows a hit or a miss replays — land while a file is being analysed. The
    # `watch:` glob is what a miss replays that the block did not read itself.
    let(:node_rule_plugin) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "slot-index", version: "0.1.0")

        producer :index, watch: [["index", "*.txt"]] do |_params|
          io_boundary.read_file("index/entries.txt").strip
        end

        node_rule Prism::CallNode do |node, _scope, path|
          next [] unless node.name == :lookup

          [diagnostic(node, path: path, message: "index #{producer_value(:index)}", severity: :warning,
                            rule: "index")]
        end
      end
    end

    def table_config
      configuration("plugins" => ["rigor-slot-table"])
    end

    def index_config
      configuration("plugins" => ["rigor-slot-index"])
    end

    def index_messages(diagnostics)
      rows(diagnostics).filter_map { |row| row["message"] if row["rule"].to_s.end_with?("index") }
    end

    before do
      stub_const("SlotTablePlugin", table_plugin)
      stub_const("SlotIndexPlugin", node_rule_plugin)
      write_project
      write("schema.txt", "v1\n")
      write("index/entries.txt", "v1\n")
    end

    it "declines once the file a producer read changes, after a recheck the producer answered from its cache" do
      incremental_run(table_config, plugin: table_plugin)
      write("lib/a.rb", "class Widget\n  def price\n    11\n  end\nend\n")
      _, warm = incremental_run(table_config, plugin: table_plugin)
      expect(warm).to be(true)
      write("schema.txt", "v2\n")
      expect(served(table_config)).to be_nil
    end

    it "writes a slot when the producer is first asked from a node rule, computed or served from its cache" do
      write("lib/c.rb", "class Other\n  def go\n    lookup(1)\n  end\nend\n")
      diagnostics, = incremental_run(index_config, plugin: node_rule_plugin)
      expect(index_messages(diagnostics)).to eq(["index v1"])
      expect(served(index_config)).not_to be_nil # the miss: the block's read and the replayed `watch:` row

      write("lib/c.rb", "class Other\n  def go\n    lookup(2)\n  end\nend\n")
      diagnostics, warm = incremental_run(index_config, plugin: node_rule_plugin)
      expect(warm).to be(true)
      expect(index_messages(diagnostics)).to eq(["index v1"])
      expect(served(index_config)).not_to be_nil # the hit: the replayed rows alone

      write("index/entries.txt", "v2\n")
      expect(served(index_config)).to be_nil
    end
  end

  # #1536's source-RBS gate decides a recheck's closure; the slot does not lean on it. An analysed file's row
  # declines for any edit, the gate's verdict aside, so a run under an untrusted gate still writes a slot. What the
  # slot does depend on is the session's content digests, and a file the gate unbinds has none.
  describe "under the source-RBS gate" do
    let(:synthesizer) do
      lambda do |path|
        source = File.read(path)
        members = source.scan(/^\s*# slot-rbs: (.+)$/).flatten
        class_name = source[/^class (\w+)/, 1]
        next nil if members.empty? || class_name.nil?

        "class #{class_name}\n#{members.map { |member| "  #{member}\n" }.join}end\n"
      end
    end

    # A synthesizer that exists only after `#prepare`, which the gate cannot see and so distrusts.
    let(:prepare_built_plugin) do
      built = synthesizer
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "slot-prepare-synth", version: "0.1.0")

        define_method(:prepare) do |_services|
          @prepared_manifest = Rigor::Plugin::Manifest.new(id: "slot-prepare-synth", version: "0.1.0",
                                                           source_rbs_synthesizer: built)
        end

        def manifest
          @prepared_manifest || self.class.manifest
        end
      end
    end

    def synth_config
      configuration("plugins" => ["rigor-slot-prepare-synth"])
    end

    def write_greeter(returns)
      write("lib/greeter.rb",
            "class Greeter\n  # slot-rbs: def greet: () -> #{returns}\n  def greet\n    x\n  end\nend\n")
      write("lib/caller.rb", "class Caller\n  def go\n    Rigor.dump_type(Greeter.new.greet)\n  end\nend\n")
    end

    def dumped(diagnostics)
      rows(diagnostics).filter_map { |row| row["message"] if row["path"] == "lib/caller.rb" }
    end

    it "writes a slot under an untrusted gate, declines for a synthesised-RBS edit, and serves the cold answer after" do
      stub_const("SlotPrepareSynthPlugin", prepare_built_plugin)
      write_greeter("String")
      incremental_run(synth_config, plugin: prepare_built_plugin)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: synth_config, roots: ["lib"])
      bundles = Rigor::Cache::IncrementalSnapshot.new(root: cache_root).load(fingerprint: fingerprint).seed_bundles
      expect(bundles.values.map { |bundle| bundle[:source_rbs_digest] }).to all(be_nil) # the gate is untrusted
      expect(dumped(served(synth_config).result.diagnostics).join).to include("String")

      write_greeter("Integer")
      expect(served(synth_config)).to be_nil
      diagnostics, = incremental_run(synth_config, plugin: prepare_built_plugin)
      expect(rows(diagnostics)).to eq(rows(cold(synth_config, plugin: prepare_built_plugin)))
      expect(dumped(diagnostics).join).to include("Integer")
      expect(rows(served(synth_config).result.diagnostics)).to eq(rows(diagnostics))
    end

    it "writes no slot when the session forgot a file's digest because the file was saved mid-run" do
      write_project
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, cache_store: Rigor::Cache::Store.new(root: cache_root)
      )
      allow(session.send(:source_rbs_gate)).to receive(:unbound).and_return(Set["lib/c.rb"])
      guarded_run_incremental(
        session,
        snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root),
        fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
      )
      expect(slot_entries).to be_empty
      expect(served).to be_nil
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

  # `.rigor.yml`'s paths load as absolute paths, and `rigor check --incremental lib` names the same root relatively.
  # Discovery widened to the configured paths once per file under both spellings (#1556), so the run recorded a
  # discovered-not-analysed row for every analysed file, and the first edit left the chain stale for good.
  it "keeps serving after an edit when the path argument names a configured path" do
    write_project
    write(".rigor.yml", "paths:\n  - lib\n")
    config = Rigor::Configuration.load(".rigor.yml")
    incremental_run(config, paths: %w[lib])
    expect(served(config, paths: %w[lib])).not_to be_nil

    write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
    diagnostics, warm = incremental_run(config, paths: %w[lib])
    expect(warm).to be(true)
    expect(rows(served(config, paths: %w[lib]).result.diagnostics)).to eq(rows(diagnostics))
  end

  # A file list widens discovery to the configured paths, which name the listed file again under its absolute
  # spelling; the listed file must not become a discovered-not-analysed row of its own.
  it "keeps serving after an edit to the one file a file-list run analyses" do
    write_project
    write(".rigor.yml", "paths:\n  - lib\n")
    config = Rigor::Configuration.load(".rigor.yml")
    incremental_run(config, paths: %w[lib/c.rb])
    expect(served(config, paths: %w[lib/c.rb])).not_to be_nil

    write("lib/c.rb", "class Other\n  def go\n    2\n  end\nend\n")
    diagnostics, warm = incremental_run(config, paths: %w[lib/c.rb])
    expect(warm).to be(true)
    expect(rows(served(config, paths: %w[lib/c.rb]).result.diagnostics)).to eq(rows(diagnostics))
  end

  it "writes no slot with effect collection on, whose configuration the key does not carry" do
    write_project
    write(".rigor.yml", "paths:\n  - lib\neffects: {}\n")
    config = Rigor::Configuration.load(".rigor.yml")
    expect(config.effects_enabled?).to be(true)
    allow(Rigor::Analysis::IncrementalRunSlot::WriteGuard).to receive(:start).and_call_original
    incremental_run(config)
    # No mark is spent on a run whose slot cannot be written.
    expect(Rigor::Analysis::IncrementalRunSlot::WriteGuard).not_to have_received(:start)
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
