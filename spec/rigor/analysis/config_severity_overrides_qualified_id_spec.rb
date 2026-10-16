# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"

# Issue #1985 — `severity_overrides:` answers a plugin's own row by its qualified id (`plugin.<id>.<rule>`, or
# `plugin.<id>` for the whole plugin), as `disable:` does since #1953. A bare key reaches built-in rows only, plus the
# plugin loader's own rows under their documented bare ids (`load-error`, `runtime-error`); it never re-stamps a
# `plugin.<id>.*` row, so two plugins sharing a bare rule never move each other's severity.
RSpec.describe "qualified ids in `severity_overrides:`" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Two plugins reporting the same bare rules at :warning, so a key that reached one by its bare rule would reach both.
  def emitter(id, const_name)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: id, version: "0.1.0")

      def diagnostics_for_file(path:, **)
        %w[unknown-column other-rule].map do |rule|
          Rigor::Analysis::Diagnostic.new(path: path, line: 2, column: 1, message: "#{rule} here", severity: :warning,
                                          rule: rule)
        end
      end
    end
    stub_const(const_name, klass)
    klass
  end

  let(:plugins) do
    { "rigor-left-1985" => emitter("left-1985", "FakeLeft1985Plugin"),
      "rigor-right-1985" => emitter("right-1985", "FakeRight1985Plugin") }
  end
  let(:plugin_rows) do
    %w[plugin.left-1985.unknown-column plugin.left-1985.other-rule
       plugin.right-1985.unknown-column plugin.right-1985.other-rule]
  end
  let(:with_missing_plugin) { { "plugins" => plugins.keys + ["rigor-no-such-plugin-1985"] } }

  # Runs a sequential, uncached check of `a.rb` (holding `source`) with `extra` merged into the configuration and
  # returns `{ qualified_rule => severity }` of the kept rows. An unknown `plugins:` entry fails to load.
  def run_rows(overrides, extra = {}, source: "x = 1\ny = 2\n")
    Dir.mktmpdir("rigor-1985-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", source)
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => ["a.rb"], "plugins" => plugins.keys,
                                               "severity_overrides" => overrides).merge(extra)
        )
        requirer = lambda do |name|
          plugin = plugins[File.basename(name, ".rb")]
          raise LoadError, "cannot load such file -- #{name}" if plugin.nil?

          Rigor::Plugin.register(plugin)
          true
        end
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
        return guarded_run(runner, allow_plugin_crash: true).diagnostics.to_h { [it.qualified_rule, it.severity] }
      end
    end
  end

  it "reports every plugin row at its authored severity when nothing overrides it" do
    rows = run_rows({})
    expect(plugin_rows.map { rows[it] }).to all(eq(:warning))
  end

  it "re-stamps (or drops) exactly the row an exact `plugin.<id>.<rule>` key names" do
    rows = run_rows({ "plugin.left-1985.unknown-column" => "error" })
    expect(rows["plugin.left-1985.unknown-column"]).to eq(:error)
    expect((plugin_rows - ["plugin.left-1985.unknown-column"]).map { rows[it] }).to all(eq(:warning))

    rows = run_rows({ "plugin.left-1985.unknown-column" => "off" })
    expect(rows).not_to have_key("plugin.left-1985.unknown-column")
    expect(rows.keys).to include(*(plugin_rows - ["plugin.left-1985.unknown-column"]))
  end

  it "re-stamps every row of the plugin `plugin.<id>` names, and no other plugin's" do
    rows = run_rows({ "plugin.right-1985" => "info" })
    expect(%w[plugin.right-1985.unknown-column plugin.right-1985.other-rule].map { rows[it] }).to all(eq(:info))
    expect(%w[plugin.left-1985.unknown-column plugin.left-1985.other-rule].map { rows[it] }).to all(eq(:warning))
  end

  it "lets an exact qualified key beat the `plugin.<id>` key" do
    rows = run_rows({ "plugin.left-1985" => "info", "plugin.left-1985.other-rule" => "error" })
    expect(rows["plugin.left-1985.other-rule"]).to eq(:error)
    expect(rows["plugin.left-1985.unknown-column"]).to eq(:info)
  end

  it "re-stamps no plugin row for a bare rule, a family wildcard or `all`" do
    rows = run_rows({ "unknown-column" => "off", "other-rule" => "error", "all" => "off" })
    expect(plugin_rows.map { rows[it] }).to all(eq(:warning))
  end

  describe "the plugin loader's own row" do
    it "answers to its qualified id and to its documented bare id, never to a plugin's row" do
      %w[plugin_loader.load-error load-error].each do |key|
        rows = run_rows({ key => "off" }, with_missing_plugin)
        expect(rows).not_to have_key("plugin_loader.load-error")
        expect(rows.keys).to include(*plugin_rows)
      end

      rows = run_rows({ "plugin_loader.load-error" => "warning" }, with_missing_plugin)
      expect(rows["plugin_loader.load-error"]).to eq(:warning)
    end

    it "lets the qualified key beat the bare key for the loader's row" do
      rows = run_rows({ "load-error" => "info", "plugin_loader.load-error" => "off" }, with_missing_plugin)
      expect(rows).not_to have_key("plugin_loader.load-error")

      rows = run_rows({ "load-error" => "off", "plugin_loader.load-error" => "info" }, with_missing_plugin)
      expect(rows["plugin_loader.load-error"]).to eq(:info)
    end
  end

  # rigor-rails-i18n reports an unparsable locale as its own run-level `load-error`, beside the loader's row for an
  # unloadable entry: the collision #1985 reports. Re-registers on every load (PR #1976).
  def i18n_rows(overrides)
    config = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["a.rb"], "plugins" => %w[rigor-rails-i18n rigor-no-such-plugin-1985],
        "severity_overrides" => overrides
      )
    )
    requirer = lambda do |name|
      require name
      Rigor::Plugin.register(Rigor::Plugin::RailsI18n)
      true
    end
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner, allow_plugin_crash: true).diagnostics.to_h { [it.qualified_rule, it.severity] }
  end

  it "separates rails-i18n's load-error from the loader's under bare and qualified keys" do
    Dir.mktmpdir("rigor-1985-i18n-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", "x = 1\n")
        FileUtils.mkdir_p("config/locales")
        File.write("config/locales/en.yml", "en:\n  foo: [\n")

        expect(i18n_rows({}).keys).to include("plugin.rails-i18n.load-error", "plugin_loader.load-error")

        rows = i18n_rows({ "load-error" => "off" })
        expect(rows.keys).to include("plugin.rails-i18n.load-error")
        expect(rows.keys).not_to include("plugin_loader.load-error")

        rows = i18n_rows({ "plugin.rails-i18n.load-error" => "off" })
        expect(rows.keys).not_to include("plugin.rails-i18n.load-error")
        expect(rows.keys).to include("plugin_loader.load-error")

        rows = i18n_rows({ "plugin.rails-i18n" => "off" })
        expect(rows.keys).not_to include("plugin.rails-i18n.load-error")
        expect(rows.keys).to include("plugin_loader.load-error")
      end
    end
  end

  describe "built-in rows (positive control)" do
    it "still answers to an exact id and to a family wildcard" do
      rows = run_rows({ "call.undefined-method" => "warning" }, source: "1.zork\n")
      expect(rows["call.undefined-method"]).to eq(:warning)
      rows = run_rows({ "call" => "info" }, source: "1.zork\n")
      expect(rows["call.undefined-method"]).to eq(:info)
    end
  end
end
