# frozen_string_literal: true

require "optionparser"

module Rigor
  class CLI
    # Executes the `rigor lsp` command.
    #
    # See `docs/design/20260517-language-server.md` for the design.
    # Slice 1 (this commit) ships the CLI subcommand entry point.
    # The actual stdio JSON-RPC reader / writer is queued for slice 2;
    # invoking `rigor lsp` at slice 1 returns immediately after
    # validating the transport flag.
    class LspCommand
      USAGE = "Usage: rigor lsp [options]"

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        return CLI::EXIT_USAGE if options == :usage_error

        transport = options.fetch(:transport)
        # Slice 1 doesn't wire the wire. We validate the transport
        # selection (stdio only in v1) so the CLI surface is locked
        # in, and slice 2 swaps this branch for the real stdio
        # JSON-RPC loop driving Rigor::LanguageServer::Server.
        unless transport == "stdio"
          @err.puts("rigor lsp: unsupported transport: #{transport.inspect} (only `stdio` is supported in v1)")
          return CLI::EXIT_USAGE
        end

        require_relative "../language_server"
        @err.puts("rigor lsp: stdio JSON-RPC transport queued for slice 2 (server lifecycle ready, wire pending)")
        0
      end

      private

      def parse_options
        options = { transport: "stdio", log: nil, config: nil }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--transport=NAME", "Transport (default: stdio; only stdio supported in v1)") do |value|
            options[:transport] = value
          end
          opts.on("--log=PATH", "Write LSP wire log + server debug to PATH (default: stderr)") do |value|
            options[:log] = value
          end
          opts.on("--config=PATH", "Path to the Rigor configuration file") do |value|
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
