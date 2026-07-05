# frozen_string_literal: true

require "tmpdir"

require_relative "../../environment"
require_relative "../diagnostic"
require_relative "../worker_session"
require_relative "../run_stats"
require_relative "../../rbs_extended/conformance_checker"

module Rigor
  module Analysis
    class Runner
      # Owns the per-file analysis dispatch: the sequential coordinator path (default) and both worker-pool
      # backends — the ADR-15 Phase 4b Ractor pool and the ADR-15 Amendment fork pool, plus the
      # pool-degraded fallback. Builds the coordinator-side Environment, snapshots the end-of-pass RBS
      # tables into the shared {RunSnapshots}, and merges per-worker reporter drains back into the runner's
      # reporter accumulators.
      #
      # Sequential-equivalence contract (docs/internal-spec/ worker-session.md): the pool path MUST produce
      # the same diagnostics, in the same order, as the sequential path. The coordinator re-orders worker
      # results by original path order and replays per-worker reporter entries through the dedupe-on-record
      # APIs so reporter state matches a single-session run.
      #
      # Per-run varying prepass state (plugin registry, dependency-source index, synthetic-method /
      # project-patched indexes) is read through injected reader procs; the actual per-file analysis is
      # delegated back through an injected `analyze_file` callable so the CheckRules / recorder /
      # plugin-emission machinery stays on the {Runner}.
      class PoolCoordinator # rubocop:disable Metrics/ClassLength
        # @param configuration [Rigor::Configuration]
        # @param cache_store [Rigor::Cache::Store, nil]
        # @param explain [Boolean]
        # @param workers [Integer]
        # @param collect_stats [Boolean]
        # @param buffer [BufferBinding, nil]
        # @param environment_override [Rigor::Environment, nil]
        # @param rbs_extended_reporter [RbsExtended::Reporter]
        # @param boundary_cross_reporter [DependencySourceInference::BoundaryCrossReporter]
        # @param source_rbs_synthesis_reporter [Plugin::SourceRbsSynthesisReporter]
        # @param snapshots [RunSnapshots] shared end-of-pass snapshot sink.
        # @param plugin_registry [#call] reader for the current registry.
        # @param dependency_source_index [#call] reader.
        # @param synthetic_method_index [#call] reader.
        # @param project_patched_methods [#call] reader.
        # @param project_scope_seed [#call] reader for the cross-file pre-pass seed tables
        #   (`Runner#project_scope_seed_tables`).
        # @param analyze_file [#call] `(path, environment) -> diagnostics`.
        def initialize(configuration:, cache_store:, explain:, workers:, collect_stats:, # rubocop:disable Metrics/ParameterLists
                       buffer:, environment_override:, rbs_extended_reporter:,
                       boundary_cross_reporter:, source_rbs_synthesis_reporter:,
                       snapshots:, plugin_registry:, dependency_source_index:,
                       synthetic_method_index:, project_patched_methods:,
                       analyze_file:, project_scope_seed: -> { {} })
          @configuration = configuration
          @cache_store = cache_store
          @explain = explain
          @workers = workers
          @collect_stats = collect_stats
          @buffer = buffer
          @environment_override = environment_override
          @rbs_extended_reporter = rbs_extended_reporter
          @boundary_cross_reporter = boundary_cross_reporter
          @source_rbs_synthesis_reporter = source_rbs_synthesis_reporter
          @snapshots = snapshots
          @plugin_registry_reader = plugin_registry
          @dependency_source_index_reader = dependency_source_index
          @synthetic_method_index_reader = synthetic_method_index
          @project_patched_methods_reader = project_patched_methods
          @project_scope_seed_reader = project_scope_seed
          @analyze_file = analyze_file
        end

        # ADR-15 Phase 4b — pool mode is enabled when `@workers > 0`. Editor mode (`buffer:` non-nil)
        # silently overrides pool mode to sequential: per design § "Ractor pool mode", the pool's warm-up
        # cost dominates one-file wall time, so the pool gains nothing on a per-buffer invocation. The
        # override is part of the contract — not a degradation diagnostic — because `--workers=N` is a
        # project-scale knob and editor mode is per-buffer; the conflict resolves toward the more specific
        # axis.
        def pool_mode?
          return false unless @workers.is_a?(Integer) && @workers.positive?

          @buffer.nil?
        end

        # ADR-15 Phase 4b — routes per-file analysis to either the sequential coordinator-side Environment
        # (legacy path, default) or a Ractor worker pool built around {WorkerSession} (opt-in via
        # `workers:`). The sequential path is bit-for-bit unchanged from v0.1.4 / earlier; the pool path is
        # the substrate exercised by phase 4c when `RIGOR_RACTOR_WORKERS` / `.rigor.yml`
        # `parallel.workers:` is wired.
        #
        # Sequential mode also snapshots `class_decl_paths` from the local environment after the per-file
        # loop completes so `RunStats` can attribute the RBS class universe between project-sig and bundled
        # sources. The env stays a LOCAL variable (not an ivar) so it goes GC-eligible when the method
        # returns — holding it as long-lived state added memory pressure that surfaced as a Bus Error
        # during the spec suite under Ruby 4.0 + rbs 4.0.2.
        def analyze_files(files, environment: nil)
          return [] if files.empty?
          return dispatch_pool(files) if pool_mode?

          analyze_files_sequentially(files, environment || resolve_sequential_environment(source_files: files))
        end

        def analyze_files_sequentially(files, environment)
          # Snapshot the small synthesized-namespace name list (NOT the env — see the method comment) so
          # #run can surface the malformed-RBS `:info` diagnostic without rebuilding the env. Gated on the
          # project actually declaring `signature_paths:`: synthesis only matters for the project's own
          # RBS, and `#synthesized_namespaces` forces the (otherwise-lazy) RBS env to build — doing so when
          # there is no project sig set would warm `.rigor/cache` on a bare `--no-stats` run.
          @snapshots.synthesized_namespaces =
            project_signature_paths? ? (environment.rbs_loader&.synthesized_namespaces || []) : []
          # `rigor:v1:conforms-to` lives only in the project's own `signature_paths:` RBS, so gate the scan
          # the same way and reuse the already-built env (no extra RBS load).
          @snapshots.conformance_results =
            project_signature_paths? ? RbsExtended::ConformanceChecker.scan(environment.rbs_loader) : []
          result = files.flat_map { |path| @analyze_file.call(path, environment) }
          if @collect_stats
            loader = environment.rbs_loader
            @snapshots.class_decl_paths = loader&.class_decl_paths || {}.freeze
            @snapshots.signature_paths = loader&.signature_paths || [].freeze
          end
          result
        end

        # Sequential-mode environment resolver. Returns the supplied `environment:` override (with the
        # runner's fresh per-run reporter pair attached so dispatcher events route to THIS runner's
        # diagnostics) when present; otherwise builds a fresh Environment per-call via
        # {#build_runner_environment} — preserving the pre-override behaviour bit-for-bit.
        def resolve_sequential_environment(source_files: [])
          return build_runner_environment(source_files: source_files) unless @environment_override

          @environment_override.attach_reporters!(
            rbs_extended_reporter: @rbs_extended_reporter,
            boundary_cross_reporter: @boundary_cross_reporter
          )
          @environment_override
        end

        # ADR-15 Amendment (2026-05-20) — worker-pool backend selector. `fork` is the active backend:
        # separate processes sidestep both the Ruby Bug #22075 use-after-free and the worker-side
        # `Ractor::IsolationError` that make the Ractor pool unusable (see the ADR-15 Amendment +
        # docs/notes/20260520-ractor-pool-cruby-uaf.md). The Ractor pool is preserved but off the default
        # path — `RIGOR_POOL_BACKEND=ractor` opts back in so it stays testable. Platforms without `fork`
        # (Windows) fall back to sequential.
        def pool_backend
          return :ractor if ENV["RIGOR_POOL_BACKEND"] == "ractor"
          return :fork if Process.respond_to?(:fork)

          :sequential
        end

        # Routes pool-mode analysis to the selected backend.
        def dispatch_pool(files)
          case pool_backend
          when :ractor then analyze_files_in_pool(files)
          when :fork   then analyze_files_in_fork_pool(files)
          else
            analyze_files_sequentially_fallback(
              files, reason: "fork-based parallelism is unavailable on this platform"
            )
          end
        end

        # Coordinator-side Environment used by the sequential code path. Pool mode builds one Environment
        # per worker inside the worker Ractor's body instead.
        #
        # ADR-32 WD4 — `source_files:` is threaded down so that `Environment.for_project` can invoke each
        # loaded plugin's `source_rbs_synthesizer` callable per project source file at env-build time.
        # Defaults to `[]` for callers that don't have a file list yet (e.g. pre-pass-only build paths); in
        # that case no synthesised RBS is contributed.
        def build_runner_environment(source_files: [])
          Environment.for_project(
            libraries: @configuration.libraries,
            signature_paths: @configuration.signature_paths,
            cache_store: @cache_store,
            plugin_registry: plugin_registry,
            dependency_source_index: dependency_source_index,
            rbs_extended_reporter: @rbs_extended_reporter,
            boundary_cross_reporter: @boundary_cross_reporter,
            source_rbs_synthesis_reporter: @source_rbs_synthesis_reporter,
            bundler_bundle_path: @configuration.bundler_bundle_path,
            bundler_auto_detect: @configuration.bundler_auto_detect,
            bundler_lockfile: @configuration.bundler_lockfile,
            rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
            rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect,
            synthetic_method_index: synthetic_method_index,
            project_patched_methods: project_patched_methods,
            source_files: source_files
          )
        end

        # ADR-15 Phase 4b — Ractor pool around {WorkerSession}. Spawns `@workers` Ractors; each takes the
        # shareable payload (Configuration, cache_root String, plugin Blueprint Array, explain Boolean) and
        # builds its OWN WorkerSession internally. Files are distributed round-robin across the pool; each
        # worker writes back to the main Ractor's mailbox via `Ractor.main.send` with one of three message
        # kinds:
        #
        # - `[:prepare, diagnostics]` — once at startup, the session's `prepare_diagnostics` snapshot. The
        #   coordinator keeps the FIRST worker's snapshot only (plugin `#prepare` is deterministic per
        #   plugin, so each worker produces the same diagnostic set; surfacing them once avoids N×
        #   duplication).
        # - `[:file, path, diagnostics]` — one per analysed file.
        # - `[:done, drained_reporters]` — once at exit, the per-worker reporter snapshots for end-of-pool
        #   merge.
        #
        # The Ruby 4.0+ Ractor model uses a single per-Ractor mailbox (no `Ractor.yield`); workers push
        # back via `Ractor.main.send`. The coordinator drains its mailbox via `Ractor.receive` until it has
        # counted exactly `pool.size` `:done` messages.
        #
        # Diagnostic order: original path order. Workers may complete files out of order; the coordinator
        # re-orders via the `results_by_path` Hash before flattening.
        #
        # Reporter merge: per-worker `RbsExtended::Reporter` and `BoundaryCrossReporter` entries are
        # replayed into the runner-side accumulators via their `record_*` APIs, which dedupe on the same
        # keys as a single-session run would. Net result: reporter state is identical to the sequential
        # path.
        def analyze_files_in_pool(files) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          # Pre-warm class-level lazy memos on the MAIN Ractor. `Environment::ClassRegistry.default` is the
          # default kwarg threaded through `Environment.new` inside each worker session; lazy-initialising
          # it from a non-main Ractor would trip `Ractor::IsolationError`. Touching it here forces the
          # (shareable) registry into the class-ivar cache before any worker reads.
          Environment::ClassRegistry.default

          # ADR-15 Phase 4b.x — pre-warm the RBS cache so workers serve every reflection query from the
          # Marshal blob on disk. Without this, the first cache MISS inside a worker falls through to
          # `RBS::EnvironmentLoader.new`, which reads a chain of non-`Ractor.shareable?` RubyGems / RBS
          # module constants and raises `Ractor::IsolationError`. Pre-warming requires a `cache_store`; the
          # run aborts to sequential mode otherwise. See ADR-15 Phase 4b.x for the full chain of failing
          # constants.
          if @cache_store.nil?
            return analyze_files_sequentially_fallback(
              files, reason: "pool mode requires a cache_store (--no-cache disables pool)"
            )
          end
          prewarm_rbs_cache_for_pool

          configuration = @configuration
          cache_root = @cache_store&.root
          blueprints = plugin_registry.blueprints
          explain = @explain
          # ADR-32 WD4 — the full project file list travels into every Ractor worker so each worker's
          # WorkerSession can invoke loaded plugins' source_rbs_synthesizers at env-build time. The list is
          # a frozen Array<String>; cheaply shareable.
          shareable_source_files = files.map { |path| path.to_s.dup.freeze }.freeze

          pool = Array.new(@workers) do
            Ractor.new(configuration, cache_root, blueprints, explain, shareable_source_files) do |configuration, cache_root, blueprints, explain, shareable_source_files| # rubocop:disable Layout/LineLength
              cache_store = cache_root ? Rigor::Cache::Store.new(root: cache_root) : nil
              session = Rigor::Analysis::WorkerSession.new(
                configuration: configuration,
                cache_store: cache_store,
                plugin_blueprints: blueprints,
                explain: explain,
                source_files: shareable_source_files
              )
              main = Ractor.main
              main.send([:prepare, session.prepare_diagnostics])

              loop do
                msg = Ractor.receive
                break if msg.nil?

                main.send([:file, msg, session.analyze(msg)])
              end

              main.send([:done, session.drain_reporters])
            end
          end

          files.each_with_index { |path, index| pool[index % pool.size].send(path) }
          pool.each { |worker| worker.send(nil) }

          prepare_diagnostics = nil
          results_by_path = {}
          done_count = 0

          while done_count < pool.size
            message = Ractor.receive
            case message.first
            when :prepare
              prepare_diagnostics ||= message.last
            when :file
              results_by_path[message[1]] = message[2]
            when :done
              merge_worker_reporters(message.last)
              done_count += 1
            end
          end

          pool.each(&:join)

          Array(prepare_diagnostics) + files.flat_map { |path| results_by_path.fetch(path, []) }
        end

        # ADR-15 Amendment (2026-05-20) — fork-based worker pool, the active backend for `workers > 0`.
        # Builds ONE {WorkerSession} on the parent, then `fork`s N children that copy-on-write inherit it.
        # Each child analyses a contiguous slice of `files` and writes a Marshal'd `{results:, reporters:}`
        # payload to a temp file; the parent `Process.wait`s every child, merges the payloads, and re-orders
        # diagnostics by original path order.
        #
        # Separate processes have separate GC heaps and `vm->ci_table` (immune to Ruby Bug #22075) and
        # copy-on-write-inherit every constant (no `Ractor.shareable?` constraint). See the ADR-15 Amendment
        # + docs/notes/20260520-ractor-pool-cruby-uaf.md.
        #
        # A child that exits non-zero (crash / unmarshalable payload) is degraded: the parent re-analyses
        # that slice in-process and prepends a `pool-degraded` warning.
        def analyze_files_in_fork_pool(files) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          Environment::ClassRegistry.default

          session = WorkerSession.new(
            configuration: @configuration,
            cache_store: @cache_store,
            plugin_blueprints: plugin_registry.blueprints,
            explain: @explain,
            synthetic_method_index: synthetic_method_index,
            project_patched_methods: project_patched_methods,
            project_scope_seed: project_scope_seed,
            source_files: files
          )
          # Force the full RBS load on the parent so children copy-on-write inherit a warm Environment
          # rather than each rebuilding it after the fork.
          session.environment.rbs_loader&.prewarm
          snapshot_fork_pool_stats(session) if @collect_stats

          worker_count = [@workers, files.size].min
          slices = files.each_slice((files.size.to_f / worker_count).ceil).to_a
          results_by_path = {}

          degraded = Dir.mktmpdir("rigor-fork-pool") do |tmpdir|
            children = slices.each_with_index.map do |slice, index|
              out_path = File.join(tmpdir, "worker-#{index}")
              { pid: fork { run_fork_worker(session, slice, out_path) },
                slice: slice, out_path: out_path }
            end
            collect_fork_results(children, results_by_path)
          end

          unless degraded.empty?
            degraded.each { |path| results_by_path[path] = session.analyze(path) }
            merge_worker_reporters(session.drain_reporters)
          end

          diagnostics = Array(session.prepare_diagnostics) +
                        files.flat_map { |path| results_by_path.fetch(path, []) }
          degraded.empty? ? diagnostics : diagnostics.unshift(fork_degraded_diagnostic(degraded.size))
        end

        # Child-process body for {#analyze_files_in_fork_pool}. Analyses the slice with the
        # copy-on-write-inherited session and writes the Marshal'd payload to `out_path`. `exit!` skips
        # `at_exit` / stdio flush — the payload is already durable on disk by then.
        def run_fork_worker(session, slice, out_path)
          results = slice.to_h { |path| [path, session.analyze(path)] }
          payload = { results: results, reporters: session.drain_reporters }
          File.binwrite(out_path, Marshal.dump(payload))
          exit!(0)
        rescue StandardError
          exit!(1)
        end

        # Snapshots `class_decl_paths` from the parent session's loader so end-of-run {RunStats} can
        # attribute the RBS class universe.
        def snapshot_fork_pool_stats(session)
          loader = session.environment.rbs_loader
          @snapshots.class_decl_paths = loader&.class_decl_paths || {}.freeze
          @snapshots.signature_paths = loader&.signature_paths || [].freeze
        end

        # Waits for every forked child, merges each successful payload into `results_by_path`, and returns
        # the file paths whose worker exited abnormally (for in-process degrade).
        def collect_fork_results(children, results_by_path)
          degraded = []
          children.each do |child|
            _, status = Process.waitpid2(child[:pid])
            payload = fork_worker_payload(status, child[:out_path])
            if payload
              results_by_path.merge!(payload.fetch(:results))
              merge_worker_reporters(payload.fetch(:reporters))
            else
              degraded.concat(child[:slice])
            end
          end
          degraded
        end

        # @return [Hash, nil] the child's `{results:, reporters:}` payload, or nil when the child exited
        #   abnormally or wrote no readable payload. `Marshal.load` is safe here: the blob was written by
        #   our own forked child to a temp file we created.
        def fork_worker_payload(status, out_path)
          return nil unless status.success? && File.exist?(out_path)

          Marshal.load(File.binread(out_path)) # rubocop:disable Security/MarshalLoad
        rescue StandardError
          nil
        end

        def fork_degraded_diagnostic(count)
          Diagnostic.new(
            path: ".rigor.yml", line: 1, column: 1,
            message: "fork pool degraded: #{count} file(s) re-analysed in-process " \
                     "after a worker exited abnormally",
            severity: :warning, rule: "pool-degraded", source_family: :builtin
          )
        end

        # ADR-15 Phase 4b.x — drives every cached RBS producer on the main Ractor so each worker can serve
        # all reflection queries from disk (Marshal-load only). Builds a single coordinator-side
        # {Environment} for this purpose; the env object is discarded immediately after the cache is warm
        # — workers build their own `Environment.for_project` inside the Ractor body, which then routes
        # through `cached_env` instead of `RBS::EnvironmentLoader.new`.
        def prewarm_rbs_cache_for_pool
          warm_env = Environment.for_project(
            libraries: @configuration.libraries,
            signature_paths: @configuration.signature_paths,
            cache_store: @cache_store,
            bundler_bundle_path: @configuration.bundler_bundle_path,
            bundler_auto_detect: @configuration.bundler_auto_detect,
            bundler_lockfile: @configuration.bundler_lockfile,
            rbs_collection_lockfile: @configuration.rbs_collection_lockfile,
            rbs_collection_auto_detect: @configuration.rbs_collection_auto_detect
          )
          warm_env.rbs_loader&.prewarm
        end

        # ADR-15 Phase 4b.x — pool-mode safety net. When pool mode is configured but a precondition fails
        # (currently: `--no-cache` would force workers through `EnvironmentLoader.new`), degrade to
        # sequential analysis with a `:warning` `pool-degraded` diagnostic at run start. The actual
        # per-file analysis runs on the coordinator, identical to the default sequential path.
        def analyze_files_sequentially_fallback(files, reason:)
          environment = build_runner_environment
          diagnostics = files.flat_map { |path| @analyze_file.call(path, environment) }
          loader = environment.rbs_loader
          @snapshots.class_decl_paths = loader&.class_decl_paths || {}.freeze
          @snapshots.signature_paths = loader&.signature_paths || [].freeze
          diagnostics.unshift(
            Diagnostic.new(
              path: ".rigor.yml", line: 1, column: 1,
              message: "pool mode degraded to sequential: #{reason}",
              severity: :warning, rule: "pool-degraded", source_family: :builtin
            )
          )
        end

        def merge_worker_reporters(drained)
          rbs = drained.fetch(:rbs_extended)
          rbs.fetch(:unresolved_payloads).each do |entry|
            @rbs_extended_reporter.record_unresolved(
              payload: entry.payload, source_location: entry.source_location
            )
          end
          rbs.fetch(:lossy_projections).each do |entry|
            @rbs_extended_reporter.record_lossy_projection(
              head: entry.head, source_location: entry.source_location
            )
          end
          drained.fetch(:boundary_cross).each do |entry|
            @boundary_cross_reporter.record(
              class_name: entry.class_name,
              method_name: entry.method_name,
              gem_name: entry.gem_name,
              rbs_display: entry.rbs_display
            )
          end
          # ADR-32 WD6 — merge per-worker synthesizer failures back into the coordinator's reporter. Fetched
          # with a default empty array so older drains (pre-slice-2) remain compatible.
          Array(drained[:source_rbs_synthesis]).each do |entry|
            @source_rbs_synthesis_reporter.record(
              plugin_id: entry.plugin_id, path: entry.path, message: entry.message
            )
          end
        end

        private

        # True when the project declares its own `signature_paths:` (the only place the
        # qualified-name-without-namespace mistake lives).
        def project_signature_paths?
          paths = @configuration.signature_paths
          !(paths.nil? || paths.empty?)
        end

        def plugin_registry
          @plugin_registry_reader.call
        end

        def dependency_source_index
          @dependency_source_index_reader.call
        end

        def synthetic_method_index
          @synthetic_method_index_reader.call
        end

        def project_patched_methods
          @project_patched_methods_reader.call
        end

        def project_scope_seed
          @project_scope_seed_reader.call
        end
      end
    end
  end
end
