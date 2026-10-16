# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/analysis/run_cache_probe"

RAILS_I18N_WARM_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rails-i18n/lib", __dir__)
$LOAD_PATH.unshift(RAILS_I18N_WARM_PLUGIN_LIB) unless $LOAD_PATH.include?(RAILS_I18N_WARM_PLUGIN_LIB)
require "rigor-rails-i18n"

# Issue #1954 — a broken `config/locales/*.yml` must report `plugin.rails-i18n.load-error` on every run
# while it stays broken, cold or warm. The YAML errors used to be captured in an instance variable the
# `:locale_index` producer block set, so a warm producer-cache hit, which skips the block, lost them: any
# run that was not served whole from the run-result cache (a config edit, `--workers`) dropped the row.
#
# Each mode runs the whole sequence in its own project with its own `.rigor/cache` and a fresh Store per
# run, so a hit comes off disk as it does for the next `rigor check` process.
RSpec.describe "plugins/rigor-rails-i18n load-error row on a warm run (#1954)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:broken_locale) { "en:\n  bad:\n :: oops\n" }
  let(:fixed_locale) { "en:\n  bad: \"fine\"\n" }
  # What answered each plain `rigor check`: the run-result slot or the runner (see `#plain_check`).
  let(:answered_by) { [] }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def configuration(disable)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["app"], "plugins" => ["rigor-rails-i18n"],
                                           "disable" => disable)
    )
  end

  def cache_root
    File.join(Dir.pwd, ".rigor", "cache")
  end

  def requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::RailsI18n)
      true
    end
  end

  def runner(config, store, workers: 0)
    Rigor::Analysis::Runner.new(configuration: config, cache_store: store, plugin_requirer: requirer,
                                workers: workers)
  end

  # `rigor check`: the boot-slim probe serves the run-result slot when it validates, else the full runner
  # runs.
  def plain_check(config, store)
    served = Rigor::Analysis::RunCacheProbe.new(configuration: config, cache_root: cache_root, explain: false)
                                           .serve(config.paths)
    answered_by << (served ? :run_slot : :runner)
    return served.diagnostics if served

    guarded_run(runner(config, store)).diagnostics
  end

  def pooled_check(config, store)
    diagnostics = guarded_run(runner(config, store, workers: 2)).diagnostics
    expect(diagnostics.map(&:rule)).not_to include("pool-degraded")
    diagnostics
  end

  def incremental_check(config, store)
    session = Rigor::Analysis::IncrementalSession.new(configuration: config, cache_store: store,
                                                      plugin_requirer: requirer)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: config.paths)
    diagnostics, = guarded_run_incremental(session, snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root),
                                                    fingerprint: fingerprint)
    diagnostics
  end

  def load_error_rows(diagnostics)
    diagnostics.select { |d| d.source_family.to_s == "plugin.rails-i18n" && d.rule == "load-error" }
               .map { |d| [d.path, d.line, d.message] }
  end

  def locale_index_hits(store)
    store.stats.fetch(:by_producer).fetch("plugin.rails-i18n.locale_index", {}).fetch(:hits, 0)
  end

  # `[step, disable:, locale text written first (nil keeps the file)]`. Cold; a config edit (a run-result
  # miss over a warm producer cache, the bug); the same config again (a whole run-result hit for plain
  # `rigor check`); the locale fixed; the locale broken again.
  def plan
    edited = ["undefined-method"]
    [[:cold, [], nil], [:config_edit, edited, nil], [:unchanged, edited, nil],
     [:fixed, edited, fixed_locale], [:broken_again, edited, broken_locale]]
  end

  # Returns each step's load-error rows and the config-edit run's Store.
  def sequence(mode)
    Dir.mktmpdir("rigor-1954-") do |raw|
      Dir.chdir(File.realpath(raw)) do
        write("app/a.rb", "x = 1\n")
        write("config/locales/bad.yml", broken_locale)
        stores = {}
        steps = plan.to_h do |step, disable, locale|
          write("config/locales/bad.yml", locale) if locale
          stores[step] = Rigor::Cache::Store.new(root: cache_root)
          [step, load_error_rows(send(:"#{mode}_check", configuration(disable), stores[step]))]
        end
        [steps, stores.fetch(:config_edit)]
      end
    end
  end

  # `skip_unchanged:` leaves out the nothing-changed rerun, for the mode whose rerun analyses no file.
  def expect_row_tracks_the_locale(steps, skip_unchanged: false)
    row = steps[:cold].first || []
    expect(row[0..1]).to eq([".rigor.yml", 1])
    expect(row[2]).to include("bad.yml").and include("YAML syntax error")
    expected = { cold: [row], config_edit: [row], unchanged: [row], fixed: [], broken_again: [row] }
    expected, steps = [expected, steps].map { |table| table.except(:unchanged) } if skip_unchanged
    expect(steps).to eq(expected)
  end

  it "keeps the row on plain `rigor check` when a config edit misses the run-result cache", :aggregate_failures do
    steps, edit_store = sequence(:plain)
    expect_row_tracks_the_locale(steps)
    # The config edit ran the analysis over a warm producer; the unchanged rerun was served whole.
    expect(answered_by.first(3)).to eq(%i[runner runner run_slot])
    expect(locale_index_hits(edit_store)).to be_positive
  end

  it "keeps the row under `--workers 2`", :aggregate_failures do
    steps, = sequence(:pooled)
    expect_row_tracks_the_locale(steps)
  end

  it "keeps the row under `--incremental`", :aggregate_failures do
    steps, edit_store = sequence(:incremental)
    # The nothing-changed rerun is a recheck over an empty closure: it calls no `#diagnostics_for_file`, so
    # no plugin registers a disclosure, and the session snapshot does not carry run-scoped disclosures over
    # from the previous run. That drops the row for every plugin that registers from the per-file hook, not
    # just this producer, and is outside this fix. `rigor check --incremental` normally answers that rerun
    # from its run-result slot instead; `--cache-stats` or `--workers` reaches the empty-closure recheck.
    expect_row_tracks_the_locale(steps, skip_unchanged: true)
    expect(locale_index_hits(edit_store)).to be_positive
  end
end
