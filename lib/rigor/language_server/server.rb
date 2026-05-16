# frozen_string_literal: true

require_relative "../version"

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

      attr_reader :state, :exit_code

      def initialize
        @state = :uninitialized
        @exit_code = nil
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
        when "initialize"       then handle_initialize(params)
        when "initialized"      then handle_initialized
        when "shutdown"         then handle_shutdown
        when "exit"             then handle_exit
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
      # responds with its capabilities. Slice 1 advertises NOTHING
      # — every cap is added in the slice that wires the handler.
      # Clients that ask for unadvertised methods get
      # `MethodNotFound`.
      def handle_initialize(_params)
        @state = :initialized
        {
          capabilities: {},
          serverInfo: {
            name: "rigor-lsp",
            version: Rigor::VERSION
          }
        }
      end

      # `initialized` is a notification — no response body. Slice 7
      # will hook this to register `workspace/didChangeWatchedFiles`
      # if the client advertised the capability.
      def handle_initialized
        nil
      end

      def handle_shutdown
        @state = :shutdown
        nil
      end

      def handle_exit
        @exit_code = @state == :shutdown ? 0 : 1
        @state = :exited
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
