# frozen_string_literal: true

require "tempfile"

require_relative "uri"
require_relative "../analysis/runner"
require_relative "../analysis/buffer_binding"

module Rigor
  module LanguageServer
    # Converts buffer state into `textDocument/publishDiagnostics`
    # notifications. Owns the Rigor `Analysis::Runner` orchestration
    # for the per-buffer single-file scope path that editor mode v1
    # already supports — every `publish_for(uri)` call materialises
    # a `BufferBinding` from the BufferTable entry, runs the Runner,
    # and pushes the resulting LSP `Diagnostic[]` through the writer.
    #
    # Slice 4 is synchronous: each call blocks until analysis
    # completes (typically 100-300ms warm). Debouncing (200ms
    # quiet-time before publish) and Ractor-pool dispatch are
    # queued for slice 4b / slice 8 respectively.
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

      # @param debouncer [Rigor::LanguageServer::Debouncer, nil]
      #   when present, `publish_for` schedules its work through
      #   the debouncer (cancels prior pending task for the same
      #   URI, fires after `debounce_seconds` quiet-time). Nil
      #   keeps the slice 4-7 synchronous behaviour — primarily
      #   useful for specs.
      # @param debounce_seconds [Numeric] quiet-time before the
      #   debounced publish fires. 0 with a debouncer means
      #   "schedule on next-tick" (still async); without a
      #   debouncer the value is unused.
      def initialize(writer:, buffer_table:, project_context:,
                     debouncer: nil, debounce_seconds: 0.2)
        @writer = writer
        @buffer_table = buffer_table
        @project_context = project_context
        @debouncer = debouncer
        @debounce_seconds = debounce_seconds
      end

      # Run analysis for the buffer at `uri` (looked up in the
      # BufferTable) and push a `textDocument/publishDiagnostics`
      # notification. No-op when the URI isn't a `file://` form or
      # the buffer isn't currently open. When a Debouncer is wired,
      # the analysis is scheduled async per the configured
      # `debounce_seconds`; otherwise it runs inline.
      def publish_for(uri)
        path = Uri.to_path(uri)
        return if path.nil?

        if @debouncer
          @debouncer.schedule(uri, delay: @debounce_seconds) { run_and_notify(uri, path) }
        else
          run_and_notify(uri, path)
        end
      end

      # Publishes an EMPTY diagnostic array for `uri`. The LSP-spec
      # idiom for "clear inline markers" — called from `didClose`
      # so clients drop stale highlights when the user closes a
      # buffer.
      def publish_empty(uri)
        notify(uri, [])
      end

      # Cancels every in-flight debounced task. Called from
      # `Server#handle_shutdown` so pending publishes don't fire
      # against a closed STDOUT.
      def cancel_pending
        @debouncer&.cancel_all
      end

      private

      def run_and_notify(uri, path)
        entry = @buffer_table[uri]
        # The buffer may have been closed during the debounce
        # window — drop the publish; the empty notification from
        # didClose already cleared the markers.
        return if entry.nil?

        diagnostics = run_analysis(path: path, bytes: entry.bytes)
        notify(uri, diagnostics)
      end

      # Runs `Analysis::Runner` with a `BufferBinding` so the buffer
      # bytes (instead of the on-disk file) drive the parse. Returns
      # the LSP-shaped Diagnostic Array, ready to serialize into the
      # notification's `params.diagnostics` field.
      def run_analysis(path:, bytes:)
        with_tempfile(bytes) do |tmp|
          binding = Analysis::BufferBinding.new(logical_path: path, physical_path: tmp.path)
          runner = Analysis::Runner.new(
            configuration: @project_context.configuration,
            cache_store: @project_context.cache_store,
            collect_stats: false,
            buffer: binding
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

      # @return [Hash, nil] the LSP `Diagnostic` Hash, or nil to
      #   skip diagnostics outside the buffer's own path (e.g.
      #   `.rigor.yml`-anchored info diagnostics get filtered —
      #   they belong to the project, not the buffer).
      def to_lsp_diagnostic(diagnostic, buffer_path)
        return nil if diagnostic.path != buffer_path

        # Rigor uses 1-based line + 1-based byte column; LSP uses
        # 0-based line + 0-based UTF-16 code unit. UTF-16 conversion
        # is queued (design doc § "Open questions"); v1 emits byte
        # columns which are correct for ASCII source.
        line = (diagnostic.line - 1).clamp(0, Float::INFINITY).to_i
        character = (diagnostic.column - 1).clamp(0, Float::INFINITY).to_i

        {
          range: {
            start: { line: line, character: character },
            end:   { line: line, character: character }
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
