# frozen_string_literal: true

require_relative "command"
require_relative "options"
require_relative "../runtime/jit"

require "json"
require "optionparser"

module Rigor
  class CLI
    # Executes the `rigor lsp` command.
    #
    # Starts a long-running LSP server over stdio (JSON-RPC). See `docs/design/20260517-language-server.md` for the
    # design.
    class LspCommand < Command
      USAGE = "Usage: rigor lsp [options]"

      # Records each JSON-RPC message one per line, prefixed with the direction (`<-` read from the client, `->`
      # written to it) and a timestamp. Only the message framing is logged; the server's own debug output joins the
      # same file through `$stderr` (see {#with_debug_output}).
      #
      # It never raises into the protocol path. A message the JSON encoder rejects (raw invalid UTF-8 in a string) is
      # logged as a scrubbed rendering, so its line is still written. Any IO failure disables the log for the rest of
      # the session: records are dropped, and debug output falls back to `fallback` (the real stderr). Nothing is
      # `warn`ed into the failing log.
      class WireLog
        def initialize(io, fallback)
          @io = io
          @fallback = fallback
          @broken = false
        end

        def record(direction, message)
          deliver { "#{stamp} #{direction} #{render(message)}\n" }
          nil
        end

        # Debug output written to `$stderr` while the session runs (`Kernel#warn` calls `write`).
        def write(*parts)
          text = parts.join
          @fallback.write(text) unless deliver { text }
          text.bytesize
        end

        def print(*parts)
          write(*parts)
          nil
        end

        def puts(*args)
          lines = if args.empty?
                    ["\n"]
                  else
                    args.flatten.map { |arg| arg.to_s.end_with?("\n") ? arg.to_s : "#{arg}\n" }
                  end
          write(*lines)
          nil
        end

        def <<(part)
          write(part)
          self
        end

        def flush
          self
        end

        # The exception that escaped the server loop, with its backtrace, so a crash is in the log, not only on stderr.
        def crash(error)
          lines = ["#{stamp} ! #{error.class}: #{error.message}\n"]
          lines.concat((error.backtrace || []).map { |frame| "    #{frame}\n" })
          text = lines.join
          @fallback.write(text) unless deliver { text }
          nil
        end

        def close
          @io.close unless @io.closed?
        end

        private

        # Writes the text the block builds. Returns false when the log is (or just became) unusable.
        def deliver
          return false if @broken

          @io.write(yield)
          true
        rescue StandardError
          @broken = true
          false
        end

        def stamp
          Time.now.strftime("%FT%T.%6N%:z")
        end

        # The JSON line for `message`; a message the encoder rejects is rendered from its scrubbed copy, or from its
        # `inspect` when even that does not encode.
        def render(message)
          JSON.generate(message)
        rescue JSON::GeneratorError, EncodingError
          begin
            JSON.generate(scrub(message))
          rescue JSON::GeneratorError, EncodingError
            JSON.generate(message.inspect)
          end
        end

        def scrub(value)
          case value
          when Hash then value.to_h { |key, val| [scrub(key), scrub(val)] }
          when Array then value.map { |item| scrub(item) }
          when Symbol then scrub(value.to_s).to_sym
          when String then value.dup.force_encoding(Encoding::UTF_8).scrub
          else value
          end
        end
      end

      # Wraps the framed reader so every request or notification it yields is logged before the Loop dispatches it.
      class WireLogReader
        def initialize(inner, log)
          @inner = inner
          @log = log
        end

        def read(&block)
          @inner.read do |message|
            @log.record("<-", message)
            block.call(message)
          end
        end

        def close
          @inner.close
        end
      end

      # Wraps the framed writer so every outgoing message is logged as it goes on the wire. It sits inside
      # `SynchronizedWriter`, so the log line and the frame it describes are written under the same lock.
      class WireLogWriter
        def initialize(inner, log)
          @inner = inner
          @log = log
        end

        def write(message)
          @log.record("->", message.merge(jsonrpc: "2.0"))
          @inner.write(message)
        end

        def close
          @inner.close
        end
      end

      # @return CLI exit status.
      def run
        options = parse_options
        return CLI::EXIT_USAGE if options == :usage_error

        transport = options.fetch(:transport)
        unless transport == "stdio"
          @err.puts("rigor lsp: unsupported transport: #{transport.inspect} (only `stdio` is supported in v1)")
          return CLI::EXIT_USAGE
        end

        log = open_wire_log(options.fetch(:log))
        return CLI::EXIT_USAGE if log == :usage_error

        # A long-lived server always outlasts the JIT compile cost, so enable
        # YJIT at boot rather than on the analysis deadline (Runtime::Jit).
        Runtime::Jit.enable_now

        require_relative "../language_server"
        require_relative "../configuration"
        require "language_server-protocol"

        begin
          serve(config_path: options.fetch(:config), log: log)
        ensure
          log&.close
        end
      end

      # The parser this command parses with, built without parsing anything: the catalogue reads the
      # flags and formats from it (ADR-126 WD3). `options` is only written by the switches' blocks.
      def option_parser(options = {})
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--transport=NAME", "Transport (default: stdio; only stdio supported in v1)") do |value|
            options[:transport] = value
          end
          opts.on("--log=PATH",
                  "Append the LSP wire log and server debug output to PATH " \
                  "(default: no wire log; debug output goes to stderr)") do |value|
            options[:log] = value
          end
          Options.add_config(opts, options)
        end
      end

      private

      # STDIN is read frame-by-frame via the gem's `Io::Reader`; STDOUT is wrapped in `SynchronizedWriter` so
      # concurrent writes from the main dispatch thread + the Debouncer's async threads don't interleave frames. The
      # Loop runs until either STDIN hits EOF or `server.exited?`; the process then exits with the server's recorded
      # code (0 after a clean shutdown+exit, 1 otherwise). With a wire log, both directions are logged inside the lock.
      def serve(config_path:, log:)
        reader = ::LanguageServer::Protocol::Transport::Io::Reader.new($stdin)
        frame_writer = ::LanguageServer::Protocol::Transport::Io::Writer.new($stdout)
        if log
          reader = WireLogReader.new(reader, log)
          frame_writer = WireLogWriter.new(frame_writer, log)
        end
        writer = LanguageServer::SynchronizedWriter.new(frame_writer)
        server, loop_runner = build_server(writer: writer, reader: reader, config_path: config_path)
        with_debug_output(log) { loop_runner.run }
        server.exit_code || 0
      end

      # Opens PATH for appending with synchronous writes, so a crash loses no logged line. Returns nil without a
      # PATH, the open file, or `:usage_error` after reporting why it could not be opened.
      def open_wire_log(path)
        return nil if path.nil?

        io = File.new(path, "a")
        io.sync = true
        WireLog.new(io, $stderr)
      rescue SystemCallError => e
        @err.puts("rigor lsp: cannot open --log file #{path.inspect}: #{e.message}")
        :usage_error
      end

      # Routes the server's debug output (`warn` and the Ruby runtime's warnings, both written to `$stderr`) into the
      # wire log for the length of the session. An exception that escapes the loop is written to the log before
      # `$stderr` is restored and the exception is re-raised. Without a log, `$stderr` is left alone.
      def with_debug_output(log)
        return yield if log.nil?

        saved = $stderr
        begin
          $stderr = log
          yield
        rescue StandardError, ScriptError, SystemStackError => e
          log.crash(e)
          raise
        ensure
          $stderr = saved
        end
      end

      # Builds the full collaborator graph from a fresh `Configuration` + `ProjectContext`. Returns `[server, loop]` so
      # the caller drives the loop and reads `server.exit_code` for the process exit status.
      def build_server(writer:, reader:, config_path:) # rubocop:disable Metrics/MethodLength
        configuration = Configuration.load(config_path)
        # ProjectContext caches Environment + Cache::Store across requests so hover / publish hit the warm path.
        # Invalidated by `workspace/didChangeWatchedFiles` and `workspace/didChangeConfiguration`; every save round
        # also re-reads the configuration (the loader below) and re-baselines when its inputs moved (#1613).
        project_context = LanguageServer::ProjectContext.new(
          configuration: configuration, configuration_loader: -> { Configuration.load(config_path) }
        )
        # Single source of truth for buffer state — threaded to Server + all three providers.
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
          folding_range_provider: LanguageServer::FoldingRangeProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          selection_range_provider: LanguageServer::SelectionRangeProvider.new(
            buffer_table: buffer_table, project_context: project_context
          ),
          project_context: project_context
        )
        loop_runner = LanguageServer::Loop.new(
          reader: reader,
          writer: writer,
          server: server
        )
        [server, loop_runner]
      end

      def parse_options
        options = { transport: "stdio", log: nil, config: nil }

        option_parser(options).parse!(@argv)
        options
      rescue OptionParser::ParseError => e
        @err.puts(e.message)
        @err.puts(USAGE)
        :usage_error
      end
    end
  end
end
