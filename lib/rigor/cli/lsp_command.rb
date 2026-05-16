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
        unless transport == "stdio"
          @err.puts("rigor lsp: unsupported transport: #{transport.inspect} (only `stdio` is supported in v1)")
          return CLI::EXIT_USAGE
        end

        require_relative "../language_server"
        require_relative "../configuration"
        require "language_server-protocol"

        # STDIN is read frame-by-frame via the gem's `Io::Reader`;
        # STDOUT is written via `Io::Writer` which auto-merges
        # `jsonrpc: "2.0"` into every response. The Loop runs until
        # either STDIN hits EOF (client closed the pipe) or the
        # server reaches `:exited`. The process then exits with the
        # server's recorded exit code (0 after a clean
        # `shutdown`+`exit`, 1 otherwise — per the LSP `exit`
        # contract).
        writer = ::LanguageServer::Protocol::Transport::Io::Writer.new($stdout)
        configuration = Configuration.load(options.fetch(:config))
        # The same BufferTable instance is threaded to both Server
        # (for didOpen / didChange / didClose writes) and Publisher
        # (for read-by-URI when emitting diagnostics) so they share
        # one source of truth.
        buffer_table = LanguageServer::BufferTable.new
        publisher = LanguageServer::DiagnosticPublisher.new(
          writer: writer, configuration: configuration, buffer_table: buffer_table
        )
        server = LanguageServer::Server.new(buffer_table: buffer_table, publisher: publisher)
        loop_runner = LanguageServer::Loop.new(
          reader: ::LanguageServer::Protocol::Transport::Io::Reader.new($stdin),
          writer: writer,
          server: server
        )
        loop_runner.run
        server.exit_code || 0
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
