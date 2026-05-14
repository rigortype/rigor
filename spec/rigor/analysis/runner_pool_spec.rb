# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/plugin"

# ADR-15 Phase 4b — Runner Ractor pool equivalence.
#
# The pool path (`workers: N > 0`) MUST produce the same diagnostic
# stream as the sequential path (`workers: 0` — the default).
# Specs here exercise:
#
# - Empty file lists short-circuit (no Ractor spawn).
# - Single-worker + multi-worker pools produce the same per-file
#   diagnostics as the sequential coordinator path.
# - Diagnostic order respects original path order even though
#   workers complete files out of order.
# - Plugin emission replays via blueprints (per-worker plugin
#   instances) and stamps diagnostics with `plugin.<id>` as the
#   sequential path does.
# - Plugin `#prepare` errors surface ONCE despite each worker
#   independently running `prepare` on its own plugin instance
#   (deterministic-per-plugin contract; coordinator keeps the
#   first worker's snapshot).
RSpec.describe "Rigor::Analysis::Runner with Ractor pool (Phase 4b)" do
  # Per-file diagnostic comparison key. Severity is stripped
  # because the severity-profile re-stamping is identical on
  # both code paths (the profile sees the same authored
  # severity → resolved severity table); the remaining fields
  # are the per-file invariant the equivalence contract binds.
  def diag_keys(diagnostics)
    diagnostics.map do |d|
      [d.path, d.line, d.column, d.rule, d.source_family, d.message]
    end.sort
  end

  describe "equivalence with the sequential path" do
    it "returns an empty diagnostic stream when no files are configured" do
      Dir.mktmpdir do |dir|
        configuration = Rigor::Configuration.new("paths" => [dir])
        result = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: Rigor::Cache::Store.new(root: File.join(dir,
                                                                                               ".rigor")), workers: 2
          ).run
        end

        expect(result.diagnostics).to be_empty
      end
    end

    it "produces the same per-file diagnostics for a single file with workers: 1" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [path])

        sequential = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          ).run.diagnostics
        end
        pool = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: Rigor::Cache::Store.new(root: File.join(dir,
                                                                                               ".rigor")), workers: 1
          ).run.diagnostics
        end

        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end

    it "produces the same per-file diagnostics for many files with workers: 4" do
      Dir.mktmpdir do |dir|
        paths = Array.new(6) do |i|
          path = File.join(dir, "file_#{i}.rb")
          File.write(path, "x_#{i} = #{i}\n")
          path
        end
        configuration = Rigor::Configuration.new("paths" => paths)

        sequential = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil
          ).run.diagnostics
        end
        pool = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: Rigor::Cache::Store.new(root: File.join(dir,
                                                                                               ".rigor")), workers: 4
          ).run.diagnostics
        end

        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end

    it "handles non-trivial source that exercises the RBS dispatch chain (Phase 4b.x)" do
      # Without the Phase 4b.x cache pre-warm, the worker
      # would call `RBS::EnvironmentLoader.new` on first
      # class lookup and trip
      # `Ractor::IsolationError` reading
      # `RBS::EnvironmentLoader::DEFAULT_CORE_ROOT` etc.
      # The pre-warm ensures every cached producer is warm
      # on the main Ractor first, so the worker's
      # `cached_env` Marshal-load path serves every query
      # without ever touching `EnvironmentLoader.new`.
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, <<~RUBY)
          "hello".no_such_method
          [1, 2, 3].rotate(1, 2, 3)
        RUBY
        configuration = Rigor::Configuration.new("paths" => [path])

        sequential = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor-seq"))
          ).run.diagnostics
        end
        pool = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor-pool")), workers: 2
          ).run.diagnostics
        end

        # Both runs MUST flag the same `call.undefined-method`
        # / `call.wrong-arity` diagnostics — proves the
        # worker dispatched through RBS without crashing.
        expect(diag_keys(pool).select { |k| %w[call.undefined-method call.wrong-arity].include?(k[3]) }).to eq(
          diag_keys(sequential).select { |k| %w[call.undefined-method call.wrong-arity].include?(k[3]) }
        )
      end
    end

    it "degrades gracefully to sequential when pool mode is configured without a cache_store" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [path])
        result = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, workers: 2
          ).run
        end

        degraded = result.diagnostics.find { |d| d.rule == "pool-degraded" }
        expect(degraded).not_to be_nil
        expect(degraded.severity).to eq(:warning)
        expect(degraded.message).to include("requires a cache_store")
      end
    end

    it "preserves original path order even when workers complete out of order" do
      Dir.mktmpdir do |dir|
        # Each file emits a parse-error diagnostic so the
        # per-file output is deterministic; the resulting
        # diagnostic stream's `path` sequence MUST match the
        # input path order.
        paths = Array.new(5) do |i|
          path = File.join(dir, "broken_#{i}.rb")
          File.write(path, "def broken_#{i}\n")
          path
        end
        configuration = Rigor::Configuration.new("paths" => paths)

        pool = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: Rigor::Cache::Store.new(root: File.join(dir,
                                                                                               ".rigor")), workers: 3
          ).run.diagnostics
        end

        observed_path_order = pool.map(&:path).uniq
        expect(observed_path_order).to eq(paths)
      end
    end
  end

  describe "plugin lifecycle replay across the pool" do
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "pool-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          [
            Rigor::Analysis::Diagnostic.new(
              path: path, line: 1, column: 1,
              message: "pool plugin saw #{File.basename(path)}",
              severity: :info, rule: "pool-rule"
            )
          ]
        end
      end
    end

    before do
      Rigor::Plugin.unregister!
      stub_const("RunnerPoolStubPlugin", plugin_class)
    end

    after { Rigor::Plugin.unregister! }

    it "stamps plugin-emitted diagnostics from per-worker instances" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        paths = Array.new(3) do |i|
          path = File.join(dir, "file_#{i}.rb")
          File.write(path, "x = #{i}\n")
          path
        end
        configuration = Rigor::Configuration.new(
          "paths" => paths,
          "plugins" => ["rigor-pool-plugin"]
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end

        result = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor")),
            plugin_requirer: requirer, workers: 2
          ).run
        end

        plugin_diags = result.diagnostics.select { |d| d.rule == "pool-rule" }
        expect(plugin_diags.size).to eq(3)
        expect(plugin_diags.map(&:source_family).uniq).to eq(["plugin.pool-plugin"])
        expect(plugin_diags.map { |d| File.basename(d.path) }.sort).to eq(%w[file_0.rb file_1.rb file_2.rb])
      end
    end

    it "deduplicates per-worker plugin#prepare errors to a single diagnostic" do # rubocop:disable RSpec/ExampleLength
      raising_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "pool-prepare-raises", version: "0.1.0")

        def prepare(_services)
          raise StandardError, "prepare boom"
        end
      end
      stub_const("RunnerPoolPrepareRaises", raising_class)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        configuration = Rigor::Configuration.new(
          "paths" => [path],
          "plugins" => ["rigor-pool-prepare-raises"]
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(raising_class)
          true
        end

        result = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor")),
            plugin_requirer: requirer, workers: 3
          ).run
        end

        prepare_errors = result.diagnostics.select do |d|
          d.rule == "runtime-error" &&
            d.source_family == :plugin_loader &&
            d.message.include?("pool-prepare-raises")
        end
        # 3 workers, each runs `prepare` and raises; the
        # coordinator keeps only the first worker's snapshot.
        expect(prepare_errors.size).to eq(1)
      end
    end
  end
end
