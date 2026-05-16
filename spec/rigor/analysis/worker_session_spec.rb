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
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          ).run.diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end
        session_diags = Dir.chdir(dir) { session.analyze(path) }

        expect(diag_keys(session_diags)).to eq(diag_keys(runner_diags))
      end
    end

    it "produces the same parse-error diagnostics for an unparseable file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.rb")
        File.write(path, "def broken\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        runner_diags = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          ).run.diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil)
        end
        session_diags = Dir.chdir(dir) { session.analyze(path) }

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
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, explain: true
          ).run.diagnostics
        end

        session = Dir.chdir(dir) do
          described_class.new(configuration: configuration, cache_store: nil, explain: true)
        end
        session_diags = Dir.chdir(dir) { session.analyze(path) }

        # The CoverageScanner stream is identical regardless of
        # whether the chosen source happens to trigger any
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

        diags = Dir.chdir(dir) { session.analyze(File.join(dir, "ghost.rb")) }
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
        diags = Dir.chdir(dir) { session.analyze(path) }

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
        diags = Dir.chdir(dir) { session.analyze(path) }

        runtime = diags.find { |d| d.rule == "runtime-error" && d.source_family == :plugin_loader }
        expect(runtime).not_to be_nil
        expect(runtime.message).to include("session-runtime-raises")
        expect(runtime.message).to include("boom")
      end
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

          diagnostics = session.analyze(logical)

          # Parse-error from the BUFFER, attributed to the LOGICAL path.
          expect(diagnostics).not_to be_empty
          expect(diagnostics.map(&:path).uniq).to eq([logical])
        end
      end
    end
  end

  # Per-file diagnostic comparison key. Severity is intentionally
  # excluded from the key because the Runner re-stamps severity
  # via `apply_severity_profile` AFTER the per-file pass, whereas
  # the WorkerSession returns raw (un-stamped) per-file output —
  # severity-profile application is the caller's responsibility.
  # The remaining fields capture every per-file invariant the
  # equivalence contract is built on.
  def diag_keys(diagnostics)
    diagnostics.map do |d|
      [d.path, d.line, d.column, d.rule, d.source_family, d.message]
    end.sort
  end
end
