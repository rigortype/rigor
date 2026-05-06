# frozen_string_literal: true

require "rigor/plugin"

require_relative "routes/route_table"
require_relative "routes/walker"

module Rigor
  module Plugin
    # Example plugin: validates Rails-style route helper calls
    # (`users_path`, `edit_user_path(@user.id)`, …) against a
    # YAML route table read from the project. This is the
    # reference example for **slice 2 (`Plugin::IoBoundary` /
    # `Plugin::TrustPolicy`)** and **slice 6 (`Plugin::Base.producer`
    # / `#cache_for`)** — the two facets the earlier
    # `rigor-lisp-eval` and `rigor-units` examples did not
    # exercise.
    #
    # ## Architecture
    #
    # - `init` reads the configured `routes_file` path from the
    #   plugin's frozen `config` Hash. Default: `config/routes.yml`.
    # - `diagnostics_for_file` consults a memoised `RouteTable`
    #   produced via the cache surface; first call reads the file
    #   through `IoBoundary#read_file` (so `TrustPolicy` validates
    #   the path AND the boundary records a `:digest` `FileEntry`),
    #   then calls into `cache_for(:route_table)` whose captured
    #   descriptor includes that digest. Subsequent runs hit the
    #   cache when `routes.yml` content is unchanged.
    # - The `Walker` finds every `*_path` / `*_url` implicit-
    #   receiver call. Each is checked against the table for
    #   existence and arity (= number of `:foo` placeholders in
    #   the path template). Unknown helpers carry a "did you
    #   mean" suggestion via Levenshtein distance ≤ 3.
    #
    # Same scope note as `rigor-lisp-eval` / `rigor-units`:
    # diagnostics-only today; once plugin return-type
    # contributions ship in v0.1.x, the same `RouteTable` lookup
    # moves into a `FlowContribution` bundle so callers can rely
    # on the analyzer's own inferred return type.
    #
    # ## Usage
    #
    # `.rigor.yml`:
    #
    #     plugins:
    #       - gem: rigor-routes
    #         config:
    #           routes_file: config/routes.yml   # default; optional
    class Routes < Rigor::Plugin::Base
      manifest(
        id: "routes",
        version: "0.1.0",
        description: "Validates Rails-style route helper calls against a YAML route table.",
        config_schema: {
          "routes_file" => :string
        }
      )

      DEFAULT_ROUTES_FILE = "config/routes.yml"
      DID_YOU_MEAN_DISTANCE = 3

      # Cached producer (slice 6-A). The block runs through
      # `instance_exec` so `@routes_file`, `io_boundary`, and
      # private helpers are all in scope. The cache descriptor
      # (slice 6-B) is auto-assembled from the plugin's
      # `PluginEntry` template plus the `IoBoundary`'s
      # accumulated `FileEntry` digests; nothing to wire up by
      # hand.
      producer :route_table do |_params|
        contents = io_boundary.read_file(@routes_file)
        RouteTable.parse(contents)
      end

      def init(_services)
        @routes_file = config.fetch("routes_file", DEFAULT_ROUTES_FILE)
        @table = nil
        @load_error = nil
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        table = route_table
        return [load_error_diagnostic(path)] if table.nil?
        return [] if table.empty?

        diagnostics = []
        Walker.each_helper_call(root) do |node, base, kind|
          diagnostics.concat(diagnostics_for_call(path, node, base, kind, table))
        end
        diagnostics
      end

      private

      def route_table
        return @table if @table

        # Read the file FIRST so the IoBoundary records the
        # digest, then call `cache_for` — the descriptor it
        # captures now includes the digest, so the cache key
        # invalidates when `routes.yml` changes. (Pattern from
        # `spec/rigor/plugin/cache_producer_spec.rb` —
        # "invalidates when files read via io_boundary BEFORE
        # cache_for change between calls".)
        io_boundary.read_file(@routes_file)
        @table = cache_for(:route_table, params: {}).call
      rescue Plugin::AccessDeniedError => e
        @load_error = "rigor-routes: #{e.message}"
        nil
      rescue Errno::ENOENT
        @load_error = "rigor-routes: routes file `#{@routes_file}` not found; helper checks skipped"
        nil
      rescue ArgumentError, Psych::SyntaxError => e
        @load_error = "rigor-routes: failed to parse `#{@routes_file}`: #{e.message}"
        nil
      end

      def diagnostics_for_call(path, node, base, kind, table)
        entry = table.find(base)
        return [unknown_route_diagnostic(path, node, base, kind, table)] unless entry

        actual_arity = call_argument_count(node)
        if actual_arity != entry.arity
          [arity_mismatch_diagnostic(path, node, base, kind, entry, actual_arity)]
        else
          [recognised_diagnostic(path, node, base, kind, entry)]
        end
      end

      def call_argument_count(node)
        return 0 if node.arguments.nil?

        node.arguments.arguments.size
      end

      def recognised_diagnostic(path, node, base, kind, entry)
        diagnostic(
          path, node,
          severity: :info,
          rule: "path-helper",
          message: "#{base}_#{kind} → #{entry.method} #{entry.path}"
        )
      end

      def unknown_route_diagnostic(path, node, base, kind, table)
        suggestion = closest_route(base, table.names)
        hint = suggestion ? " (did you mean `#{suggestion}_#{kind}`?)" : ""
        diagnostic(
          path, node,
          severity: :error,
          rule: "unknown-route",
          message: "no route helper `#{base}_#{kind}`#{hint}"
        )
      end

      def arity_mismatch_diagnostic(path, node, base, kind, entry, actual)
        params = entry.params.map { |p| ":#{p}" }.join(", ")
        plural = entry.arity == 1 ? "argument" : "arguments"
        params_clause = entry.arity.zero? ? "no arguments" : "#{entry.arity} #{plural} (#{params})"
        diagnostic(
          path, node,
          severity: :error,
          rule: "wrong-arity",
          message: "`#{base}_#{kind}` expects #{params_clause}, got #{actual}"
        )
      end

      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: @load_error,
          severity: :warning,
          rule: "load-error"
        )
      end

      def diagnostic(path, node, severity:, rule:, message:)
        location = node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: message,
          severity: severity,
          rule: rule
        )
      end

      def closest_route(name, candidates)
        best = nil
        best_distance = DID_YOU_MEAN_DISTANCE + 1
        candidates.each do |candidate|
          distance = levenshtein(name, candidate)
          if distance < best_distance
            best = candidate
            best_distance = distance
          end
        end
        best
      end

      def levenshtein(a, b) # rubocop:disable Naming/MethodParameterName,Metrics/AbcSize,Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return b.length if a.empty?
        return a.length if b.empty?

        rows = Array.new(a.length + 1) { |i| Array.new(b.length + 1, 0) }
        (0..a.length).each { |i| rows[i][0] = i }
        (0..b.length).each { |j| rows[0][j] = j }

        (1..a.length).each do |i|
          (1..b.length).each do |j|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            rows[i][j] = [
              rows[i - 1][j] + 1,
              rows[i][j - 1] + 1,
              rows[i - 1][j - 1] + cost
            ].min
          end
        end
        rows[a.length][b.length]
      end
    end

    Rigor::Plugin.register(Routes)
  end
end
