# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"

# Issue #1953 — `disable:` and `# rigor:disable[-file]` reach a plugin's own row by its qualified id: the exact
# `plugin.<id>.<rule>` or the whole plugin's `plugin.<id>`. A bare id keeps reaching built-in rows only, so two
# plugins that share a bare rule never hide each other's findings, and the run-level rows the diagnostic policy keeps
# on `severity_overrides:` stay out of reach under every spelling (#1895).
RSpec.describe "qualified ids in `disable:` and suppression markers" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Two plugins reporting the same bare rules on line 2, so a token that reached one by its bare rule would reach both.
  # Each also positions a `far-rule` row in another file, whose comments the analysed file's markers do not speak for.
  def emitter(id, const_name)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: id, version: "0.1.0")

      def diagnostics_for_file(path:, **)
        rows = %w[unknown-column other-rule].map do |rule|
          Rigor::Analysis::Diagnostic.new(path: path, line: 2, column: 1, message: "#{rule} here", severity: :warning,
                                          rule: rule)
        end
        rows << Rigor::Analysis::Diagnostic.new(path: "elsewhere.rb", line: 2, column: 1, message: "far",
                                                severity: :warning, rule: "far-rule")
      end
    end
    stub_const(const_name, klass)
    klass
  end

  let(:plugins) do
    { "rigor-left-1953" => emitter("left-1953", "FakeLeft1953Plugin"),
      "rigor-right-1953" => emitter("right-1953", "FakeRight1953Plugin") }
  end
  let(:all_rows) do
    %w[plugin.left-1953.unknown-column plugin.left-1953.other-rule
       plugin.right-1953.unknown-column plugin.right-1953.other-rule
       plugin.left-1953.far-rule plugin.right-1953.far-rule]
  end

  # Runs a sequential, uncached check of `a.rb` (holding `source`) with `extra` merged into the configuration and
  # returns the kept rows' qualified ids. Each `plugins:` entry loads its fake plugin; an unknown entry fails to load.
  def run_rows(extra = {}, source: "x = 1\ny = 2\n")
    Dir.mktmpdir("rigor-1953-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", source)
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => ["a.rb"], "plugins" => plugins.keys).merge(extra)
        )
        requirer = lambda do |name|
          plugin = plugins[File.basename(name, ".rb")]
          raise LoadError, "cannot load such file -- #{name}" if plugin.nil?

          Rigor::Plugin.register(plugin)
          true
        end
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
        return guarded_run(runner, allow_plugin_crash: true).diagnostics.map(&:qualified_rule)
      end
    end
  end

  it "reports every plugin row when nothing suppresses it" do
    expect(run_rows).to include(*all_rows)
  end

  describe "the `disable:` list" do
    it "drops only the row an exact `plugin.<id>.<rule>` names" do
      rows = run_rows({ "disable" => ["plugin.left-1953.unknown-column"] })
      expect(rows).not_to include("plugin.left-1953.unknown-column")
      expect(rows).to include(*(all_rows - ["plugin.left-1953.unknown-column"]))
    end

    it "drops every row of the plugin `plugin.<id>` names, and no other plugin's" do
      rows = run_rows({ "disable" => ["plugin.left-1953"] })
      expect(rows).not_to include("plugin.left-1953.unknown-column", "plugin.left-1953.other-rule",
                                  "plugin.left-1953.far-rule")
      expect(rows).to include("plugin.right-1953.unknown-column", "plugin.right-1953.other-rule")
    end

    it "drops no plugin row for a bare id or `all`" do
      expect(run_rows({ "disable" => %w[unknown-column other-rule all] })).to include(*all_rows)
    end

    it "keeps the plugin loader's row under its qualified id and its bare id" do
      extra = { "plugins" => plugins.keys + ["rigor-no-such-plugin-1953"] }
      %w[plugin_loader.load-error plugin_loader load-error].each do |token|
        expect(run_rows(extra.merge("disable" => [token]))).to include("plugin_loader.load-error")
      end
    end
  end

  describe "in-source markers" do
    it "drops the row a line marker names by `plugin.<id>.<rule>`, on that line only" do
      rows = run_rows(source: "x = 1\ny = 2 # rigor:disable plugin.left-1953.unknown-column\n")
      expect(rows).not_to include("plugin.left-1953.unknown-column")
      expect(rows).to include(*(all_rows - ["plugin.left-1953.unknown-column"]))

      rows = run_rows(source: "x = 1 # rigor:disable plugin.left-1953.unknown-column\ny = 2\n")
      expect(rows).to include(*all_rows)
    end

    it "drops every row of the plugin a file marker names by `plugin.<id>`" do
      rows = run_rows(source: "# rigor:disable-file plugin.right-1953\nx = 1\n")
      expect(rows).not_to include("plugin.right-1953.unknown-column", "plugin.right-1953.other-rule")
      expect(rows).to include("plugin.left-1953.unknown-column", "plugin.left-1953.other-rule")
      # The row the plugin positioned in another file is not this file's to suppress.
      expect(rows).to include("plugin.right-1953.far-rule")
    end

    it "drops no plugin row for a bare id or `all`" do
      expect(run_rows(source: "x = 1\ny = 2 # rigor:disable unknown-column, all\n")).to include(*all_rows)
      expect(run_rows(source: "# rigor:disable-file all\nx = 1\n")).to include(*all_rows)
    end
  end

  # The collision #1948's review found: rigor-rails-i18n reports an unparsable locale as its own `load-error`. Its
  # qualified id now drops it, while the plugin loader's `load-error` beside it stays.
  it "drops rails-i18n's load-error by its qualified id and keeps the loader's" do
    Dir.mktmpdir("rigor-1953-i18n-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", "x = 1\n")
        FileUtils.mkdir_p("config/locales")
        File.write("config/locales/en.yml", "en:\n  foo: [\n")
        rows_for = lambda do |disable|
          config = Rigor::Configuration.new(
            Rigor::Configuration::DEFAULTS.merge(
              "paths" => ["a.rb"], "plugins" => %w[rigor-rails-i18n rigor-no-such-plugin-1953], "disable" => disable
            )
          )
          # Re-register on every load: a spec that ran `unregister!` after an earlier require leaves `require` a
          # no-op with nothing registered (PR #1976).
          requirer = lambda do |name|
            require name
            Rigor::Plugin.register(Rigor::Plugin::RailsI18n)
            true
          end
          runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
          guarded_run(runner, allow_plugin_crash: true).diagnostics.map(&:qualified_rule)
        end

        expect(rows_for.call([])).to include("plugin.rails-i18n.load-error", "plugin_loader.load-error")
        %w[plugin.rails-i18n.load-error plugin.rails-i18n].each do |token|
          rows = rows_for.call([token])
          expect(rows).not_to include("plugin.rails-i18n.load-error")
          expect(rows).to include("plugin_loader.load-error")
        end
      end
    end
  end
end
