# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/cli/effects_report"
require "rigor/cli/effects_renderer"
require_relative "../../fixtures/template_units/view_demo_plugin"

# #392 — the revived ADR-16 Tier-D seam, end to end: a plugin claims `app/views/**/*.rbx`, compiles each
# match into Ruby with a line map, and the engine parses and types the result under the declared `self`,
# with the declared ivar seeds and locals in scope.
#
# The four things the issue asks to be true, each with its own example below: the unit reaches
# `rigor effects` as `view:<logical_name>`; a diagnostic inside it points at the template's own file:line;
# the unit marshals through the fork pool so pooled equals sequential; and a project with no template-unit
# plugin is byte-identical to what it was.
RSpec.describe "template units (#392)" do
  def template_source
    <<~RBX
      render_header(@user.name)
      render_header(size)
      File.read("VERSION")
      render_header(@title.upcasee)
    RBX
  end

  def project_source
    <<~RUBY
      class User
        def initialize
          @name = "anonymous"
        end

        def name
          @name
        end
      end

      class ViewContext
        def render_header(text)
          text
        end
      end
    RUBY
  end

  def build_project(dir, template: true)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "app.rb"), project_source)
    return unless template

    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    File.write(File.join(dir, "app", "views", "users", "show.rbx"), template_source)
  end

  # `Configuration#to_h` deliberately omits the `effects:` block (it must not perturb the diagnostics
  # cache identity), so the whole configuration is built in one call rather than merged into an existing one.
  def configuration(effects:, workers:, plugins:)
    data = Rigor::Configuration::DEFAULTS.merge(
      "paths" => ["lib"],
      "plugins" => plugins ? ["rigor-view-demo"] : [],
      "parallel" => { "workers" => workers }
    )
    data = data.merge("effects" => {}) if effects
    Rigor::Configuration.new(data)
  end

  # Runs one whole-project analysis inside a throwaway project root and yields the finished Runner.
  def in_project(template: true, effects: true, workers: 0, plugins: true)
    Dir.mktmpdir("rigor-392-") do |dir|
      build_project(dir, template: template)
      config = configuration(effects: effects, workers: workers, plugins: plugins)
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: config, cache_store: nil,
          plugin_requirer: plugins ? ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) } : ->(_name) {}
        )
        result = guarded_run(runner, ["lib"])
        yield runner, result
      end
    end
  end

  describe "the unit reaches the effect table" do
    it "is keyed `view:<logical_name>` and carries what the template's own body does" do
      in_project do |runner, _result|
        entry = runner.effect_table.find { |row| row.key == "view:users/show.html" }

        expect(entry).not_to be_nil
        expect(entry.proven.to_a).to include("io.fs.read")
      end
    end

    it "traces the unit back to the template file the user wrote, not to a synthesised path" do
      in_project do |runner, _result|
        expect(runner.effect_sources["view:users/show.html"]).to eq(["app/views/users/show.rbx"])
      end
    end
  end

  describe "the `rigor effects` report" do
    it "prints the unit under its `view:` key" do
      in_project do |runner, _result|
        report = Rigor::CLI::EffectsReport.build(runner.effect_table, sources: runner.effect_sources)
        out = StringIO.new
        Rigor::CLI::EffectsRenderer.new(out: out).render(report, format: "text")

        expect(out.string).to include("view:users/show.html: [io.fs.read]")
      end
    end
  end

  describe "positions map back through the line map" do
    # `@title.upcasee` is on line 4 of the TEMPLATE and line 5 of the compiled Ruby (the fixture
    # transform prepends a banner). Reporting 5 is exactly the failure the line map exists to prevent.
    it "positions a diagnostic inside the unit at the template's own file:line" do
      in_project do |_runner, result|
        found = result.diagnostics.select { |d| d.path.end_with?("show.rbx") }

        expect(found.map { |d| [d.rule, d.line] }).to include(["call.undefined-method", 4])
      end
    end
  end

  describe "the declared self, locals and ivar seeds" do
    # Each of the three is exercised by a line of the template that would otherwise be a finding:
    # `render_header` resolves only through the declared `self`, `size` only through the locals, and
    # `@user.name` only through the ivar seeds.
    it "leaves the seeded lines clean" do
      in_project do |_runner, result|
        lines = result.diagnostics.select { |d| d.path.end_with?("show.rbx") }.map(&:line)

        expect(lines).not_to include(1, 2)
      end
    end
  end

  describe "the fork pool" do
    it "reports the same diagnostics pooled as sequentially" do
      sequential = nil
      pooled = nil
      in_project(workers: 0) { |_r, result| sequential = result.diagnostics.map(&:to_s).sort }
      in_project(workers: 2) { |_r, result| pooled = result.diagnostics.map(&:to_s).sort }

      expect(pooled).to eq(sequential)
      # Not vacuous: both sides carry the finding that only exists because the template was analysed.
      expect(pooled).to include(a_string_including("show.rbx:4"))
    end

    it "collects the same effect summary pooled as sequentially" do
      sequential = nil
      pooled = nil
      in_project(workers: 0) { |runner, _| sequential = summary_text(runner) }
      in_project(workers: 2) { |runner, _| pooled = summary_text(runner) }

      expect(pooled).to eq(sequential)
      expect(pooled).to include("view:users/show.html: io.fs.read")
    end

    def summary_text(runner)
      runner.effect_table.map { |row| "#{row.key}: #{row.proven.to_a.sort.join(',')}" }.sort
    end
  end

  # The control the lane contract asks for: effects OFF, and no template-unit plugin at all, must be what
  # the engine was before this seam existed.
  describe "a project with no template-unit plugin" do
    it "analyses exactly its `.rb` files and reports no template diagnostics" do
      in_project(template: false, effects: false, plugins: false) do |runner, result|
        expect(runner.send(:template_units)).to be_empty
        expect(result.diagnostics.map(&:path).uniq).to all(end_with(".rb"))
      end
    end

    it "leaves the `.rbx` file alone when the plugin is not loaded, even though it is on disk" do
      in_project(effects: false, plugins: false) do |_runner, result|
        expect(result.diagnostics.map(&:path)).not_to include(a_string_ending_with(".rbx"))
      end
    end
  end
end
