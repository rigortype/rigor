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
        # STDOUT is wrapped in `SynchronizedWriter` so concurrent
        # writes from the main dispatch thread + the Debouncer's
        # async threads don't interleave frames. The Loop runs
        # until either STDIN hits EOF or `server.exited?`; the
        # process then exits with the server's recorded code
        # (0 after a clean shutdown+exit, 1 otherwise).
        writer = LanguageServer::SynchronizedWriter.new(
          ::LanguageServer::Protocol::Transport::Io::Writer.new($stdout)
        )
        server, loop_runner = build_server(writer: writer, config_path: options.fetch(:config))
        loop_runner.run
        server.exit_code || 0
      end

      private

      # Builds the full collaborator graph from a fresh
      # `Configuration` + `ProjectContext`. Returns `[server,
      # loop]` so the caller drives the loop and reads
      # `server.exit_code` for the process exit status.
      def build_server(writer:, config_path:) # rubocop:disable Metrics/MethodLength
        configuration = Configuration.load(config_path)
        # ProjectContext caches Environment + Cache::Store across
        # requests so hover / publish hit the warm path. Invalidated
        # by `workspace/didChangeWatchedFiles` and
        # `workspace/didChangeConfiguration`.
        project_context = LanguageServer::ProjectContext.new(configuration: configuration)
        # Single source of truth for buffer state — threaded to
        # Server + all three providers.
        buffer_table = LanguageServer::BufferTable.new
        debouncer = LanguageServer::Debouncer.new
        publisher = LanguageServer::DiagnosticPublisher.new(
          writer: writer, buffer_table: buffer_table, project_context: project_context,
          debouncer: debouncer, debounce_seconds: 0.2
        )
        server = LanguageServer::Server.new(
          buffer_table: buffer_table,
          publisher: publisher,
          hover_provider: LanguageServer::HoverProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          document_symbol_provider: LanguageServer::DocumentSymbolProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          completion_provider: LanguageServer::CompletionProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          signature_help_provider: LanguageServer::SignatureHelpProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          project_context: project_context
        )
        loop_runner = LanguageServer::Loop.new(
          reader: ::LanguageServer::Protocol::Transport::Io::Reader.new($stdin),
          writer: writer,
          server: server
        )
        [server, loop_runner]
      end

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
