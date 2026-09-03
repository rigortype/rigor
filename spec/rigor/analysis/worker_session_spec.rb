# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/worker_session"
require "rigor/cache/store"
require "rigor/configuration"
require "rigor/plugin"

# ADR-15 Phase 4a substrate. The session-level guarantees:
#
# - Equivalence with `Runner#analyze_file` for the per-file
#   diagnostic stream (no plugins, plugins, --explain, parse
#   errors). This is the contract Phase 4b's Ractor pool relies
#   on when it dispatches paths across worker sessions.
# - Plugin lifecycle replay through {Plugin::Registry.materialize}
#   plus per-session `prepare` invocation captured into
#   `prepare_diagnostics`. Plugin runtime errors surface as the
#   same `runtime-error / source_family: :plugin_loader`
#   diagnostics the Runner emits today.
# - Per-session ownership of {RbsExtended::Reporter} and
#   {DependencySourceInference::BoundaryCrossReporter} so worker
#   pools can merge entries via `#drain_reporters` after the
#   pool drains.
RSpec.describe Rigor::Analysis::WorkerSession do
  describe "equivalence with Runner#analyze_file (no plugins)" do
    it "produces the same per-file diagnostics for a clean file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        runner_diags = Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          )
          guarded_run(runner).diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end
        session_diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        expect(diag_keys(session_diags)).to eq(diag_keys(runner_diags))
      end
    end

    it "produces the same parse-error diagnostics for an unparseable file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.rb")
        File.write(path, "def broken\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        runner_diags = Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          )
          guarded_run(runner).diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end
        session_diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        expect(session_diags).not_to be_empty
        expect(diag_keys(session_diags)).to eq(diag_keys(runner_diags))
      end
    end

    it "honours --explain — same `fallback` stream as Runner (modulo source-driven event count)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        runner_diags = Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, explain: true
          )
          guarded_run(runner).diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil, explain: true)
        end
        session_diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        # The CoverageScanner stream is identical regardless of whether the chosen source happens to trigger any
        # fallback events — equivalence is the contract proof.
        expect(diag_keys(session_diags)).to eq(diag_keys(runner_diags))
      end
    end

    it "surfaces an analyzer-error diagnostic when the source path disappears mid-run" do
      Dir.mktmpdir do |dir|
        configuration = Rigor::Configuration.new("paths" => [dir])
        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end

        diags = Dir.chdir(dir) { guarded_session_analyze(session, File.join(dir, "ghost.rb")) }
        expect(diags.size).to eq(1)
        expect(diags.first.severity).to eq(:error)
      end
    end
  end

  describe "plugin contract via blueprints" do
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "session-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          [
            Rigor::Analysis::Diagnostic.new(
              path: path, line: 1, column: 1,
              message: "session plugin saw #{File.basename(path)}",
              severity: :info, rule: "session-rule"
            )
          ]
        end
      end
    end

    before do
      Rigor::Plugin.unregister!
      stub_const("WorkerSessionStubPlugin", plugin_class)
      Rigor::Plugin.register(plugin_class)
    end

    after { Rigor::Plugin.unregister! }

    it "instantiates plugins from blueprints + runs init" do
      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionStubPlugin")
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []),
        cache_store: nil, plugin_blueprints: [blueprint]
      )

      expect(session.plugin_registry.plugins.size).to eq(1)
      expect(session.plugin_registry.plugins.first).to be_a(plugin_class)
    end

    it "stamps plugin-emitted diagnostics with `plugin.<manifest.id>` source_family" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionStubPlugin")
        configuration = Rigor::Configuration.new("paths" => [path])

        session = Dir.chdir(dir) do
          described_class.new(
            configuration: configuration, cache_store: nil,
            plugin_blueprints: [blueprint]
          )
        end
        diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        plugin_diag = diags.find { |d| d.rule == "session-rule" }
        expect(plugin_diag).not_to be_nil
        expect(plugin_diag.source_family).to eq("plugin.session-plugin")
      end
    end

    it "captures plugin#prepare exceptions into prepare_diagnostics" do
      raising_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "session-prepare-raises", version: "0.1.0")

        def prepare(_services)
          raise StandardError, "prepare boom"
        end
      end
      stub_const("WorkerSessionPrepareRaises", raising_class)
      Rigor::Plugin.register(raising_class)

      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionPrepareRaises")
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []),
        cache_store: nil, plugin_blueprints: [blueprint]
      )

      expect(session.prepare_diagnostics.size).to eq(1)
      diag = session.prepare_diagnostics.first
      expect(diag.severity).to eq(:error)
      expect(diag.rule).to eq("runtime-error")
      expect(diag.source_family).to eq(:plugin_loader)
      expect(diag.message).to include("session-prepare-raises")
      expect(diag.message).to include("prepare boom")
    end

    it "isolates plugin#diagnostics_for_file exceptions as runtime-error diagnostics" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        raising_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "session-runtime-raises", version: "0.1.0")

          def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
            raise StandardError, "boom"
          end
        end
        stub_const("WorkerSessionRuntimeRaises", raising_class)
        Rigor::Plugin.register(raising_class)

        blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionRuntimeRaises")
        configuration = Rigor::Configuration.new("paths" => [path])

        session = Dir.chdir(dir) do
          described_class.new(
            configuration: configuration, cache_store: nil,
            plugin_blueprints: [blueprint]
          )
        end
        diags = Dir.chdir(dir) { guarded_session_analyze(session, path, allow_plugin_crash: true) }

        runtime = diags.find { |d| d.rule == "runtime-error" && d.source_family == :plugin_loader }
        expect(runtime).not_to be_nil
        expect(runtime.message).to include("session-runtime-raises")
        expect(runtime.message).to include("boom")
      end
    end

    it "isolates a raising node_rule into a runtime-error diagnostic naming the plugin " \
       "(node_rule_results_by_plugin keys by `plugin` / collect_plugin_diagnostics re-raises)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "foo(1)\n")
        raising_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "session-node-rule-raises", version: "0.1.0")

          node_rule Prism::CallNode do |_node, _scope, _path|
            raise StandardError, "node rule boom"
          end
        end
        stub_const("WorkerSessionNodeRuleRaises", raising_class)
        Rigor::Plugin.register(raising_class)

        blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionNodeRuleRaises")
        configuration = Rigor::Configuration.new("paths" => [path])

        session = Dir.chdir(dir) do
          described_class.new(
            configuration: configuration, cache_store: nil,
            plugin_blueprints: [blueprint]
          )
        end
        diags = Dir.chdir(dir) { guarded_session_analyze(session, path, allow_plugin_crash: true) }

        runtime = diags.find { |d| d.rule == "runtime-error" && d.source_family == :plugin_loader }
        expect(runtime).not_to be_nil
        expect(runtime.message).to include("session-node-rule-raises")
        expect(runtime.message).to include("node rule boom")
      end
    end

    it "appends a successful node_result's diagnostics (no error), stamped with plugin source_family" do
      # Base#diagnostics_for_file already returns [], so no override is needed — the node_result diagnostics are the
      # only input here.
      stub_const("WorkerSessionNodeResultSuccess", Class.new(Rigor::Plugin::Base) do
        manifest(id: "session-noderesult-success", version: "0.1.0")
      end)
      Rigor::Plugin.register(WorkerSessionNodeResultSuccess)

      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "WorkerSessionNodeResultSuccess")
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []),
        cache_store: nil, plugin_blueprints: [blueprint]
      )
      plugin = session.plugin_registry.plugins.first

      node_diagnostic = Rigor::Analysis::Diagnostic.new(
        path: "x.rb", line: 3, column: 2,
        message: "from node rule", severity: :info, rule: "node-rule"
      )
      # A Result with no error but carrying diagnostics exercises the SUCCESS branch `raw += node_result.diagnostics if
      # node_result`.
      node_result = Rigor::Plugin::NodeRuleWalk::Result.new(plugin, [node_diagnostic], nil)

      diags = session.send(
        :collect_plugin_diagnostics, plugin, "x.rb", nil, Rigor::Scope.empty, node_result
      )

      appended = diags.find { |d| d.rule == "node-rule" }
      expect(appended&.message).to eq("from node rule")
      expect(appended&.source_family).to eq("plugin.session-noderesult-success")
    end

    it "names the plugin CLASS in a runtime-error diagnostic when manifest.id raises " \
       "(safe_plugin_id rescue -> plugin.class.to_s)" do
      raising_manifest_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "unused-when-manifest-raises", version: "0.1.0")

        def manifest
          raise StandardError, "manifest exploded"
        end
      end
      stub_const("WorkerSessionRaisingManifest", raising_manifest_class)
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      # `allocate` avoids invoking a normal `#initialize` path; only the overridden `#manifest` (which raises) matters
      # for the fallback.
      plugin = raising_manifest_class.allocate

      diag = session.send(
        :plugin_runtime_error_diagnostic, "x.rb", plugin, StandardError.new("boom")
      )

      expect(diag.message).to include("WorkerSessionRaisingManifest")
      expect(diag.message).to include("boom")
    end
  end

  describe "reporter ownership" do
    it "constructs its own RbsExtended::Reporter + BoundaryCrossReporter" do
      session_a = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      session_b = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )

      expect(session_a.rbs_extended_reporter).not_to equal(session_b.rbs_extended_reporter)
      expect(session_a.boundary_cross_reporter).not_to equal(session_b.boundary_cross_reporter)
    end

    it "exposes drain_reporters with frozen Array snapshots" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      drained = session.drain_reporters

      expect(drained[:rbs_extended][:unresolved_payloads]).to be_frozen
      expect(drained[:rbs_extended][:lossy_projections]).to be_frozen
      expect(drained[:boundary_cross]).to be_frozen
    end

    it "threads the per-session reporters into Environment so the dispatcher writes into them" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )

      expect(session.environment.rbs_extended_reporter).to equal(session.rbs_extended_reporter)
      expect(session.environment.boundary_cross_reporter).to equal(session.boundary_cross_reporter)
    end
  end

  describe "editor mode (buffer: BufferBinding)" do
    it "parses bytes from the buffer's physical path when analyzing the logical path" do
      Dir.mktmpdir("rigor-worker-session-buffer-") do |tmpdir|
        Dir.chdir(tmpdir) do
          logical = File.join("lib", "foo.rb")
          FileUtils.mkdir_p("lib")
          File.write(logical, "x = 1\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "def broken\n")

          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          session = described_class.new(
            configuration: Rigor::Configuration.new("paths" => ["lib"]),
            cache_store: nil, buffer: binding
          )

          diagnostics = guarded_session_analyze(session, logical)

          # Parse-error from the BUFFER, attributed to the LOGICAL path.
          expect(diagnostics).not_to be_empty
          expect(diagnostics.map(&:path).uniq).to eq([logical])
        end
      end
    end

    it "threads configuration.target_ruby into the buffer-path Prism.parse call" do
      Dir.mktmpdir("rigor-worker-session-buffer-") do |tmpdir|
        Dir.chdir(tmpdir) do
          logical = File.join("lib", "foo.rb")
          FileUtils.mkdir_p("lib")
          File.write(logical, "x = 1\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "y = 2\n")

          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          # "3.0" is version-shaped (passes Configuration's own validation) but is older than Prism's supported set, so
          # Prism.parse itself raises ArgumentError — a discriminating probe that the buffer-path resolve() AND
          # target_ruby both actually reach Prism.parse's `version:` keyword.
          configuration = Rigor::Configuration.new("paths" => ["lib"], "target_ruby" => "3.0")
          session = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          )

          diagnostics = session.analyze(logical)

          expect(diagnostics.size).to eq(1)
          expect(diagnostics.first.message).to include("invalid version")
        end
      end
    end
  end

  describe "--explain fallback diagnostics (explain_diagnostics / explain_diagnostic)" do
    it "emits one `:info` / `fallback` diagnostic per CoverageScanner event, " \
       "with column = location.start_column + 1" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        # A flip-flop condition is a directly-unrecognised node, so the CoverageScanner records a real fail-soft
        # fallback event — driving `explain_diagnostics` through the non-empty `result.events` map.
        File.write(path, "if (a..b)\nend\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil, explain: true)
        end
        diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        fallbacks = diags.select { |d| d.rule == "fallback" }
        expect(fallbacks).not_to be_empty
        expect(fallbacks.map(&:severity).uniq).to eq([:info])

        flipflop = fallbacks.find { |d| d.message.include?("Prism::FlipFlopNode") }
        expect(flipflop).not_to be_nil
        # `(` sits at zero-indexed column 4; the diagnostic is +1 (1-indexed).
        expect(flipflop.line).to eq(1)
        expect(flipflop.column).to eq(5)
        expect(flipflop.message).to eq("fail-soft fallback at Prism::FlipFlopNode: Dynamic[top]")
      end
    end

    it "returns [] when @explain is false (never scans)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "if (a..b)\nend\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil, explain: false)
        end
        diags = Dir.chdir(dir) { guarded_session_analyze(session, path) }

        expect(diags.map(&:rule)).not_to include("fallback")
      end
    end

    it "explain_diagnostic derives line/column from event.location (start_column + 1)" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      location = instance_double(Prism::Location, start_line: 7, start_column: 3)
      inner_type = instance_double(Rigor::Type::Dynamic)
      allow(inner_type).to receive(:describe).with(:short).and_return("String")
      event = instance_double(
        Rigor::Inference::Fallback,
        location: location, node_class: Prism::CallNode, inner_type: inner_type
      )

      diag = session.send(:explain_diagnostic, "x.rb", event)

      expect(diag.line).to eq(7)
      expect(diag.column).to eq(4) # start_column (3) + 1
      expect(diag.severity).to eq(:info)
      expect(diag.rule).to eq("fallback")
      expect(diag.message).to eq("fail-soft fallback at Prism::CallNode: String")
    end

    it "explain_diagnostic falls back to line/column 1 when event.location is nil" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      inner_type = instance_double(Rigor::Type::Dynamic)
      allow(inner_type).to receive(:describe).with(:short).and_return("Integer")
      event = instance_double(
        Rigor::Inference::Fallback,
        location: nil, node_class: Prism::IntegerNode, inner_type: inner_type
      )

      diag = session.send(:explain_diagnostic, "x.rb", event)

      expect(diag.line).to eq(1)
      expect(diag.column).to eq(1)
      expect(diag.message).to eq("fail-soft fallback at Prism::IntegerNode: Integer")
    end
  end

  describe "#analyze error handling (analyzer_error / target_ruby)" do
    it "captures a StandardError raised while parsing into a single :error diagnostic " \
       "carrying the exception class and message" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        # Same "version-shaped but Prism-unsupported" probe as above, exercised on the non-buffer `Prism.parse_file`
        # path this time.
        configuration = Rigor::Configuration.new("paths" => [path], "target_ruby" => "3.0")

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end
        diagnostics = Dir.chdir(dir) { session.analyze(path) }

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.path).to eq(path)
        expect(diag.line).to eq(1)
        expect(diag.column).to eq(1)
        expect(diag.severity).to eq(:error)
        expect(diag.message).to include("internal analyzer error")
        expect(diag.message).to include("ArgumentError")
        expect(diag.message).to include("invalid version")
      end
    end
  end

  describe "#seed_project_scope / with_discovery (private)" do
    it "threads the project_scope_seed discovery tables into a fresh scope" do
      seed = { discovered_methods: { "Foo" => { baz: :instance } } }
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []),
        cache_store: nil, project_scope_seed: seed
      )
      scope = Rigor::Scope.empty(environment: session.environment, source_path: "x.rb")

      seeded = session.send(:seed_project_scope, scope)

      expect(scope.discovered_method?("Foo", :baz, :instance)).to be(false)
      expect(seeded.discovered_method?("Foo", :baz, :instance)).to be(true)
    end

    it "returns the scope unchanged when project_scope_seed is empty" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      scope = Rigor::Scope.empty(environment: session.environment, source_path: "x.rb")

      expect(session.send(:seed_project_scope, scope)).to equal(scope)
    end
  end

  describe "#trusted_gem_name / #trusted_gem_root (private, build_trust_policy)" do
    it "resolves a String plugin entry to itself" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      expect(session.send(:trusted_gem_name, "rigor-example")).to eq("rigor-example")
    end

    it "resolves a Hash plugin entry via the `gem` key, falling back to `id`" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      expect(session.send(:trusted_gem_name, { "gem" => "foo", "id" => "bar" })).to eq("foo")
      expect(session.send(:trusted_gem_name, { "id" => "bar" })).to eq("bar")
      expect(session.send(:trusted_gem_name, { "gem" => nil, "id" => "bar" })).to eq("bar")
    end

    it "returns nil for a plugin entry of an unrecognised shape" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      expect(session.send(:trusted_gem_name, 42)).to be_nil
    end

    it "resolves trusted_gem_root to the loaded spec's full_gem_path" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      fake_spec = instance_double(Gem::Specification, full_gem_path: "/fake/gem/path")
      allow(Gem).to receive(:loaded_specs).and_return({ "myfakegem" => fake_spec })

      expect(session.send(:trusted_gem_root, "myfakegem")).to eq("/fake/gem/path")
    end

    it "returns nil for trusted_gem_root when gem_name is nil or empty" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      expect(session.send(:trusted_gem_root, nil)).to be_nil
      expect(session.send(:trusted_gem_root, "")).to be_nil
    end

    it "returns nil for trusted_gem_root when the gem is not loaded" do
      session = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []), cache_store: nil
      )
      allow(Gem).to receive(:loaded_specs).and_return({})

      expect(session.send(:trusted_gem_root, "totally-unloaded-gem")).to be_nil
    end

    it "threads a trusted gem's root into TrustPolicy#allowed_read_roots via build_trust_policy" do
      fake_spec = instance_double(Gem::Specification, full_gem_path: "/fake/gem/root")
      allow(Gem).to receive(:loaded_specs).and_return({ "myfakegem" => fake_spec })

      configuration = Rigor::Configuration.new("paths" => [], "plugins" => ["myfakegem"])
      session = described_class.new(configuration: configuration, cache_store: nil)

      expect(session.services.trust_policy.trusted_gems).to eq(["myfakegem"])
      expect(session.services.trust_policy.allowed_read_roots).to include("/fake/gem/root")
    end
  end

  # Per-file diagnostic comparison key. Severity is intentionally excluded from the key because the Runner re-stamps
  # severity via `apply_severity_profile` AFTER the per-file pass, whereas the WorkerSession returns raw (un-stamped)
  # per-file output — severity-profile application is the caller's responsibility. The remaining fields capture every
  # per-file invariant the equivalence contract is built on.
  def diag_keys(diagnostics)
    diagnostics.map do |d|
      [d.path, d.line, d.column, d.rule, d.source_family, d.message]
    end.sort
  end
end
