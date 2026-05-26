# frozen_string_literal: true

require "json"
require "stringio"

module Rigor
  module MCP
    # JSON-RPC 2.0 dispatcher for the MCP server.
    #
    # Each public `handle` call takes a parsed request hash and returns
    # a response hash (or nil for notifications that require no reply).
    # Tool implementations delegate to `CLI.new(argv, out:, err:).run`
    # with StringIO capture — every tool stays in sync with its CLI
    # counterpart automatically (ADR-33 WD4).
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
                             "(harvests call-site argument types from spec/)"
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
                description: "Rule ID, legacy alias, or family prefix (call, flow, assert, dump, def). " \
                             "Omit to list every rule."
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

      def initialize(config_path: nil, err: $stderr)
        @config_path = config_path
        @err = err
      end

      # Dispatches a parsed JSON-RPC request hash.
      # Returns nil for notifications (requests without an `id`).
      def handle(request)
        id = request["id"]
        method_name = request["method"]

        # Notifications carry no `id` and require no response.
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
        exit_code = CLI.new(argv, out: out_io, err: err_io).run

        is_error = exit_code == CLI::EXIT_USAGE
        text = out_io.string
        text = err_io.string if text.empty? && is_error

        success(id, { content: [{ type: "text", text: text }], isError: is_error })
      rescue StandardError => e
        @err.puts("rigor mcp: #{e.class}: #{e.message}")
        @err.puts(e.backtrace.first(5).join("\n")) if e.backtrace
        success(id, {
                  content: [{ type: "text", text: "Internal error: #{e.message}" }],
                  isError: true
                })
      end

      def build_argv(name, args) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/AbcSize,Metrics/PerceivedComplexity
        effective_config = args["config"] || @config_path

        case name
        when "rigor_check"
          argv = ["check", "--format=json", "--no-stats"]
          argv << "--config=#{effective_config}" if effective_config
          argv += Array(args["paths"])
          argv

        when "rigor_type_of"
          return nil unless args["file"] && args["line"] && args["col"]

          argv = ["type-of", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv << "#{args['file']}:#{args['line']}:#{args['col']}"
          argv

        when "rigor_triage"
          argv = ["triage", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv << "--top=#{args['top']}" if args["top"]
          argv += Array(args["paths"])
          argv

        when "rigor_annotate"
          return nil unless args["file"]

          argv = ["annotate", "--no-color"]
          argv << "--config=#{effective_config}" if effective_config
          argv << args["file"]
          argv

        when "rigor_sig_gen"
          argv = ["sig-gen", "--print", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv << "--params=#{args['params']}" if args["params"]
          argv += Array(args["paths"])
          argv

        when "rigor_explain"
          argv = ["explain", "--format=json"]
          argv << args["rule"] if args["rule"]
          argv

        when "rigor_coverage"
          argv = ["coverage", "--format=json"]
          argv << "--config=#{effective_config}" if effective_config
          argv += Array(args["paths"])
          argv
        end
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
