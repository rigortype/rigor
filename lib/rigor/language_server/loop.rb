# frozen_string_literal: true

require "json"
require "language_server-protocol"

module Rigor
  module LanguageServer
    # JSON-RPC dispatch loop. Drains messages from `reader`, routes
    # each to `server.dispatch`, and writes responses back through
    # `writer`. Stops when either the reader hits EOF (client closed
    # its end of the pipe) or the server transitions to `:exited`.
    #
    # The Loop knows the request / notification distinction from the
    # presence of the `id` field on the inbound JSON-RPC envelope:
    #
    # - Request (`id` present) → ALWAYS gets a response (success or
    #   error). `Server#dispatch` returning nil for a request maps
    #   to `result: null` per the LSP shutdown contract.
    # - Notification (`id` absent) → NEVER gets a response. The
    #   dispatcher's return value is discarded.
    #
    # JSON parse errors at the framing boundary surface as an LSP
    # `ParseError` (-32700) response with `id: null` per JSON-RPC
    # spec § 5.1; the loop continues so a corrupt frame doesn't
    # poison the rest of the session.
    class Loop
      def initialize(reader:, writer:, server:)
        @reader = reader
        @writer = writer
        @server = server
      end

      def run
        @reader.read do |request|
          handle(request)
          break if @server.exited?
        end
      rescue JSON::ParserError => e
        @writer.write(id: nil, error: { code: Server::ERROR_PARSE_ERROR, message: e.message })
      end

      private

      def handle(request)
        method = request[:method]
        params = request[:params]
        id = request[:id]

        result = @server.dispatch(method, params)
        return if id.nil? # notification — no response.

        write_response(id, result)
      end

      # Maps the dispatcher's return value to a JSON-RPC response
      # envelope. `Server#dispatch` returns one of three shapes:
      #
      # - `{ error: {...} }` — surfaced as `{ id, error: {...} }`.
      # - any other Hash — surfaced as `{ id, result: hash }`.
      # - `nil` — surfaced as `{ id, result: null }` (the LSP
      #   `shutdown` contract).
      def write_response(id, result)
        if result.is_a?(Hash) && result.key?(:error)
          @writer.write(id: id, error: result[:error])
        else
          @writer.write(id: id, result: result)
        end
      end
    end
  end
end
