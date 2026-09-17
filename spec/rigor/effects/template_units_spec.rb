# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/analysis/run_cache_probe"
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

  def build_project(dir, template: true, body: nil)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "app.rb"), project_source)
    return unless template

    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    File.write(File.join(dir, "app", "views", "users", "show.rbx"), body || template_source)
  end

  def template_findings(diagnostics)
    diagnostics.select { |d| d.path.end_with?("show.rbx") }.map { |d| [d.rule, d.line] }
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
  def in_project(template: true, effects: true, workers: 0, plugins: true, template_body: nil,
                 allow_plugin_crash: false, **overrides)
    RigorViewDemoPlugin.spec_overrides = overrides
    Dir.mktmpdir("rigor-392-") do |dir|
      build_project(dir, template: template, body: template_body)
      config = configuration(effects: effects, workers: workers, plugins: plugins)
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: config, cache_store: nil,
          plugin_requirer: plugins ? ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) } : ->(_name) {}
        )
        result = guarded_run(runner, ["lib"], allow_plugin_crash: allow_plugin_crash)
        yield runner, result
      end
    end
  ensure
    RigorViewDemoPlugin.spec_overrides = {}
    Rigor::Plugin.unregister!("view-demo")
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

  # #392 review B1 — a narrowed run must still analyse every unit. `target_files` narrows the `.rb`
  # expansion FIRST and appends the units second; before that fix the `@analyze_only` select ate them, and
  # `IncrementalSession` neither replayed them from its cache (they are not in `current_files`) nor kept
  # them in `@analyzed`, so the finding vanished from the second run onwards.
  describe "an `--incremental` recheck" do
    it "reports the template diagnostic on the recheck as well as on the baseline" do
      Dir.mktmpdir("rigor-392-inc-") do |dir|
        build_project(dir)
        config = configuration(effects: false, workers: 0, plugins: true)
        Dir.chdir(dir) do
          session = Rigor::Analysis::IncrementalSession.new(
            configuration: config, paths: ["lib"],
            plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
          )
          baseline = guarded_baseline(session)
          recheck = guarded_recheck(session)

          expect(template_findings(baseline)).to eq([["call.undefined-method", 4]])
          expect(template_findings(recheck.diagnostics)).to eq([["call.undefined-method", 4]])
        end
      end
    end

    # The units must also stay out of the session's analysed set, or the FIRST recheck reads them as files
    # that vanished from the project and evicts them.
    it "never counts a unit as a project file that was added or removed" do
      Dir.mktmpdir("rigor-392-inc2-") do |dir|
        build_project(dir)
        config = configuration(effects: false, workers: 0, plugins: true)
        Dir.chdir(dir) do
          session = Rigor::Analysis::IncrementalSession.new(
            configuration: config, paths: ["lib"],
            plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
          )
          guarded_baseline(session)
          recheck = guarded_recheck(session)

          expect(recheck.removed.to_a).to eq([])
          expect(recheck.added.to_a).to eq([])
        end
      end
    end
  end

  # #392 review S1 — Prism parses a bare identifier with no assignment in sight as a method call, so a
  # seeded local was never consulted until the parse declared the render site's locals as an enclosing
  # scope. `size` is a `String` here, and calling something String does not have must say so.
  describe "the render site's locals" do
    it "types a bare local as the declared type rather than as a method call" do
      in_project(effects: false, template_body: "size.nope
") do |_runner, result|
        found = result.diagnostics.select { |d| d.path.end_with?("show.rbx") }

        expect(found.map { |d| [d.rule, d.receiver_type] }).to eq([["call.undefined-method", "String"]])
      end
    end
  end

  # #392 review S2 — a declared-but-unresolvable `self_type:` used to leave the body typing at top level,
  # so every helper call reported `call.unresolved-toplevel`. That is a finding per line caused by the
  # plugin naming a class whose RBS the project does not ship — `ActionView::Base` on the first real Rails
  # app — which is exactly the false-positive direction the engine must not take (ADR-5).
  describe "a declared type the environment cannot resolve" do
    # The body carries two helper calls AND one genuine finding, so the example says both halves at once:
    # the helper calls are silent (Dynamic, not top-level), and the file was really analysed rather than
    # skipped — the `String` row is still reported at its template line.
    it "binds Dynamic and stays silent rather than typing the body at top level" do
      body = "render_header(1)\nrender_footer(2)\n@title.upcasee\n"
      in_project(effects: false, self_type: "Nope::Missing", template_body: body) do |_runner, result|
        found = result.diagnostics.select { |d| d.path.end_with?("show.rbx") }

        expect(found.map { |d| [d.rule, d.line] }).to eq([["call.undefined-method", 3]])
      end
    end
  end

  # #392 review S3 — a unit may only name the file it was compiled from. Without the check a `path:`
  # naming another project file silently replaced that file's source, and one naming a path outside the
  # root was analysed with no dependency-descriptor row.
  describe "a unit that names a file it was not offered" do
    it "is refused, and the project file it aimed at is analysed from its own bytes" do
      in_project(effects: false, unit_path: "lib/app.rb", allow_plugin_crash: true) do |_runner, result|
        rows = result.diagnostics.select { |d| d.rule == "runtime-error" }

        expect(rows.map(&:path)).to eq(["app/views/users/show.rbx"])
        expect(rows.first.message).to include("may only name its own source")
        expect(result.diagnostics.select { |d| d.path.end_with?(".rbx") && d.rule != "runtime-error" }).to eq([])
      end
    end
  end

  # #392 review S4 — a raising transform is reported through the same `:plugin_loader` `runtime-error`
  # envelope a raise from `#diagnostics_for_file` uses, not dropped in silence.
  describe "a transform that raises" do
    it "reports one plugin-isolation row for the file and leaves the run standing" do
      in_project(effects: false, raise_on_transform: true, allow_plugin_crash: true) do |_runner, result|
        rows = result.diagnostics.select { |d| d.source_family == :plugin_loader }

        expect(rows.map { |d| [d.path, d.rule] }).to eq([["app/views/users/show.rbx", "runtime-error"]])
        expect(rows.first.message).to include("produced no template unit")
      end
    end
  end

  # #392 review round 2 B1 — the ADR-45 run-result cache must never answer for a world that has a
  # different set of templates in it. Both examples run the SAME project root twice with one cache store,
  # which is what `rigor check` does; the second run's answer has to match a `--no-cache` oracle.
  describe "the run-result cache across a template's life" do
    # One `rigor check` in this project root, engine path then probe path, the way the CLI runs it: the
    # ADR-87 boot-slim probe is asked FIRST and the engine runs only when it declines. The probe is the
    # half that matters here — it loads no plugin, so it reconstructs a key with no `template-units` slot,
    # and every stale answer this block pins was a probe hit on a key the engine had written.
    def cached_run(dir, root)
      config = configuration(effects: false, workers: 0, plugins: true)
      Dir.chdir(dir) do
        served = Rigor::Analysis::RunCacheProbe.new(
          configuration: config, cache_root: root, explain: false
        ).serve(["lib"])
        next served.diagnostics if served

        store = Rigor::Cache::Store.new(root: root)
        runner = Rigor::Analysis::Runner.new(
          configuration: config, cache_store: store,
          plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
        )
        guarded_run(runner, ["lib"], allow_plugin_crash: true).diagnostics
      end
    end

    # A project whose FIRST template appears between two runs. Before the `:names` glob row the descriptor
    # listed only the templates that already existed, so nothing noticed the new file and the warm run
    # replayed the answer computed before it was written.
    it "sees a template that appeared since the run it cached" do
      Dir.mktmpdir("rigor-392-c1-") do |dir|
        build_project(dir, template: false)
        root = File.join(dir, ".rigor", "cache")
        expect(cached_run(dir, root)).to eq([])

        build_project(dir)

        expect(template_findings(cached_run(dir, root))).to eq([["call.undefined-method", 4]])
      end
    end

    # A run whose transform failed produced an answer — one `plugin_loader` row — under a key that, before
    # the failures joined the digest, was the no-templates key. The boot-slim probe reconstructs exactly
    # that key, so the row outlived the edit that fixed the template.
    it "sees a template that stopped failing since the run it cached" do
      Dir.mktmpdir("rigor-392-c2-") do |dir|
        build_project(dir)
        root = File.join(dir, ".rigor", "cache")
        RigorViewDemoPlugin.spec_overrides = { raise_on_transform: true }
        expect(cached_run(dir, root).map(&:rule)).to eq(["runtime-error"])

        RigorViewDemoPlugin.spec_overrides = {}

        expect(template_findings(cached_run(dir, root))).to eq([["call.undefined-method", 4]])
      end
    ensure
      RigorViewDemoPlugin.spec_overrides = {}
    end
  end

  # #392 review round 2 S1 — editor mode. `TemplateUnits.collect` reads through the `BufferBinding`, so a
  # `--tmp-file` / `--instead-of` pair naming a TEMPLATE compiles the editor's bytes; before the fix the
  # transform read the saved file and the editor was published diagnostics it had already fixed.
  describe "an editor buffer bound to a template" do
    it "compiles the buffer's bytes rather than the file on disk" do
      Dir.mktmpdir("rigor-392-buf-") do |dir|
        build_project(dir, body: "render_header(@title.upcase)\n")
        buffer_path = File.join(dir, "buffer.rbx")
        File.write(buffer_path, "render_header(@title.nope_from_buffer)\n")
        logical = "app/views/users/show.rbx"
        binding = Rigor::Analysis::BufferBinding.new(logical_path: logical, physical_path: buffer_path)
        config = configuration(effects: false, workers: 0, plugins: true)

        found = Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: config, cache_store: nil, buffer: binding,
            plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
          )
          guarded_run(runner, [logical]).diagnostics
        end

        expect(found.map { |d| [d.path, d.method_name] }).to eq([[logical, "nope_from_buffer"]])
      end
    end

    # `didOpen` on a freshly created view: the file exists only in the editor, so `Dir.glob` cannot see it
    # and the plugin was never offered it. The run then parsed the tmp bytes as plain top-level Ruby — no
    # declared `self`, no seeds — so a helper call read as `call.unresolved-toplevel` and the finding the
    # editor was looking at was missed.
    it "compiles a buffer whose template does not exist on disk at all" do
      Dir.mktmpdir("rigor-392-new-") do |dir|
        build_project(dir, template: false)
        buffer_path = File.join(dir, "buffer.rbx")
        File.write(buffer_path, "render_header(@title.nope_from_buffer)\n")
        logical = "app/views/users/new.rbx"
        binding = Rigor::Analysis::BufferBinding.new(logical_path: logical, physical_path: buffer_path)
        config = configuration(effects: false, workers: 0, plugins: true)

        found = Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: config, cache_store: nil, buffer: binding,
            plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
          )
          guarded_run(runner, [logical]).diagnostics
        end

        expect(found.map { |d| [d.rule, d.method_name] }).to eq([["call.undefined-method", "nope_from_buffer"]])
      end
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
