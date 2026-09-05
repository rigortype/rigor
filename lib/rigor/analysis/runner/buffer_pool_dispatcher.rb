# frozen_string_literal: true

require "tmpdir"

require_relative "../../environment"
require_relative "../../runtime/jit"

module Rigor
  module Analysis
    class Runner
      # Issue #142 — LSP multi-buffer dispatch. Runs one independent single-buffer `Runner#run` call per
      # dirty buffer due to publish, distributed across a fork-based worker pool, reusing the SAME warm
      # `Environment` + `ProjectScan` a sequential per-buffer publish already shares via
      # `Rigor::LanguageServer::ProjectContext` — so a batch pays zero extra RBS-env-build or plugin
      # `#prepare` cost over today's sequential path; only the per-file inference itself moves off the main
      # process.
      #
      # Deliberately a SIBLING of {PoolCoordinator}, not a method on it. PoolCoordinator's unit of dispatch is
      # "one shared {WorkerSession}, a project's files split across it" — that shape needs cross-worker
      # reporter merge because ONE session's reporters accumulate per file. This dispatcher's unit of
      # dispatch is "one COMPLETE `Runner#run` call per job", and each job is already fully self-contained
      # (its own fresh reporters, its own severity-profile stamp, its own diagnostic aggregation) by
      # construction — there is nothing to merge back except the diagnostics array itself. Forcing this
      # through PoolCoordinator's constructor (which exists to wire ONE Runner's own mutable ivar surface
      # through reader procs) would buy nothing.
      #
      # Sequential-equivalence contract: each job's diagnostics are EXACTLY what
      #   `Runner.new(buffer:, prebuilt:, environment:, configuration:, cache_store:, collect_stats: false)
      #     .run([binding.logical_path]).diagnostics`
      # returns today — the same call `LanguageServer::DiagnosticPublisher#run_analysis` already makes
      # inline for a single buffer. This dispatcher only changes WHERE that call executes (a forked child vs.
      # the parent), never what it computes — so two runs of the same dirty set publish byte-identical
      # results, and a run that cannot use the pool falls back to running every job in-process rather than
      # failing.
      #
      # Buffer-substitution correctness (the highest-risk part of #142): EVERY job carries its OWN
      # `BufferBinding` — a fork worker never shares one session-wide binding the way `PoolCoordinator`'s
      # editor-mode single-buffer contract does. A binding not threaded all the way into the child's `Runner`
      # would make that worker parse the file as it sits on disk and publish plausible-looking, stale
      # diagnostics; every code path below carries `binding` explicitly rather than defaulting to nil.
      class BufferPoolDispatcher
        # Below this many bindings, `#analyze` takes the sequential in-process path even when the pool is
        # otherwise available (workers positive, `fork` available, `cache_store` present). Reviewed and
        # required for #142 to merge: a throwaway measurement against this repo's own `lib/rigor` (46-353
        # files, ~1-2ms/file analysis once `Environment` + `ProjectScan` are warm — the exact steady state
        # this dispatcher runs in) showed the FORK + `Marshal` + `Process.waitpid2` overhead exceeding the
        # parallelism win below roughly N=12, and only paying off cleanly from N=16 up (interleaved,
        # median-of-5, `workers: 8`):
        #
        #   N=8   sequential=0.018s  pooled=0.027s  speedup=0.66x  (pool SLOWER)
        #   N=12  sequential=0.021s  pooled=0.021s  speedup=1.00x  (break-even, noisy)
        #   N=16  sequential=0.028s  pooled=0.025s  speedup=1.09x
        #   N=24  sequential=0.038s  pooled=0.026s  speedup=1.47x
        #   N=32  sequential=0.050s  pooled=0.029s  speedup=1.73x
        #
        # 16 sits with margin ABOVE the noisy break-even (12), not at it — full method + table in #142's PR
        # description.
        #
        # This is deliberately a FIXED default, not a per-project auto-calibrated one. Per-file analysis cost
        # varies enormously by project — this repo's own `lib/rigor` is ~1-2ms/file warm; a large Rails
        # controller or model file can cost far more, which would make pooling profitable at a MUCH smaller N
        # there. A cost-aware gate — deciding from the publisher's own observed per-publish duration instead
        # of a bare file count — would adapt automatically, but needs plumbing that does not exist today (the
        # publisher tracks no timing history) and is disproportionate to what closing #142 calls for; it is a
        # reasonable follow-up, not attempted here. A project whose crossover sits at a different N overrides
        # via `RIGOR_LSP_POOL_MIN_BATCH` (mirrors `RIGOR_RACTOR_WORKERS`'s override shape).
        DEFAULT_MIN_BATCH_SIZE = 16

        # @return [Integer] `RIGOR_LSP_POOL_MIN_BATCH` when set to a non-empty value, else
        #   {DEFAULT_MIN_BATCH_SIZE}.
        def self.resolve_min_batch_size
          env_value = ENV.fetch("RIGOR_LSP_POOL_MIN_BATCH", nil)
          return DEFAULT_MIN_BATCH_SIZE if env_value.nil? || env_value.empty?

          Integer(env_value)
        end

        # @param environment [Rigor::Environment] the warm, shared per-session Environment
        #   (`ProjectContext#environment`) every job's Runner reuses instead of rebuilding.
        # @param prebuilt [Rigor::Analysis::ProjectScan] the warm, shared pre-pass snapshot
        #   (`ProjectContext#project_scan`) every job's Runner adopts instead of re-scanning.
        # @param workers [Integer] pool size. `#analyze` degrades to sequential in-process execution — one
        #   job at a time, no `fork` — when fewer than 2 bindings are submitted, fewer than `min_batch_size`
        #   bindings are submitted, `workers` is not positive, `fork` is unavailable on this platform, or
        #   `cache_store` is nil. The middle two are the fork-pool-is-not-worth-it-yet gate documented on
        #   {DEFAULT_MIN_BATCH_SIZE}; the last two mirror
        #   {PoolCoordinator#analyze_files_in_pool}'s own fork-pool preconditions.
        # @param min_batch_size [Integer] see {DEFAULT_MIN_BATCH_SIZE}. Exposed as a constructor param
        #   (rather than read from the env internally) purely for spec control; production callers get the
        #   resolved default.
        def initialize(configuration:, cache_store:, environment:, prebuilt:, workers:,
                       min_batch_size: self.class.resolve_min_batch_size)
          @configuration = configuration
          @cache_store = cache_store
          @environment = environment
          @prebuilt = prebuilt
          @workers = workers
          @min_batch_size = min_batch_size
        end

        # Runs one `Runner#run([binding.logical_path])` per binding and returns `Array<Array<Diagnostic>>` —
        # one diagnostics array per input binding, IN INPUT ORDER. The parent always absorbs worker results
        # re-indexed by POSITION, never keyed on path, so two bindings that happen to share a logical path
        # (should not occur — one dirty buffer per URI — but is not assumed away) can never collide or
        # silently overwrite one another.
        def analyze(bindings)
          return [] if bindings.empty?
          return bindings.map { |binding| run_one(binding) } unless dispatchable?(bindings)

          dispatch_in_fork_pool(bindings)
        end

        private

        def dispatchable?(bindings)
          bindings.size > 1 && bindings.size >= @min_batch_size &&
            @workers.is_a?(Integer) && @workers.positive? &&
            Process.respond_to?(:fork) && !@cache_store.nil?
        end

        # One job, run exactly as `DiagnosticPublisher#run_analysis` runs it today — the equivalence contract
        # this whole class exists to preserve.
        def run_one(binding)
          Runner.new(
            configuration: @configuration, cache_store: @cache_store, collect_stats: false,
            buffer: binding, prebuilt: @prebuilt, environment: @environment
          ).run([binding.logical_path]).diagnostics
        end

        def dispatch_in_fork_pool(bindings)
          # Pre-warm the memoized class registry on the parent so every forked child inherits it via
          # copy-on-write instead of each re-computing it — mirrors `PoolCoordinator`'s own pool entry points.
          Environment::ClassRegistry.default

          worker_count = [@workers, bindings.size].min
          indexed = bindings.each_with_index.to_a
          slices = indexed.each_slice((indexed.size.to_f / worker_count).ceil).to_a
          results_by_index = {}

          degraded = Dir.mktmpdir("rigor-lsp-buffer-pool") do |tmpdir|
            children = slices.each_with_index.map do |slice, worker_index|
              out_path = File.join(tmpdir, "worker-#{worker_index}")
              { pid: fork { run_fork_worker(slice, out_path) }, slice: slice, out_path: out_path }
            end
            collect_fork_results(children, results_by_index)
          end

          degraded.each do |slice|
            slice.each { |binding, index| results_by_index[index] = run_one(binding) }
          end

          indexed.map { |_binding, index| results_by_index.fetch(index, []) }
        end

        # Child-process body. `fork` copies only the calling thread, so any deferred-YJIT deadline the parent
        # armed does not survive into this child — re-arm it first, mirroring
        # `PoolCoordinator#run_fork_worker`. In practice the LSP process enables YJIT immediately at boot
        # (`Runtime::Jit.enable_now` in `LspCommand`, never the deferred-deadline path), so this is a cheap
        # no-op today — kept for parity with every other fork site and in case that boot-time choice changes.
        # `exit!` skips `at_exit` / stdio flush; the payload is already durable on disk by then.
        def run_fork_worker(slice, out_path)
          Runtime::Jit.rearm_after_fork
          results = slice.to_h { |binding, index| [index, run_one(binding)] }
          File.binwrite(out_path, Marshal.dump(results))
          exit!(0)
        rescue StandardError
          exit!(1)
        end

        # Waits for every forked child, merges each successful payload into `results_by_index`, and returns
        # the (binding, index) slices whose worker exited abnormally, for in-process degrade.
        def collect_fork_results(children, results_by_index)
          degraded = []
          children.each do |child|
            _, status = Process.waitpid2(child[:pid])
            payload = fork_worker_payload(status, child[:out_path])
            if payload
              results_by_index.merge!(payload)
            else
              degraded << child[:slice]
            end
          end
          degraded
        end

        # @return [Hash, nil] the child's `{index => diagnostics}` payload, or nil when the child exited
        #   abnormally or wrote no readable payload. `Marshal.load` is safe here: the blob was written by our
        #   own forked child to a temp file we created.
        def fork_worker_payload(status, out_path)
          return nil unless status.success? && File.exist?(out_path)

          Marshal.load(File.binread(out_path)) # rubocop:disable Security/MarshalLoad
        rescue StandardError
          nil
        end
      end
    end
  end
end
