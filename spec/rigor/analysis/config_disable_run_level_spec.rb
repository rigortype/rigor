# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"

# Issue #1895 — what the `.rigor.yml` `disable:` list reaches. `disable: [all]` drops every built-in check-rule row,
# including one no per-file filter sees (the `effect.annotations-unchecked` residual). The run-level rows outside
# the check-rule catalogue (the plugin loader, ADR-10 dependency-source, `rbs.coverage.*`) and a plugin's own
# `plugin.<id>.*` rows are not reached, by their id or by `all`: the diagnostic policy keeps them on
# `severity_overrides:` (diagnostic-policy.md, the `rbs.coverage.*` row), and whether that should change is open.
RSpec.describe "config `disable:` over run-level rows" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:lockfile) do
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rare_gem_1895 (1.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        rare_gem_1895

      BUNDLED WITH
         2.5.3
    LOCK
  end
  let(:raising_prepare_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "prepare-bomb-1895", version: "0.1.0")

      def prepare(_services)
        raise "prepare kaboom"
      end
    end
    stub_const("FakePrepareBomb1895Plugin", klass)
    klass
  end
  let(:emitting_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "emitter-1895", version: "0.1.0")

      def diagnostics_for_file(path:, **)
        [Rigor::Analysis::Diagnostic.new(path: path, line: 1, column: 1, message: "saw it", severity: :warning,
                                         rule: "flow.dead-assignment")]
      end
    end
    stub_const("FakeEmitter1895Plugin", klass)
    klass
  end
  let(:missing_plugin) { { "plugins" => ["rigor-no-such-plugin-1895"] } }
  let(:missing_gem) { { "dependencies" => { "source_inference" => [{ "gem" => "no-such-gem-1895" }] } } }
  let(:run_level_rows) do
    ["plugin_loader.load-error", "dynamic.dependency-source.gem-not-found", "rbs.coverage.missing-gem"]
  end

  # Runs a sequential, uncached check of `a.rb` (holding `source`) with `extra` merged into the configuration and
  # returns the diagnostics the run kept. `plugin` is what every `plugins:` entry loads; without one, the entry
  # fails to load. `annotated_sig` adds a signature carrying an effect annotation and no `effects:` block.
  def run_diagnostics(extra = {}, plugin: nil, source: "x = 1\n", annotated_sig: false)
    Dir.mktmpdir("rigor-1895-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", source)
        File.write("Gemfile.lock", lockfile)
        if annotated_sig
          FileUtils.mkdir_p("sig")
          File.write("sig/widget.rbs", "class Widget\n  %a{pure}\n  def price: () -> Integer\nend\n")
        end
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => ["a.rb"], "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
          ).merge(extra)
        )
        requirer = lambda do |name|
          raise LoadError, "cannot load such file -- #{name}" if plugin.nil?

          Rigor::Plugin.register(plugin)
          true
        end
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
        return guarded_run(runner, allow_plugin_crash: true).diagnostics
      end
    end
  end

  def run_rows(...)
    run_diagnostics(...).map(&:qualified_rule)
  end

  it "emits every run-level row when nothing disables it" do
    expect(run_rows(missing_plugin.merge(missing_gem))).to include(*run_level_rows)
  end

  it "keeps each run-level row outside the check-rule catalogue when `disable:` names it" do
    names = ["load-error", "dynamic.dependency-source.gem-not-found", "rbs.coverage.missing-gem"]
    expect(run_rows(missing_plugin.merge(missing_gem).merge("disable" => names))).to include(*run_level_rows)

    plugins = { "plugins" => ["rigor-prepare-bomb"] }
    expect(run_rows(plugins.merge("disable" => ["runtime-error"]), plugin: raising_prepare_plugin))
      .to include("plugin_loader.runtime-error")
  end

  it "drops every check-rule row under `disable: [all]` and keeps the run-level, plugin and rule-less rows" do
    extra = missing_plugin.merge(missing_gem).merge("paths" => ["a.rb", "ghost.rb"])
    source = "x = 1\nx.no_such_method_1895\n"
    expect(run_rows(extra, source: source, annotated_sig: true))
      .to include("call.undefined-method", "effect.annotations-unchecked")

    kept = run_diagnostics(extra.merge("disable" => ["all"]), source: source, annotated_sig: true)
    rows = kept.map(&:qualified_rule)
    expect(rows).not_to include("call.undefined-method", "effect.annotations-unchecked")
    expect(rows).to include(*run_level_rows)
    # The path-error row for `ghost.rb` carries no rule and stays: a nil-rule row is never suppressed.
    expect(kept.select { |d| d.rule.nil? }.map(&:path)).to eq(["ghost.rb"])

    # A plugin row stays even when its bare rule names a built-in check rule.
    plugins = { "plugins" => ["rigor-emitter"] }
    expect(run_rows(plugins.merge("disable" => ["all", "flow.dead-assignment"]), plugin: emitting_plugin))
      .to include("plugin.emitter-1895.flow.dead-assignment")
  end

  # The collision the round-1 review of #1948 found: `rigor-rails-i18n` reports an unparsable locale file as its
  # own `load-error`, which `disable: [load-error]` must not hide; the loader's row is not reached either.
  it "keeps both the loader's and rails-i18n's load-error rows under `disable: [load-error]`" do
    Dir.mktmpdir("rigor-1895-i18n-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", "x = 1\n")
        FileUtils.mkdir_p("config/locales")
        File.write("config/locales/en.yml", "en:\n  foo: [\n")
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => ["a.rb"], "plugins" => ["rigor-rails-i18n", "rigor-no-such-plugin-1895"],
            "disable" => ["load-error"]
          )
        )
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
        rows = guarded_run(runner).diagnostics.map(&:qualified_rule)
        expect(rows).to include("plugin.rails-i18n.load-error", "plugin_loader.load-error")
      end
    end
  end
end
