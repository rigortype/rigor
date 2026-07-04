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
    #   through `#producer_value` (ADR-60 WD4), which runs the
    #   `:route_table` producer via `#cache_for` and caches the result
    #   (nil included) on the instance. The producer block reads the
    #   file through `IoBoundary#read_file` (so `TrustPolicy`
    #   validates the path AND the boundary records a `:digest`
    #   `FileEntry`); ADR-60 WD3 record-and-validate captures that
    #   digest into the dependency descriptor after the block runs, so
    #   subsequent runs hit the cache when `routes.yml` is unchanged.
    #   A malformed / missing / denied file is rescued into
    #   `#producer_error`, degrading the plugin to a single load-error
    #   warning.
    # - The `Walker` finds every `*_path` / `*_url` implicit-
    #   receiver call. Each is checked against the table for
    #   existence and arity (= number of `:foo` placeholders in
    #   the path template). Unknown helpers carry a "did you
    #   mean" suggestion via `Plugin::Base.suggest`
    #   (`DidYouMean::SpellChecker`).
    #
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
          "routes_file" => { kind: :string, default: "config/routes.yml" }
        }
      )

      # Cached producer (slice 6-A). The block runs through
      # `instance_exec` so `@routes_file`, `io_boundary`, and private
      # helpers are all in scope. Under ADR-60 WD3 record-and-validate,
      # the `io_boundary.read_file` BELOW runs inside the block, and
      # its `FileEntry` digest is captured into the dependency
      # descriptor *after* the block runs — so editing `routes.yml`
      # invalidates the cache with nothing to wire up by hand. (A
      # producer that globbed a directory would add `watch:` to cover
      # file additions; this one reads a single named file.)
      producer :route_table do |_params|
        contents = io_boundary.read_file(@routes_file)
        RouteTable.parse(contents)
      end

      def init(_services)
        @routes_file = config["routes_file"]
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        # ADR-60 WD4 — `#producer_value` runs the `:route_table` producer
        # through `#cache_for` and memoises the result (nil included) on
        # this instance. A `StandardError` the producer raises (missing /
        # malformed / access-denied `routes.yml`) is rescued into
        # `#producer_error`, degrading the plugin to a single load-error
        # warning rather than aborting the run. ADR-60 WD3
        # record-and-validate captures the in-block `routes.yml` read into
        # the dependency descriptor, so the cache invalidates on edit with
        # nothing to wire up by hand.
        table = producer_value(:route_table)
        return [load_error_diagnostic(path)] if table.nil?
        return [] if table.empty?

        diagnostics = []
        Walker.each_helper_call(root) do |node, base, kind|
          diagnostics.concat(diagnostics_for_call(path, node, base, kind, table))
        end
        diagnostics
      end

      private

      def diagnostics_for_call(path, node, base, kind, table)
        entry = table.find(base)
        return [unknown_route_diagnostic(path, node, base, kind, table)] unless entry

        actual_arity = call_argument_count(node)
        if actual_arity == entry.arity
          [recognised_diagnostic(path, node, base, kind, entry)]
        else
          [arity_mismatch_diagnostic(path, node, base, kind, entry, actual_arity)]
        end
      end

      def call_argument_count(node)
        return 0 if node.arguments.nil?

        node.arguments.arguments.size
      end

      def recognised_diagnostic(path, node, base, kind, entry)
        diagnostic(
          node, path: path,
                severity: :info,
                rule: "path-helper",
                message: "#{base}_#{kind} → #{entry.method} #{entry.path}"
        )
      end

      def unknown_route_diagnostic(path, node, base, kind, table)
        # ADR-60 WD4 — the shared `DidYouMean::SpellChecker` helper the
        # engine also uses for `NoMethodError` hints, replacing the
        # hand-rolled Levenshtein table this example used to carry.
        suggestion = self.class.suggest(base, table.names)
        hint = suggestion ? " (did you mean `#{suggestion}_#{kind}`?)" : ""
        diagnostic(
          node, path: path,
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
          node, path: path,
                severity: :error,
                rule: "wrong-arity",
                message: "`#{base}_#{kind}` expects #{params_clause}, got #{actual}"
        )
      end

      # File-level (line 1) load-error warning. There is no call node to
      # position at, so this is one of the few places a plugin constructs
      # a `Diagnostic` directly rather than through `#diagnostic`. The
      # message is tailored to the `StandardError` class `#producer_value`
      # rescued into `#producer_error(:route_table)`.
      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: load_error_message,
          severity: :warning,
          rule: "load-error"
        )
      end

      def load_error_message
        case (error = producer_error(:route_table))
        when Plugin::AccessDeniedError
          "rigor-routes: #{error.message}"
        when Errno::ENOENT
          "rigor-routes: routes file `#{@routes_file}` not found; helper checks skipped"
        when ArgumentError, Psych::SyntaxError
          "rigor-routes: failed to parse `#{@routes_file}`: #{error.message}"
        else
          "rigor-routes: could not load `#{@routes_file}`: #{error&.message}"
        end
      end
    end

    Rigor::Plugin.register(Routes)
  end
end
