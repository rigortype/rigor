# frozen_string_literal: true

require "json"

module Rigor
  module MCP
    # Reads newline-delimited JSON-RPC 2.0 messages from `input`, dispatches each to `server`, and writes responses to
    # `output`. Runs until input reaches EOF (the client closes the connection).
    class Loop
      def initialize(input:, output:, server:)
        @input = input
        @output = output
        @server = server
      end

      def run
        @input.each_line do |raw|
          line = raw.chomp
          next if line.empty?

          begin
            request = JSON.parse(line)
          rescue JSON::ParserError => e
            write_response({ "jsonrpc" => "2.0", "id" => nil,
                             "error" => { "code" => -32_700, "message" => "Parse error: #{e.message}" } })
            next
          end

          response = @server.handle(request)
          write_response(response) if response
        end
      end

      private

      def write_response(response)
        @output.puts(JSON.generate(response))
        @output.flush
      end
    end
  end
end
