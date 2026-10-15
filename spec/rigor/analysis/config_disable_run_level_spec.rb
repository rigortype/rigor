# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"

# Issue #1895 — the `.rigor.yml` `disable:` list reaches the run-level rows (plugin load / prepare, ADR-10
# dependency-source, `rbs.coverage.*`), which are assembled outside any per-file suppression filter, and the
# `all` sentinel in that list drops every rule-bearing row. The match is the per-file one: the token expansion of
# {Rigor::Analysis::CheckRules.expand_rule_tokens} against the diagnostic's `rule`.
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
                                         rule: "saw-file")]
      end
    end
    stub_const("FakeEmitter1895Plugin", klass)
    klass
  end
  let(:missing_plugin) { { "plugins" => ["rigor-no-such-plugin-1895"] } }
  let(:missing_gem) { { "dependencies" => { "source_inference" => [{ "gem" => "no-such-gem-1895" }] } } }

  # Runs a sequential, uncached check of `a.rb` (holding `source`) with `extra` merged into the configuration and
  # returns the diagnostics the run kept. `plugin` is what every `plugins:` entry loads; without one, the entry
  # fails to load.
  def run_diagnostics(extra = {}, plugin: nil, source: "x = 1\n")
    Dir.mktmpdir("rigor-1895-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", source)
        File.write("Gemfile.lock", lockfile)
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
    rows = run_rows(missing_plugin.merge(missing_gem))
    expect(rows).to include("plugin_loader.load-error", "dynamic.dependency-source.gem-not-found",
                            "rbs.coverage.missing-gem")
  end

  it "drops the plugin load-error row under its rule id" do
    rows = run_rows(missing_plugin.merge("disable" => ["load-error"]))
    expect(rows).not_to include("plugin_loader.load-error")
  end

  it "drops the plugin prepare row under its rule id" do
    plugins = { "plugins" => ["rigor-prepare-bomb"] }
    expect(run_rows(plugins, plugin: raising_prepare_plugin)).to include("plugin_loader.runtime-error")
    expect(run_rows(plugins.merge("disable" => ["runtime-error"]), plugin: raising_prepare_plugin))
      .not_to include("plugin_loader.runtime-error")
  end

  # Round-1 review of #1948 — a `plugin.<id>` row is not reached by the `disable:` list, by its bare rule id or by
  # `all`, as before #1895: the bare-id match would let a built-in token hide every plugin's same-named rule.
  it "leaves a plugin's own row alone under its bare rule id and under `all`" do
    plugins = { "plugins" => ["rigor-emitter"] }
    expect(run_rows(plugins.merge("disable" => ["saw-file"]), plugin: emitting_plugin))
      .to include("plugin.emitter-1895.saw-file")
    expect(run_rows(plugins.merge("disable" => ["all"]), plugin: emitting_plugin))
      .to eq(["plugin.emitter-1895.saw-file"])
  end

  # The collision the review found: `rigor-rails-i18n` reports an unparsable locale file as its own `load-error`,
  # which `disable: [load-error]` must not hide while it drops the plugin loader's row.
  it "drops the loader's load-error row but keeps rails-i18n's own load-error row" do
    Dir.mktmpdir("rigor-1895-i18n-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", "x = 1\n")
        FileUtils.mkdir_p("config/locales")
        File.write("config/locales/en.yml", "en:\n  foo: [\n")
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => ["a.rb"], "plugins" => %w[rigor-rails-i18n rigor-no-such-plugin-1895],
            "disable" => ["load-error"]
          )
        )
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
        rows = guarded_run(runner).diagnostics.map(&:qualified_rule)
        expect(rows).to include("plugin.rails-i18n.load-error")
        expect(rows).not_to include("plugin_loader.load-error")
      end
    end
  end

  it "drops the dependency-source row under its canonical id" do
    rows = run_rows(missing_gem.merge("disable" => ["dynamic.dependency-source.gem-not-found"]))
    expect(rows).not_to include("dynamic.dependency-source.gem-not-found")
  end

  it "drops the rbs.coverage row under its canonical id" do
    expect(run_rows({ "disable" => ["rbs.coverage.missing-gem"] })).not_to include("rbs.coverage.missing-gem")
  end

  it "leaves the rows a non-matching entry does not name" do
    rows = run_rows(missing_plugin.merge(missing_gem).merge("disable" => ["call.undefined-method"]))
    expect(rows).to include("plugin_loader.load-error", "dynamic.dependency-source.gem-not-found",
                            "rbs.coverage.missing-gem")
  end

  it "drops every rule-bearing row, per-file and run-level, under `disable: [all]`" do
    extra = missing_plugin.merge("paths" => ["a.rb", "ghost.rb"])
    source = "x = 1\nx.no_such_method_1895\n"
    expect(run_rows(extra, source: source))
      .to include("call.undefined-method", "plugin_loader.load-error", "rbs.coverage.missing-gem")

    kept = run_diagnostics(extra.merge("disable" => ["all"]), source: source)
    # The path-error row for `ghost.rb` carries no rule and stays: a nil-rule row is never suppressed.
    expect(kept.map(&:qualified_rule)).to eq([nil])
    expect(kept.first.path).to eq("ghost.rb")
  end
end
