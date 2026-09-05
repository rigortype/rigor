# frozen_string_literal: true

require_relative "../version"
require_relative "buffer_table"

module Rigor
  module LanguageServer
    # LSP server lifecycle state machine + JSON-RPC method dispatcher. State machine: `:uninitialized` →
    # `:initialized` → `:shutdown` → `:exited`. {#dispatch} routes (method, params) to the matching handler and
    # returns the response payload (`nil` for notifications); out-of-state requests return `InvalidRequest`
    # (-32002) / `MethodNotFound` (-32601). Full v1 capability surface (document sync, publishDiagnostics,
    # hover, completion, sig-help, folding, selection, and watched-file invalidation) is implemented.
    class Server # rubocop:disable Metrics/ClassLength
      # JSON-RPC error codes per LSP spec § "Response Message".
      ERROR_PARSE_ERROR      = -32_700
      ERROR_INVALID_REQUEST  = -32_600
      ERROR_METHOD_NOT_FOUND = -32_601
      ERROR_INVALID_PARAMS   = -32_602
      ERROR_INTERNAL_ERROR   = -32_603
      # LSP-specific reserved codes.
      ERROR_SERVER_NOT_INITIALIZED = -32_002
      ERROR_INVALID_REQUEST_AFTER_SHUTDOWN = -32_600

      # `TextDocumentSyncKind::Incremental = 2`: `didChange` carries range edits, which `IncrementalSync`
      # splices into the buffer the table already holds instead of re-sending — and re-parsing — the whole
      # document on every keystroke. The full-text entry form (a `contentChanges` entry with no `range`) stays
      # legal under this mode and is still handled.
      TEXT_DOCUMENT_SYNC_INCREMENTAL = 2

      # LSP `PositionEncodingKind`. UTF-16 is the protocol default and the encoding `IncrementalSync` does its
      # offset arithmetic in; advertising it explicitly states the contract rather than leaving it implied.
      POSITION_ENCODING_UTF16 = "utf-16"

      # Methods callable BEFORE `initialize`. Per LSP spec § 3 only `initialize` and `exit` are allowed
      # pre-initialization; every other request returns `ServerNotInitialized`. We also accept `shutdown` so a
      # sequence like `initialize → shutdown → exit` (the conformance harness) round-trips even when the
      # client skips real work.
      PRE_INITIALIZE_METHODS = %w[initialize shutdown exit].freeze

      attr_reader :state, :exit_code, :buffer_table, :publisher,
                  :hover_provider, :document_symbol_provider, :completion_provider,
                  :signature_help_provider, :folding_range_provider,
                  :selection_range_provider, :project_context

      #   resolves `textDocument/completion`. Nil → `MethodNotFound`.
      #   resolves `textDocument/signatureHelp`. Nil → `MethodNotFound`.
      # @rbs project_context: Rigor::LanguageServer::ProjectContext? --
      #   The per-session cache of `Environment` + `Cache::Store` the providers read on every request. When present,
      #   `workspace/didChangeWatchedFiles` and `workspace/didChangeConfiguration` invalidate the cache; nil means "no
      #   project context": each request rebuilds env from scratch (mainly for specs and backward compatibility).
      def initialize(buffer_table: BufferTable.new, publisher: nil, # rubocop:disable Metrics/ParameterLists
                     hover_provider: nil, document_symbol_provider: nil,
                     completion_provider: nil, signature_help_provider: nil,
                     folding_range_provider: nil, selection_range_provider: nil,
                     project_context: nil)
        @state = :uninitialized
        @exit_code = nil
        @buffer_table = buffer_table
        @publisher = publisher
        @hover_provider = hover_provider
        @document_symbol_provider = document_symbol_provider
        @completion_provider = completion_provider
        @signature_help_provider = signature_help_provider
        @folding_range_provider = folding_range_provider
        @selection_range_provider = selection_range_provider
        @project_context = project_context
      end

      # @rbs return: bool --
      #   True once the client has called `exit` and the server has set its terminal exit code. The CLI loop reads
      #   this between dispatches to know when to stop.
      def exited?
        @state == :exited
      end

      # Routes one LSP method call.
      #
      # @rbs method: String -- The LSP method name (e.g. "initialize").
      # @rbs params: Hash[untyped, untyped]? --
      #   The LSP `params` payload (Hash for request / notification methods; nil for the empty case).
      # @rbs return: Hash[untyped, untyped]? --
      #   One of: - the response result Hash for request methods, - nil for notification methods, - { error: { code:,
      #   message: } } for state / shape errors.
      def dispatch(method, params = nil) # rubocop:disable Metrics/CyclomaticComplexity
        return state_violation_response(method) unless method_allowed_in_state?(method)

        case method
        when "initialize"             then handle_initialize(params)
        when "initialized"            then handle_initialized
        when "shutdown"               then handle_shutdown
        when "exit"                   then handle_exit
        when "textDocument/didOpen"   then handle_did_open(params)
        when "textDocument/didChange" then handle_did_change(params)
        when "textDocument/didSave"   then handle_did_save(params)
        when "textDocument/didClose"  then handle_did_close(params)
        when "textDocument/hover"               then handle_hover(params)
        when "textDocument/documentSymbol"      then handle_document_symbol(params)
        when "textDocument/completion"          then handle_completion(params)
        when "textDocument/signatureHelp"       then handle_signature_help(params)
        when "textDocument/foldingRange"        then handle_folding_range(params)
        when "textDocument/selectionRange"      then handle_selection_range(params)
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

      # Per LSP spec § "Server lifecycle / initialize": the server responds with its capabilities. Each later
      # slice extends `advertised_capabilities` with the handler it wires; clients asking for unadvertised
      # methods get `MethodNotFound`.
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

      def advertised_capabilities
        caps = {
          positionEncoding: POSITION_ENCODING_UTF16,
          textDocumentSync: {
            openClose: true,
            change: TEXT_DOCUMENT_SYNC_INCREMENTAL,
            # `includeText: false` — the round reads the file the client just wrote, so the payload's copy
            # would be redundant. See `handle_did_save`.
            save: { includeText: false }
          }
        }
        caps[:hoverProvider] = true if @hover_provider
        caps[:documentSymbolProvider] = true if @document_symbol_provider
        if @completion_provider
          caps[:completionProvider] = {
            # `.` for method completion; `:` for constant-path completion (slice 6). The server detects which
            # form by looking one character back when `:` triggers.
            triggerCharacters: [".", ":"],
            # v1 eager — full payload returned on first request. Resolve becomes relevant if large
            # enumerations (Object descendants) become noticeable.
            resolveProvider: false
          }
        end
        if @signature_help_provider
          caps[:signatureHelpProvider] = {
            # `(` opens the argument list; `,` advances to the next argument. Editors retrigger on both.
            triggerCharacters: ["(", ","]
          }
        end
        caps[:foldingRangeProvider] = true if @folding_range_provider
        caps[:selectionRangeProvider] = true if @selection_range_provider
        caps
      end

      # `initialized` is a notification — no response body. Slice 7 will hook this to register
      # `workspace/didChangeWatchedFiles` if the client advertised the capability.
      def handle_initialized
        nil
      end

      def handle_shutdown
        @state = :shutdown
        # Drop any in-flight debounced publishes so they don't fire after the client has stopped listening.
        @publisher&.cancel_pending
        nil
      end

      def handle_exit
        @exit_code = @state == :shutdown ? 0 : 1
        @state = :exited
        nil
      end

      # textDocument/didOpen notification. Per LSP spec § the `textDocument` payload carries `uri`,
      # `languageId`, `version`, and the full initial `text`. Triggers a `publishDiagnostics` push when a
      # publisher is wired.
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

      # textDocument/didChange under INCREMENTAL sync. Every `contentChanges` entry is applied in order, each
      # against the result of the previous — an entry with a `range` splices that span, an entry without one is
      # the full new document text. The application (and its UTF-16 offset arithmetic) lives in
      # `IncrementalSync`; the table keeps the last known-good text and flags the URI when a change cannot be
      # applied. Triggers `publishDiagnostics` either way: a desynchronised buffer publishes an EMPTY set,
      # which clears the markers instead of leaving stale ones on screen.
      def handle_did_change(params)
        doc = params.fetch(:textDocument)
        changes = params.fetch(:contentChanges)
        return nil if changes.empty?

        uri = doc.fetch(:uri)
        @buffer_table.apply_changes(
          uri: uri,
          changes: changes,
          version: doc.fetch(:version)
        )
        @publisher&.publish_for(uri)
        nil
      end

      # textDocument/didSave notification. Marks the buffer clean — the client has written it, so the held
      # text and the file on disk agree — and starts a whole-project publish round (#246).
      #
      # This is where whole-project scope lives, rather than on `didChange`: a round costs ~0.6s on a
      # mid-sized project against a 250ms `didChange` p50 budget, and "the rest of the project catches up"
      # is what saving means to the user. Because the saved bytes are the bytes on disk, the round needs no
      # buffer binding at all. Design: `docs/design/20260517-language-server.md` § "Whole-project publishes
      # on save".
      def handle_did_save(params)
        uri = params.fetch(:textDocument).fetch(:uri)
        @buffer_table.save(uri: uri)
        @publisher&.publish_project(uri)
        nil
      end

      # textDocument/hover REQUEST. Slice 5 returns either a `Hover` payload (markdown contents wrapping type
      # + erased-RBS info) or nil when no expression is at the queried position. Nil maps to `result: null`
      # per LSP spec; clients suppress the popup. Returns `MethodNotFound` when no hover_provider is wired
      # (slice 1-4 behaviour).
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

      # workspace/didChangeWatchedFiles NOTIFICATION. Invalidates the ProjectContext so cached pre-pass /
      # Environment is rebuilt on the next request. Slice 7's floor: any watched file change triggers a full
      # context rebuild. Per-file surgical invalidation (per design doc § "Project context refresh") is a
      # follow-up; this is the LSP-correct floor.
      def handle_did_change_watched_files(_params)
        @project_context&.invalidate!
        nil
      end

      # workspace/didChangeConfiguration NOTIFICATION. The payload shape is client-specific; v1 ignores the
      # payload and invalidates the context so the next read picks up any external config changes
      # (.rigor.yml / Gemfile.lock / etc).
      def handle_did_change_configuration(_params)
        @project_context&.invalidate!
        nil
      end

      # textDocument/selectionRange REQUEST. Routes to the selection-range provider when wired;
      # `MethodNotFound` otherwise.
      def handle_selection_range(params)
        return method_not_found("textDocument/selectionRange") unless @selection_range_provider

        doc = params.fetch(:textDocument)
        positions = params.fetch(:positions)
        @selection_range_provider.provide(doc.fetch(:uri), positions)
      end

      # textDocument/foldingRange REQUEST. Routes to the folding-range provider when wired; `MethodNotFound`
      # otherwise.
      def handle_folding_range(params)
        return method_not_found("textDocument/foldingRange") unless @folding_range_provider

        doc = params.fetch(:textDocument)
        @folding_range_provider.provide(doc.fetch(:uri))
      end

      # textDocument/signatureHelp REQUEST. Routes to the signature-help provider when wired; `MethodNotFound`
      # otherwise.
      def handle_signature_help(params)
        return method_not_found("textDocument/signatureHelp") unless @signature_help_provider

        doc = params.fetch(:textDocument)
        pos = params.fetch(:position)
        context = params[:context]
        @signature_help_provider.provide(
          uri: doc.fetch(:uri),
          line: pos.fetch(:line),
          character: pos.fetch(:character),
          context: context
        )
      end

      # textDocument/completion REQUEST. Routes to the completion provider when wired; `MethodNotFound`
      # otherwise.
      def handle_completion(params)
        return method_not_found("textDocument/completion") unless @completion_provider

        doc = params.fetch(:textDocument)
        pos = params.fetch(:position)
        context = params[:context] || {}
        @completion_provider.provide(
          uri: doc.fetch(:uri),
          line: pos.fetch(:line),
          character: pos.fetch(:character),
          trigger_character: context[:triggerCharacter]
        )
      end

      # textDocument/documentSymbol REQUEST. Returns the `DocumentSymbol[]` outline for the buffer at the
      # requested URI. Returns `MethodNotFound` when no provider is wired.
      def handle_document_symbol(params)
        return method_not_found("textDocument/documentSymbol") unless @document_symbol_provider

        doc = params.fetch(:textDocument)
        @document_symbol_provider.provide(doc.fetch(:uri))
      end

      # textDocument/didClose. Drops the buffer table entry AND publishes an empty diagnostic set so clients
      # clear inline markers — per LSP spec § "publishDiagnostics" the standard way to indicate "no
      # diagnostics remain for this URI".
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
