# frozen_string_literal: true

require "json"
require "stringio"

module Rigor
  module MCP
    # JSON-RPC 2.0 dispatcher for the MCP server.
    #
    # Each public `handle` call takes a parsed request hash and returns a response hash (or nil for notifications that
    # require no reply). Tool implementations delegate to `CLI.new(argv, out:, err:).run` with StringIO capture — every
    # tool stays in sync with its CLI counterpart automatically (ADR-33 WD4).
    class Server # rubocop:disable Metrics/ClassLength
      PROTOCOL_VERSION = "2024-11-05"

      TOOLS = [
        {
          name: "rigor_check",
          description: "Analyze Ruby files for type errors, undefined methods, arity mismatches, " \
                       "and nil-receiver risks. Returns a JSON diagnostic report.",
          inputSchema: {
            type: "object",
            properties: {
              paths: {
                type: "array",
                items: { type: "string" },
                description: "Files or directories to analyze (required)"
              },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            },
            required: ["paths"]
          }
        },
        {
          name: "rigor_type_of",
          description: "Get the inferred type of the expression at a specific location in a Ruby file.",
          inputSchema: {
            type: "object",
            properties: {
              file: { type: "string",  description: "Path to the Ruby file" },
              line: { type: "integer", description: "1-based line number" },
              col: { type: "integer", description: "1-based column number" },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            },
            required: %w[file line col]
          }
        },
        {
          name: "rigor_triage",
          description: "Summarize a project's diagnostics: rule distribution, per-file hotspots, " \
                       "and heuristic hints for the most common error clusters. Returns JSON. " \
                       "Useful for understanding the shape of a diagnostic set before deciding what to fix.",
          inputSchema: {
            type: "object",
            properties: {
              paths: {
                type: "array",
                items: { type: "string" },
                description: "Files or directories to analyze (defaults to configured paths)"
              },
              top: { type: "integer", description: "Number of hotspot files to include (default: 10)" },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            }
          }
        },
        {
          name: "rigor_lens",
          description: "Map the classes, modules, methods and attributes the given Ruby files declare, with the " \
                       "type `rigor check` gives each one and where that type came from (sig/, an inline " \
                       "comment, a plugin, a library, or inference). Returns the lens/v0 JSON document " \
                       "(experimental). Pass every file you need in one call: each call pays one analysis run.",
          inputSchema: {
            type: "object",
            properties: {
              files: {
                type: "array",
                items: { type: "string" },
                description: "Ruby files to map (required)"
              },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            },
            required: ["files"]
          }
        },
        {
          name: "rigor_annotate",
          description: "Return the given Ruby source file with each line's last-expression type " \
                       "appended as a comment. Useful for understanding how Rigor infers types " \
                       "through a file.",
          inputSchema: {
            type: "object",
            properties: {
              file: { type: "string", description: "Path to the Ruby file to annotate" },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            },
            required: ["file"]
          }
        },
        {
          name: "rigor_sig_gen",
          description: "Generate RBS skeleton signatures inferred from Ruby source files. " \
                       "Returns a JSON report of candidates with their classifications " \
                       "(new-file, new-method, tighter-return, equivalent, skipped).",
          inputSchema: {
            type: "object",
            properties: {
              paths: {
                type: "array",
                items: { type: "string" },
                description: "Files or directories to generate signatures for (defaults to configured paths)"
              },
              params: {
                type: "string",
                enum: %w[untyped observed],
                description: "Parameter policy: untyped (default) or observed " \
                             "(harvests call-site argument types from the configured test_paths)"
              },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            }
          }
        },
        {
          name: "rigor_explain",
          description: "Look up the description of one or all Rigor diagnostic rules. " \
                       "Returns JSON. Without a rule argument, returns the full catalog.",
          inputSchema: {
            type: "object",
            properties: {
              rule: {
                type: "string",
                description: "Rule ID, legacy alias, or family prefix (call, flow, def, assert, dump, global, " \
                             "suppression, static, effect). Omit to list every rule."
              }
            }
          }
        },
        {
          name: "rigor_coverage",
          description: "Report type-precision coverage: the ratio of expressions Rigor types as " \
                       "Constant / Nominal / shaped / refined (precise) vs Dynamic or top (opaque). " \
                       "Returns JSON. Useful for measuring the impact of adding new fold rules.",
          inputSchema: {
            type: "object",
            properties: {
              paths: {
                type: "array",
                items: { type: "string" },
                description: "Files or directories to scan (required)"
              },
              config: { type: "string", description: "Path to .rigor.yml (optional)" }
            },
            required: ["paths"]
          }
        }
      ].freeze
      Ractor.make_shareable(TOOLS)

      # The tools that read a configuration — the ones taking a `config` argument — and so report its warnings.
      CONFIG_TOOLS = TOOLS.filter_map { |tool| tool[:name] if tool.dig(:inputSchema, :properties, :config) }.freeze
      Ractor.make_shareable(CONFIG_TOOLS)

      def initialize(config_path: nil, err: $stderr)
        @config_path = config_path
        @err = err
      end

      # Dispatches a parsed JSON-RPC request hash. Returns nil for notifications (requests without an `id`).
      def handle(request)
        id = request["id"]
        method_name = request["method"]

        # A notification carries no `id` and requires no response.
        return nil if id.nil?

        case method_name
        when "initialize"  then handle_initialize(id)
        when "ping"        then success(id, {})
        when "tools/list"  then success(id, { tools: TOOLS })
        when "tools/call"
          call_tool(id,
                    request.dig("params", "name"),
                    request.dig("params", "arguments") || {})
        else
          error(id, -32_601, "Method not found: #{method_name.inspect}")
        end
      end

      private

      def handle_initialize(id)
        require_relative "../version"
        success(id, {
                  protocolVersion: PROTOCOL_VERSION,
                  capabilities: { tools: { listChanged: false } },
                  serverInfo: { name: "rigor", version: Rigor::VERSION }
                })
      end

      def call_tool(id, name, args)
        argv = build_argv(name, args)
        return error(id, -32_602, "Unknown tool: #{name.inspect}") unless argv

        out_io = StringIO.new
        err_io = StringIO.new
        require_relative "../cli"
        exit_code = with_captured_streams(out_io, err_io) { CLI.new(argv, out: out_io, err: err_io).run }

        result = tool_result(out_io.string, err_io.string, exit_code)
        success(id, with_config_warnings(result, name, args, out_io.string))
      rescue SystemExit => e
        # Defence against any command that exits: it must not take the server down with it.
        success(id, { content: [{ type: "text", text: "Command exited (status #{e.status})" }], isError: true })
      rescue StandardError => e
        @err.puts("rigor mcp: #{e.class}: #{e.message}")
        @err.puts(e.backtrace.first(5).join("\n")) if e.backtrace
        success(id, {
                  content: [{ type: "text", text: "Internal error: #{e.message}" }],
                  isError: true
                })
      end

      # A non-zero exit with nothing on stdout printed only an error; exit 1 with a document (check, lens) is a
      # result, not an error.
      def tool_result(out, err, exit_code)
        is_error = [CLI::EXIT_USAGE, CLI::EXIT_INTERNAL_ERROR].include?(exit_code) || (out.empty? && !exit_code.zero?)
        { content: [{ type: "text", text: out.empty? ? err : out }], isError: is_error }
      end

      # Issue #2231 — `rigor check` puts {ConfigAudit} warnings in its JSON `config_warnings`; the other tools read the
      # same configuration and said nothing about it, so an agent saw `call.undefined-method` on a project whose
      # `.rigor.yml` misspelt the key meant to silence it and got no hint why. Every tool that takes a `config`
      # argument now carries them: a second `text` content block holding `{"config_warnings": [...]}`, each entry the
      # shape check's JSON uses. The tool's own document is left byte-for-byte as its CLI printed it, and an output
      # that already carries the key (check's) gets no second copy. Nothing is added when there is nothing to say,
      # nor when the configuration does not load — the CLI has already reported that.
      def with_config_warnings(result, name, args, out)
        return result unless CONFIG_TOOLS.include?(name)

        warnings = config_warnings(present_config(args["config"]) || @config_path)
        return result if warnings.empty? || carries_config_warnings?(out)

        block = { type: "text", text: JSON.generate({ "config_warnings" => warnings.map(&:to_h) }) }
        result.merge(content: result.fetch(:content) + [block])
      end

      def config_warnings(config_path)
        require_relative "../configuration"
        require_relative "../config_audit"
        ConfigAudit.warnings(Configuration.load(config_path))
      rescue StandardError
        []
      end

      def carries_config_warnings?(out)
        document = JSON.parse(out)
        document.is_a?(Hash) && document.key?("config_warnings")
      rescue JSON::ParserError
        false
      end

      # The JSON-RPC channel is the process's stdout, so nothing a command writes past its `out:` (an option
      # parser's `--help`, a stray `puts`) may reach it while the command runs.
      def with_captured_streams(out_io, err_io)
        stdout = $stdout
        stderr = $stderr
        $stdout = out_io
        $stderr = err_io
        yield
      ensure
        $stdout = stdout
        $stderr = stderr
      end

      def build_argv(name, args) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/AbcSize,Metrics/PerceivedComplexity
        effective_config = present_config(args["config"]) || @config_path

        case name
        when "rigor_check"
          argv = ["check", "--format=json", "--no-stats"]
          argv << "--config=#{effective_config}" if effective_config
          argv + ["--", *Array(args["paths"])]

        when "rigor_type_of"
          return nil unless args["file"] && args["line"] && args["col"]

          argv = ["type-of", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          # `--` ends the options, so a file named like a flag is a file.
          argv + ["--", "#{args['file']}:#{args['line']}:#{args['col']}"]

        when "rigor_triage"
          argv = ["triage", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv << "--top=#{args['top']}" if args["top"]
          argv + ["--", *Array(args["paths"])]

        when "rigor_lens"
          files = args["files"]
          return nil unless files.is_a?(Array) && !files.empty? && files.all?(String)

          argv = ["lens", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          # `--` ends the options, so a file named like a flag (`--version`) is a file.
          argv + ["--", *files]

        when "rigor_annotate"
          return nil unless args["file"]

          argv = ["annotate", "--no-color"]
          argv << "--config=#{effective_config}" if effective_config
          argv + ["--", args["file"]]

        when "rigor_sig_gen"
          argv = ["sig-gen", "--print", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv << "--params=#{args['params']}" if args["params"]
          argv + ["--", *Array(args["paths"])]

        when "rigor_explain"
          argv = ["explain", "--format=json"]
          args["rule"] ? argv + ["--", args["rule"]] : argv

        when "rigor_coverage"
          argv = ["coverage", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv + ["--", *Array(args["paths"])]
        end
      end

      # A per-call `config` that is blank names no file, so the session default applies rather than `--config=`
      # reaching the CLI as an empty path (which the CLI refuses).
      def present_config(value)
        return value unless value.is_a?(String) && value.strip.empty?

        nil
      end

      def success(id, result)
        { "jsonrpc" => "2.0", "id" => id, "result" => result }
      end

      def error(id, code, message)
        { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
      end
    end
  end
end
