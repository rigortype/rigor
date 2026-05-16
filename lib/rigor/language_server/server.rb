# frozen_string_literal: true

require_relative "../version"
require_relative "buffer_table"

module Rigor
  module LanguageServer
    # LSP server lifecycle state machine + JSON-RPC method dispatcher.
    #
    # Slice 1 (this commit) ships:
    # - State machine: `:uninitialized` → `:initialized` → `:shutdown`
    #   → `:exited`.
    # - Three lifecycle handlers: `initialize`, `shutdown`, `exit`.
    # - {#dispatch} which routes (method, params) to the matching
    #   handler and returns the response payload (or `nil` for
    #   notifications). Out-of-state requests return the
    #   spec-defined `InvalidRequest` (-32002) / `MethodNotFound`
    #   (-32601) error shapes.
    #
    # Slice 2 wraps this dispatcher in a stdio JSON-RPC reader /
    # writer so the CLI subcommand can serve real LSP clients.
    # Slice 3+ adds document sync; slice 4+ adds publishDiagnostics;
    # slice 5-8 add the rest of the v1 capability surface.
    class Server
      # JSON-RPC error codes per LSP spec § "Response Message".
      ERROR_PARSE_ERROR      = -32_700
      ERROR_INVALID_REQUEST  = -32_600
      ERROR_METHOD_NOT_FOUND = -32_601
      ERROR_INVALID_PARAMS   = -32_602
      ERROR_INTERNAL_ERROR   = -32_603
      # LSP-specific reserved codes.
      ERROR_SERVER_NOT_INITIALIZED = -32_002
      ERROR_INVALID_REQUEST_AFTER_SHUTDOWN = -32_600

      # Methods callable BEFORE `initialize`. Per LSP spec § 3 only
      # `initialize` and `exit` are allowed pre-initialization; every
      # other request returns `ServerNotInitialized`. We also accept
      # `shutdown` so a sequence like `initialize → shutdown → exit`
      # (the conformance harness) round-trips even when the client
      # skips real work.
      PRE_INITIALIZE_METHODS = %w[initialize shutdown exit].freeze

      attr_reader :state, :exit_code, :buffer_table, :publisher,
                  :hover_provider, :document_symbol_provider, :project_context

      # @param project_context [Rigor::LanguageServer::ProjectContext, nil]
      #   the per-session cache of `Environment` + `Cache::Store`
      #   the providers read on every request. When present,
      #   `workspace/didChangeWatchedFiles` and
      #   `workspace/didChangeConfiguration` invalidate the cache;
      #   nil means "no project context", which is the slice 1-6
      #   behaviour (each request rebuilds env from scratch).
      def initialize(buffer_table: BufferTable.new, publisher: nil,
                     hover_provider: nil, document_symbol_provider: nil,
                     project_context: nil)
        @state = :uninitialized
        @exit_code = nil
        @buffer_table = buffer_table
        @publisher = publisher
        @hover_provider = hover_provider
        @document_symbol_provider = document_symbol_provider
        @project_context = project_context
      end

      # @return [Boolean] true once the client has called `exit` and
      #   the server has set its terminal exit code. The CLI loop
      #   reads this between dispatches to know when to stop.
      def exited?
        @state == :exited
      end

      # Routes one LSP method call.
      #
      # @param method [String] the LSP method name (e.g. "initialize").
      # @param params [Hash, nil] the LSP `params` payload (Hash for
      #   request / notification methods; nil for the empty case).
      # @return [Hash, nil] one of:
      #   - the response result Hash for request methods,
      #   - nil for notification methods,
      #   - { error: { code:, message: } } for state / shape errors.
      def dispatch(method, params = nil)
        return state_violation_response(method) unless method_allowed_in_state?(method)

        case method
        when "initialize"             then handle_initialize(params)
        when "initialized"            then handle_initialized
        when "shutdown"               then handle_shutdown
        when "exit"                   then handle_exit
        when "textDocument/didOpen"   then handle_did_open(params)
        when "textDocument/didChange" then handle_did_change(params)
        when "textDocument/didClose"  then handle_did_close(params)
        when "textDocument/hover"               then handle_hover(params)
        when "textDocument/documentSymbol"      then handle_document_symbol(params)
        when "workspace/didChangeWatchedFiles"  then handle_did_change_watched_files(params)
        when "workspace/didChangeConfiguration" then handle_did_change_configuration(params)
        else
          method_not_found(method)
        end
      end

      private

      def method_allowed_in_state?(method)
        case @state
        when :uninitialized then PRE_INITIALIZE_METHODS.include?(method)
        when :initialized   then method != "initialize"
        when :shutdown      then method == "exit"
        when :exited        then false
        end
      end

      def state_violation_response(method)
        case @state
        when :uninitialized
          rpc_error(
            ERROR_SERVER_NOT_INITIALIZED,
            "method #{method.inspect} requires `initialize` first"
          )
        when :initialized
          rpc_error(
            ERROR_INVALID_REQUEST,
            "method #{method.inspect} is not valid after `initialize` has succeeded"
          )
        when :shutdown
          rpc_error(
            ERROR_INVALID_REQUEST_AFTER_SHUTDOWN,
            "method #{method.inspect} is not valid after `shutdown`; only `exit` is accepted"
          )
        when :exited
          rpc_error(ERROR_INVALID_REQUEST, "server has exited")
        end
      end

      # Per LSP spec § "Server lifecycle / initialize": the server
      # responds with its capabilities. Each later slice extends
      # `advertised_capabilities` with the handler it wires;
      # clients asking for unadvertised methods get `MethodNotFound`.
      def handle_initialize(_params)
        @state = :initialized
        {
          capabilities: advertised_capabilities,
          serverInfo: {
            name: "rigor-lsp",
            version: Rigor::VERSION
          }
        }
      end

      # `TextDocumentSyncKind::Full = 1`. Slice 10 (deferred)
      # promotes to `Incremental = 2`.
      TEXT_DOCUMENT_SYNC_FULL = 1

      def advertised_capabilities
        caps = {
          textDocumentSync: {
            openClose: true,
            change: TEXT_DOCUMENT_SYNC_FULL
          }
        }
        caps[:hoverProvider] = true if @hover_provider
        caps[:documentSymbolProvider] = true if @document_symbol_provider
        caps
      end

      # `initialized` is a notification — no response body. Slice 7
      # will hook this to register `workspace/didChangeWatchedFiles`
      # if the client advertised the capability.
      def handle_initialized
        nil
      end

      def handle_shutdown
        @state = :shutdown
        # Drop any in-flight debounced publishes so they don't
        # fire after the client has stopped listening.
        @publisher&.cancel_pending
        nil
      end

      def handle_exit
        @exit_code = @state == :shutdown ? 0 : 1
        @state = :exited
        nil
      end

      # textDocument/didOpen notification. Per LSP spec § the
      # `textDocument` payload carries `uri`, `languageId`,
      # `version`, and the full initial `text`. Triggers a
      # `publishDiagnostics` push when a publisher is wired.
      def handle_did_open(params)
        doc = params.fetch(:textDocument)
        uri = doc.fetch(:uri)
        @buffer_table.open(
          uri: uri,
          bytes: doc.fetch(:text),
          version: doc.fetch(:version)
        )
        @publisher&.publish_for(uri)
        nil
      end

      # textDocument/didChange under FULL sync. Each `contentChanges`
      # entry carries only `{ text: }`; the LAST entry is the new
      # full document text. Per LSP spec § "FULL sync" the array
      # MUST be exactly one entry in practice — we still take
      # `.last` defensively for clients that pad. Triggers
      # `publishDiagnostics` afterwards.
      def handle_did_change(params)
        doc = params.fetch(:textDocument)
        changes = params.fetch(:contentChanges)
        return nil if changes.empty?

        uri = doc.fetch(:uri)
        @buffer_table.change(
          uri: uri,
          bytes: changes.last.fetch(:text),
          version: doc.fetch(:version)
        )
        @publisher&.publish_for(uri)
        nil
      end

      # textDocument/hover REQUEST. Slice 5 returns either a
      # `Hover` payload (markdown contents wrapping type +
      # erased-RBS info) or nil when no expression is at the
      # queried position. Nil maps to `result: null` per LSP
      # spec; clients suppress the popup. Returns
      # `MethodNotFound` when no hover_provider is wired (slice
      # 1-4 behaviour).
      def handle_hover(params)
        return method_not_found("textDocument/hover") unless @hover_provider

        doc = params.fetch(:textDocument)
        pos = params.fetch(:position)
        @hover_provider.provide(
          uri: doc.fetch(:uri),
          line: pos.fetch(:line),
          character: pos.fetch(:character)
        )
      end

      # workspace/didChangeWatchedFiles NOTIFICATION. Invalidates
      # the ProjectContext so cached pre-pass / Environment is
      # rebuilt on the next request. Slice 7's floor: any watched
      # file change triggers a full context rebuild. Per-file
      # surgical invalidation (per design doc § "Project context
      # refresh") is a follow-up; this is the LSP-correct floor.
      def handle_did_change_watched_files(_params)
        @project_context&.invalidate!
        nil
      end

      # workspace/didChangeConfiguration NOTIFICATION. The payload
      # shape is client-specific; v1 ignores the payload and
      # invalidates the context so the next read picks up any
      # external config changes (.rigor.yml / Gemfile.lock / etc).
      def handle_did_change_configuration(_params)
        @project_context&.invalidate!
        nil
      end

      # textDocument/documentSymbol REQUEST. Returns the
      # `DocumentSymbol[]` outline for the buffer at the requested
      # URI. Returns `MethodNotFound` when no provider is wired.
      def handle_document_symbol(params)
        return method_not_found("textDocument/documentSymbol") unless @document_symbol_provider

        doc = params.fetch(:textDocument)
        @document_symbol_provider.provide(doc.fetch(:uri))
      end

      # textDocument/didClose. Drops the buffer table entry AND
      # publishes an empty diagnostic set so clients clear inline
      # markers — per LSP spec § "publishDiagnostics" the standard
      # way to indicate "no diagnostics remain for this URI".
      def handle_did_close(params)
        doc = params.fetch(:textDocument)
        uri = doc.fetch(:uri)
        @buffer_table.close(uri: uri)
        @publisher&.publish_empty(uri)
        nil
      end

      def method_not_found(method)
        rpc_error(ERROR_METHOD_NOT_FOUND, "method not found: #{method.inspect}")
      end

      def rpc_error(code, message)
        { error: { code: code, message: message } }
      end
    end
  end
end
