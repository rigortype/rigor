# frozen_string_literal: true

# Force UTF-8 throughout: the nix develop shell defaults to US-ASCII,
# which would break File.read on any source containing non-ASCII chars.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "json"
require "stringio"
require "tempfile"
require "rigor/cli"

module Rigor
  module Playground
    class App
      FRONTEND_DIR = File.expand_path("../../../frontend", __dir__)
      MAX_SOURCE_BYTES = 64 * 1024

      CONTENT_TYPES = {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8"
      }.freeze

      CORS_HEADERS = {
        "access-control-allow-origin" => "*",
        "access-control-allow-methods" => "GET, POST, OPTIONS",
        "access-control-allow-headers" => "content-type"
      }.freeze

      def call(env)
        method = env["REQUEST_METHOD"]
        path   = env["PATH_INFO"]

        return [200, CORS_HEADERS, [""]] if method == "OPTIONS"

        case [method, path]
        in ["GET", "/" | ""]
          serve_static("index.html")
        in ["POST", "/check"]
          handle_check(env)
        in ["POST", "/annotate"]
          handle_annotate(env)
        in ["POST", "/annotate-lines"]
          handle_annotate_lines(env)
        in ["POST", "/type-of"]
          handle_type_of(env)
        else
          [404, json_headers, [JSON.generate({ "error" => "not found" })]]
        end
      rescue StandardError => e
        json_response(500, { "error" => e.message })
      end

      private

      def handle_check(env)
        source = read_source(env)
        return too_large if source.bytesize > MAX_SOURCE_BYTES

        result = with_tempfile(source) do |tmppath|
          stdout = run_cli(["check", "--format=json", tmppath])
          data   = JSON.parse(stdout)
          # Keep only diagnostics from the user's temp file; replace the raw temp path with the virtual
          # "<playground>" label.
          diags = (data["diagnostics"] || []).filter_map do |d|
            next unless d["path"] == tmppath

            d.merge("path" => "<playground>")
          end
          errors = diags.count { |d| d["severity"] == "error" }
          { "success" => errors.zero?, "error_count" => errors, "diagnostics" => diags }
        end
        json_response(200, result)
      rescue JSON::ParserError
        json_response(200, { "success" => true, "error_count" => 0, "diagnostics" => [] })
      end

      def handle_annotate(env)
        source = read_source(env)
        return too_large if source.bytesize > MAX_SOURCE_BYTES

        annotated = with_tempfile(source) { |path| run_cli(["annotate", "--no-color", path]) }
        json_response(200, { "annotated" => annotated })
      end

      def handle_annotate_lines(env)
        source = read_source(env)
        return too_large if source.bytesize > MAX_SOURCE_BYTES

        # `annotate --format json` returns { "annotations": { line => type } } straight from the engine's
        # line-type map — no `#=> <type>` text to reparse. Keys are 1-based line numbers as strings.
        out = with_tempfile(source) { |path| run_cli(["annotate", "--format=json", path]) }
        json_response(200, JSON.parse(out))
      rescue JSON::ParserError
        json_response(200, { "annotations" => {} })
      end

      def handle_type_of(env)
        body   = parse_body(env)
        source = body["source"].to_s
        return too_large if source.bytesize > MAX_SOURCE_BYTES

        line   = body["line"].to_i
        column = body["column"].to_i
        stdout = with_tempfile(source) do |path|
          run_cli(["type-of", "--format=json", "#{path}:#{line}:#{column}"])
        end
        json_response(200, JSON.parse(stdout))
      rescue JSON::ParserError
        json_response(422, { "error" => "could not resolve type at position" })
      end

      def read_source(env)
        parse_body(env).fetch("source", "").to_s
      end

      def parse_body(env)
        raw = env["rack.input"].read.force_encoding("UTF-8")
        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def run_cli(argv)
        out = StringIO.new
        err = StringIO.new
        Rigor::CLI.start(argv, out: out, err: err)
        out.string
      end

      def with_tempfile(source)
        Tempfile.create(["rigor-playground-", ".rb"], encoding: "UTF-8") do |f|
          f.write(source.encode("UTF-8", invalid: :replace, undef: :replace))
          f.flush
          yield f.path
        end
      end

      def serve_static(name)
        path = File.join(FRONTEND_DIR, name)
        return [404, json_headers, [JSON.generate({ "error" => "not found" })]] unless File.exist?(path)

        ext          = File.extname(name)
        content_type = CONTENT_TYPES.fetch(ext, "application/octet-stream")
        [200, { "content-type" => content_type }, [File.binread(path)]]
      end

      def json_response(status, data)
        [status, json_headers, [JSON.generate(data)]]
      end

      def json_headers
        { "content-type" => "application/json" }.merge(CORS_HEADERS)
      end

      def too_large
        json_response(413, { "error" => "Source exceeds 64 KB limit" })
      end
    end
  end
end
