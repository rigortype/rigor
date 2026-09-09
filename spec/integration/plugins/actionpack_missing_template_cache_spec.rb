# frozen_string_literal: true

# Issue #629 — `plugin.actionpack.missing-template` is an ABSENCE answer: the diagnostic fires because
# `locate_template` found no file at any candidate path. Before the fix that lookup probed with bare
# `File.file?`, which records nothing, so the run-result cache (ADR-45) had no edge back to the template's
# later appearance and a warm run kept reporting the template missing until `--no-cache`.
#
# The fix routes the lookup through `Rigor::Plugin::IoBoundary#list_directory`, which records ONE
# `Cache::Descriptor::GlobEntry` per consulted `app/views/<controller>` directory. The three examples below
# are the #577 fixture pattern (add-after-miss invalidates, nothing-changed hits, remove-after-hit
# invalidates); the last example pins the CARDINALITY decision the issue asked for — one listing row per
# view directory, not one row per candidate path.
#
# Every example drives the real Runner against a real on-disk Store with a FRESH Store per run, so a hit
# has to come off disk: what the next `rigor check` process faces.

require "spec_helper"
require "fileutils"
require "tmpdir"

ACTIONPACK_LIB_629 = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
$LOAD_PATH.unshift(ACTIONPACK_LIB_629) unless $LOAD_PATH.include?(ACTIONPACK_LIB_629)
require "rigor-actionpack"

CONTROLLER_629 = <<~RUBY
  class PostsController
    def show
      render :show
    end
  end
RUBY

RSpec.describe "plugins/rigor-actionpack missing-template under the run cache (#629)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Returns `[result, counters]` — the run-diagnostics slot's hits/misses ARE whether the run was served
  # from cache or re-analyzed.
  def run_once(dir, cache_root)
    Rigor::Plugin.unregister!
    store = Rigor::Cache::Store.new(root: cache_root)
    result = Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => ["app/controllers"], "plugins" => ["rigor-actionpack"]
          )
        ),
        cache_store: store, collect_stats: false,
        plugin_requirer: lambda { |_name|
          Rigor::Plugin.register(Rigor::Plugin::Actionpack)
          true
        }
      )
      guarded_run(runner)
    end
    counters = store.stats.fetch(:by_producer)
                    .fetch(Rigor::Analysis::RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID) { { hits: 0, misses: 0 } }
    [result, counters.slice(:hits, :misses)]
  end

  def missing_template_rules(result)
    result.diagnostics.select { |d| d.source_family == "plugin.actionpack" && d.rule == "missing-template" }
  end

  def with_project
    Dir.mktmpdir do |raw_dir|
      Dir.mktmpdir do |cache_root|
        # `Dir.mktmpdir` hands back the unresolved `/tmp/...` alias on macOS while the plugin TrustPolicy's
        # read roots come from the symlink-resolved `Dir.pwd`; name the project the way the policy does.
        dir = File.realpath(raw_dir)
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "posts_controller.rb"), CONTROLLER_629)
        yield dir, cache_root
      end
    end
  end

  def write_template(dir)
    full = File.join(dir, "app", "views", "posts", "show.html.erb")
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "<h1>Show</h1>\n")
    full
  end

  it "reports the missing template on a cold run (the must-still-fire counterpart)" do
    with_project do |dir, cache_root|
      cold, counters = run_once(dir, cache_root)
      expect(counters).to eq(hits: 0, misses: 1)
      expect(missing_template_rules(cold).map(&:message)).to include(a_string_including("posts/show"))
    end
  end

  it "re-analyzes and drops the diagnostic once the template is ADDED" do
    with_project do |dir, cache_root|
      cold, = run_once(dir, cache_root)
      expect(missing_template_rules(cold)).not_to be_empty

      write_template(dir)
      warm, counters = run_once(dir, cache_root)
      expect(counters).to eq(hits: 0, misses: 1)
      expect(missing_template_rules(warm)).to be_empty
    end
  end

  it "serves the warm run from cache when nothing changed (the listing row does not thrash)" do
    with_project do |dir, cache_root|
      write_template(dir)
      cold, = run_once(dir, cache_root)

      warm, counters = run_once(dir, cache_root)
      expect(counters).to eq(hits: 1, misses: 0)
      expect(warm.diagnostics.map { |d| [d.rule, d.line] }).to eq(cold.diagnostics.map { |d| [d.rule, d.line] })
    end
  end

  it "re-analyzes and re-reports once the template is REMOVED" do
    with_project do |dir, cache_root|
      template = write_template(dir)
      _cold, cold_counters = run_once(dir, cache_root)
      expect(cold_counters).to eq(hits: 0, misses: 1)

      File.unlink(template)
      warm, counters = run_once(dir, cache_root)
      expect(counters).to eq(hits: 0, misses: 1)
      expect(missing_template_rules(warm)).not_to be_empty
    end
  end

  # The cardinality decision (#629): a listing row per consulted `app/views/<controller>` directory, NOT a
  # row per candidate path. `render :show` tries nine extensions, so the per-probe shape would record nine
  # file rows for this one call; the listing shape records one glob row and covers strictly more.
  it "records ONE directory-listing row for the render's view directory, not one per candidate extension" do
    with_project do |dir, cache_root|
      boundaries = []
      allow(Rigor::Plugin::IoBoundary).to receive(:new).and_wrap_original do |orig, **kwargs|
        orig.call(**kwargs).tap { |b| boundaries << b if b.plugin_id == "actionpack" }
      end
      run_once(dir, cache_root)

      expect(boundaries.size).to eq(1)
      descriptor = boundaries.first.cache_descriptor
      expect(descriptor.globs.map { |g| [File.basename(g.root), g.pattern] }).to eq([["posts", "*"]])
      expect(descriptor.files.map(&:path).grep(/show\.html\.erb/)).to be_empty
    end
  end
end
