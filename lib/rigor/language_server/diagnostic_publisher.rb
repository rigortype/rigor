# frozen_string_literal: true

require "tempfile"

require_relative "uri"
require_relative "publish_batcher"
require_relative "../analysis/runner"
require_relative "../analysis/buffer_binding"

module Rigor
  module LanguageServer
    # Converts buffer state into `textDocument/publishDiagnostics` notifications. Owns the Rigor
    # `Analysis::Runner` orchestration for the per-buffer single-file scope path that editor mode v1 already
    # supports — every `publish_for(uri)` call materialises a `BufferBinding` from the BufferTable entry, runs
    # the Runner, and pushes the resulting LSP `Diagnostic[]` through the writer.
    #
    # Debouncing is wired via an optional `Debouncer` injected at construction (delay defaults to 200ms
    # quiet-time); without a debouncer each call blocks synchronously (primarily for specs). When several
    # buffers' debounce timers elapse around the same moment, the `PublishBatcher` coalesces them into one
    # `#publish_many` round dispatched across the fork-based worker pool (issue #142) instead of N
    # independent, GVL-serialized `Runner` calls.
    class DiagnosticPublisher
      # Maps Rigor severity symbols to LSP DiagnosticSeverity
      # integers per spec § "Diagnostic":
      #   1 = Error, 2 = Warning, 3 = Information, 4 = Hint.
      SEVERITY_MAP = {
        error: 1,
        warning: 2,
        info: 3,
        hint: 4
      }.freeze

      #   when present, `publish_for` schedules its work through
      #   the debouncer (cancels prior pending task for the same
      #   URI, fires after `debounce_seconds` quiet-time). Nil
      #   keeps the slice 4-7 synchronous behaviour — primarily
      #   useful for specs.
      # @rbs debounce_seconds: Numeric --
      #   Quiet-time before the debounced publish fires. 0 with a debouncer means "schedule on next-tick" (still
      #   async); without a debouncer the value is unused. The single Debouncer key every save round shares (#246).
      #   Per-URI keys would let two saves start two concurrent rounds; one key means a burst collapses into the last
      #   one.
      PROJECT_ROUND_KEY = :__rigor_project_round__

      def initialize(writer:, buffer_table:, project_context:,
                     debouncer: nil, debounce_seconds: 0.2)
        @writer = writer
        @buffer_table = buffer_table
        @project_context = project_context
        @debouncer = debouncer
        @debounce_seconds = debounce_seconds
        @round_lock = Mutex.new
        @round_running = false
        @round_pending = false
        # Issue #142 — coalesces buffers whose OWN debounce timers elapse close together into one
        # `#publish_many` round instead of N independent GVL-serialized `Runner` calls. Separate from
        # `@round_lock` above, which single-flights the whole-project SAVE round; this single-flights the
        # per-buffer DIDCHANGE batch instead. See `PublishBatcher` for the coalescing mechanics.
        @batcher = PublishBatcher.new(
          on_batch: ->(uris) { publish_many(uris) },
          on_error: ->(e) { warn "DiagnosticPublisher batch round: #{e.class}: #{e.message}" }
        )
      end

      # Run analysis for the buffer at `uri` (looked up in the BufferTable) and push a
      # `textDocument/publishDiagnostics` notification. No-op when the URI isn't a `file://` form or the
      # buffer isn't currently open. When a Debouncer is wired, the analysis is scheduled async per the
      # configured `debounce_seconds` and joins the batch coalescing layer (`PublishBatcher`) once its own
      # quiet-time elapses; otherwise it runs inline (primarily for specs).
      def publish_for(uri)
        path = Uri.to_path(uri)
        return if path.nil?

        if @debouncer
          @debouncer.schedule(uri, delay: @debounce_seconds) { @batcher.enqueue(uri) }
        else
          run_and_notify(uri, path)
        end
      end

      # Issue #142 — publishes N dirty buffers' diagnostics through ONE dispatch across the fork-based
      # worker pool (`Analysis::Runner::BufferPoolDispatcher`) instead of N independent, GVL-serialized
      # `Runner` calls. Each URI's OWN `BufferBinding` (its logical path bound to its OWN editor tempfile)
      # travels with it, so a worker analyses that buffer's in-flight bytes — never the file as it sits on
      # disk — even when several buffers are dispatched in the same round.
      #
      # Degrades to `#run_and_notify`'s existing single-buffer path when only one URI is eligible after
      # filtering (a buffer closed mid-debounce-window is dropped; a desynchronised one publishes empty
      # immediately) — a lone edit takes exactly the path it takes today. The dispatcher itself degrades to
      # sequential in-process execution for any other precondition (see
      # `BufferPoolDispatcher#dispatchable?`), so a pool that cannot start never fails a publish, only slows
      # it back down to today's wall time.
      def publish_many(uris)
        eligible = uris.uniq.filter_map { |uri| eligible_job(uri) }
        return if eligible.empty?
        return run_and_notify(eligible.first.fetch(:uri), eligible.first.fetch(:path)) if eligible.size == 1

        publish_batch(eligible)
      end

      # Runs one whole-project save round and publishes to the publish set (#246). Called from `didSave`.
      #
      # Analysis scope is the whole project; the PUBLISH SET is the open buffers that are not dirty, plus the
      # buffer that was just saved. A dirty buffer is excluded because only its own `didChange` analysis has
      # seen its bytes — publishing this round's on-disk answer for it would replace correct markers with
      # markers for a file the user has already changed.
      #
      # Scheduled through the same Debouncer the per-buffer path uses, under one project-wide key, so the
      # dispatcher never blocks on it.
      def publish_project(saved_uri)
        if @debouncer
          @debouncer.schedule(PROJECT_ROUND_KEY, delay: 0) { run_project_round(saved_uri) }
        else
          run_project_round(saved_uri)
        end
      end

      # Publishes an EMPTY diagnostic array for `uri`. The LSP-spec idiom for "clear inline markers" — called
      # from `didClose` so clients drop stale highlights when the user closes a buffer.
      def publish_empty(uri)
        notify(uri, [])
      end

      # Cancels every in-flight debounced task. Called from `Server#handle_shutdown` so pending publishes
      # don't fire against a closed STDOUT.
      def cancel_pending
        @debouncer&.cancel_all
      end

      private

      # Single-flight. The Debouncer only cancels a task that has not started, so without this two rounds
      # could run concurrently over one session's mutable state. A save that arrives mid-round sets the
      # pending flag instead of starting a second round, and the running one repeats once when it finishes —
      # so a burst of saves costs at most one extra round, and the last save is always accounted for.
      def run_project_round(saved_uri)
        return unless claim_round

        loop do
          execute_project_round(saved_uri)
          break unless consume_pending
        end
      end

      # True when this call owns the round. A save arriving while one is in flight records itself as pending
      # instead — the running round will pick it up.
      def claim_round
        @round_lock.synchronize do
          if @round_running
            @round_pending = true
            next false
          end

          @round_running = true
          true
        end
      end

      # True when a save arrived mid-round and the loop should run once more. Releases ownership otherwise.
      # `next`, not `break`: inside `Mutex#synchronize`'s block, `break` returns from the SYNCHRONIZE call, so
      # a `break` written here would leave the caller's `loop` spinning forever — which is exactly what it did
      # before this was split out.
      def consume_pending
        @round_lock.synchronize do
          next(@round_running = false) unless @round_pending

          @round_pending = false
          true
        end
      end

      # One round: analyse the project as it now stands on disk, then publish each target URI's slice.
      # The generation captured before the analysis is re-read after it — a `didChangeWatchedFiles` or a
      # configuration change during a long round invalidates the world these diagnostics describe, and
      # publishing them would put an answer about a superseded project on the user's screen.
      def execute_project_round(saved_uri)
        generation = @project_context.generation
        diagnostics = @project_context.project_diagnostics
        return if generation != @project_context.generation

        by_path = diagnostics.group_by(&:path)
        publish_set(saved_uri).each do |uri|
          path = Uri.to_path(uri)
          next if path.nil?

          notify(uri, (by_path[path] || []).filter_map { |diagnostic| to_lsp_diagnostic(diagnostic, path) })
        end
      end

      # The URIs this round may speak for: every open buffer whose bytes are the ones on disk. The just-saved
      # URI qualifies by definition (the client wrote it), and is named explicitly so a client that sends
      # `didSave` without a preceding applied `didChange` still refreshes it.
      def publish_set(saved_uri)
        ([saved_uri] + @buffer_table.uris).uniq.select do |uri|
          @buffer_table.open?(uri) && !@buffer_table.dirty?(uri) && !@buffer_table.desynchronized?(uri)
        end
      end

      def run_and_notify(uri, path)
        entry = @buffer_table[uri]
        # The buffer may have been closed during the debounce window — drop the publish; the empty
        # notification from didClose already cleared the markers.
        return if entry.nil?
        # An incremental change the table could not apply: the held text no longer matches the editor's, so
        # every span we could compute from it would be misplaced. Clear the markers and stay silent until a
        # full-text change or a re-open re-establishes the buffer.
        return notify(uri, []) if @buffer_table.desynchronized?(uri)

        diagnostics = run_analysis(path: path, bytes: entry.bytes)
        notify(uri, diagnostics)
      end

      # @rbs return: Hash[untyped, untyped]? --
      #   `{ uri:, path:, bytes: }` when `uri` is eligible for the batch, or nil to exclude it. Mirrors
      #   `#run_and_notify`'s own guards: a buffer closed during the debounce window is dropped silently (its didClose
      #   empty publish already cleared the markers); a desynchronised buffer publishes an EMPTY set immediately (same
      #   as the single-buffer path) rather than joining the batch.
      def eligible_job(uri)
        entry = @buffer_table[uri]
        return nil if entry.nil?

        path = Uri.to_path(uri)
        return nil if path.nil?

        if @buffer_table.desynchronized?(uri)
          notify(uri, [])
          return nil
        end

        { uri: uri, path: path, bytes: entry.bytes }
      end

      # Materialises one tempfile + `BufferBinding` per job, dispatches all of them through
      # `BufferPoolDispatcher#analyze` in ONE call, and publishes each job's own slice. `dispatcher.analyze`
      # returns diagnostics IN INPUT ORDER, so `jobs`/`bindings`/the result array stay index-aligned — the
      # parent absorbs worker results in this stable order, so two runs of the same dirty set publish
      # byte-identical results.
      def publish_batch(jobs)
        with_tempfiles(jobs) do |bound_jobs|
          bindings = bound_jobs.map { |job| job.fetch(:binding) }
          dispatcher = Analysis::Runner::BufferPoolDispatcher.new(
            configuration: @project_context.configuration,
            cache_store: @project_context.cache_store,
            environment: @project_context.environment,
            prebuilt: @project_context.project_scan,
            workers: worker_count
          )
          diagnostics_per_binding = dispatcher.analyze(bindings)
          bound_jobs.each_with_index do |job, index|
            diagnostics = diagnostics_per_binding.fetch(index, []).filter_map do |diagnostic|
              to_lsp_diagnostic(diagnostic, job.fetch(:path))
            end
            notify(job.fetch(:uri), diagnostics)
          end
        end
      end

      # Worker-pool size, mirroring `rigor check`'s own precedence minus the CLI flag the LSP does not have:
      # env `RIGOR_RACTOR_WORKERS` (if set and non-empty) wins, else `.rigor.yml` `parallel.workers:` (0 —
      # sequential — by default). See `docs/design/20260517-language-server.md` § "Concurrency".
      def worker_count
        env_value = ENV.fetch("RIGOR_RACTOR_WORKERS", nil)
        return [Integer(env_value), 0].max if env_value && !env_value.empty?

        @project_context.configuration.parallel_workers
      end

      # Runs `Analysis::Runner` with a `BufferBinding` so the buffer bytes (instead of the on-disk file) drive
      # the parse. The `Rigor::Analysis::ProjectScan` cached on the ProjectContext is passed through
      # `prebuilt:` so plugin `#prepare`, the dependency-source walker, and the synthetic-method /
      # project-patched scanners do not re-run per publish. The snapshot rebuilds only when
      # `ProjectContext#invalidate!` fires (watched-file or configuration change). Returns the LSP-shaped
      # Diagnostic Array, ready to serialize into the notification's `params.diagnostics` field.
      def run_analysis(path:, bytes:)
        with_tempfile(bytes) do |tmp|
          binding = Analysis::BufferBinding.new(logical_path: path, physical_path: tmp.path)
          runner = Analysis::Runner.new(
            configuration: @project_context.configuration,
            cache_store: @project_context.cache_store,
            collect_stats: false,
            buffer: binding,
            prebuilt: @project_context.project_scan,
            environment: @project_context.environment
          )
          result = runner.run([path])
          result.diagnostics.filter_map { |diagnostic| to_lsp_diagnostic(diagnostic, path) }
        end
      end

      def with_tempfile(bytes)
        tmp = Tempfile.new(["rigor-lsp-buffer-", ".rb"])
        tmp.write(bytes)
        tmp.flush
        yield tmp
      ensure
        tmp&.close
        tmp&.unlink
      end

      # Plural form of `#with_tempfile` for `#publish_batch` — writes one tempfile per job up front, yields
      # each job Hash augmented with its own `binding:` (a `BufferBinding` pairing the job's logical path
      # with ITS OWN physical tempfile), and unlinks every tempfile afterward regardless of how the block
      # exits.
      def with_tempfiles(jobs)
        tempfiles = []
        bound_jobs = jobs.map do |job|
          tmp = Tempfile.new(["rigor-lsp-buffer-", ".rb"])
          tmp.write(job.fetch(:bytes))
          tmp.flush
          tempfiles << tmp
          binding = Analysis::BufferBinding.new(logical_path: job.fetch(:path), physical_path: tmp.path)
          job.merge(binding: binding)
        end
        yield bound_jobs
      ensure
        tempfiles.each do |tmp|
          tmp.close
          tmp.unlink
        end
      end

      # @rbs return: Hash[untyped, untyped]? --
      #   The LSP `Diagnostic` Hash, or nil to skip diagnostics outside the buffer's own path (e.g.
      #   `.rigor.yml`-anchored info diagnostics get filtered — they belong to the project, not the buffer).
      def to_lsp_diagnostic(diagnostic, buffer_path)
        return nil if diagnostic.path != buffer_path

        # Rigor uses 1-based line + 1-based byte column; LSP uses 0-based line + 0-based UTF-16 code unit.
        # UTF-16 conversion is queued (design doc § "Open questions"); v1 emits byte columns which are
        # correct for ASCII source.
        line = (diagnostic.line - 1).clamp(0, Float::INFINITY).to_i
        character = (diagnostic.column - 1).clamp(0, Float::INFINITY).to_i

        {
          range: {
            start: { line: line, character: character },
            end: { line: line, character: character }
          },
          severity: SEVERITY_MAP.fetch(diagnostic.severity, 3),
          code: diagnostic.rule,
          source: "rigor",
          message: diagnostic.message
        }.compact
      end

      def notify(uri, diagnostics)
        @writer.write(
          method: "textDocument/publishDiagnostics",
          params: { uri: uri, diagnostics: diagnostics }
        )
      end
    end
  end
end
