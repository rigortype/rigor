# frozen_string_literal: true

require_relative "command"
require_relative "../runtime/jit"

require "optionparser"

module Rigor
  class CLI
    # Executes the `rigor mcp` command.
    #
    # Starts a long-running MCP (Model Context Protocol) server over stdio. The server exposes Rigor's analysis tools as
    # MCP tool calls over a newline-delimited JSON-RPC 2.0 stream. See ADR-33.
    #
    # Slice 1 ships the stdio transport with seven read-only tools: rigor_check, rigor_type_of, rigor_triage,
    # rigor_annotate, rigor_sig_gen, rigor_explain, rigor_coverage.
    class McpCommand < Command
      USAGE = "Usage: rigor mcp [options]"

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        return CLI::EXIT_USAGE if options == :usage_error

        transport = options.fetch(:transport)
        unless transport == "stdio"
          @err.puts("rigor mcp: unsupported transport: #{transport.inspect} (only `stdio` is supported in v1)")
          return CLI::EXIT_USAGE
        end

        # A long-lived server always outlasts the JIT compile cost, so enable
        # YJIT at boot rather than on the analysis deadline (Runtime::Jit).
        Runtime::Jit.enable_now

        require_relative "../mcp"
        require_relative "../version"

        server = MCP::Server.new(config_path: options.fetch(:config), err: $stderr)
        loop_runner = MCP::Loop.new(input: $stdin, output: $stdout, server: server)
        loop_runner.run
        0
      end

      private

      def parse_options
        options = { transport: "stdio", config: nil }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--transport=NAME",
                  "Transport (default: stdio; only stdio is supported in v1)") do |value|
            options[:transport] = value
          end
          opts.on("--config=PATH",
                  "Session-level default config path (individual tool calls may override)") do |value|
            options[:config] = value
          end
        end
        parser.parse!(@argv)
        options
      rescue OptionParser::ParseError => e
        @err.puts(e.message)
        @err.puts(USAGE)
        :usage_error
      end
    end
  end
end
