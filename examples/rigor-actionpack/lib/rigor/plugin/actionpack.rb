# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionpack/analyzer"

module Rigor
  module Plugin
    # rigor-actionpack — validates Action Pack DSL calls in
    # controller files.
    #
    # **Phase 4 of the Action Pack plugin family** (route-helper
    # consumption). Reads the `:helper_table` fact published by
    # `rigor-rails-routes` (ADR-9 cross-plugin API) and validates
    # every implicit-self `*_path` / `*_url` call inside files
    # under `controller_search_paths` (default `app/controllers`).
    #
    # Tier 2 of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Phase 1 (strong-parameters → AR column validation), Phase 2
    # (filter chains), and Phase 3 (render targets) ship as
    # separate slices; each phase composes additively under the
    # same plugin id.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-rails-routes      # producer (must come first
    #                                       # in `Configuration#plugins`
    #                                       # ordering, OR the loader's
    #                                       # ADR-9 topo sort handles it)
    #       - gem: rigor-actionpack
    #         config:
    #           controller_search_paths: ["app/controllers"]   # default; optional
    #
    # ## What it checks
    #
    # - **Helper existence** — every `*_path` / `*_url` call
    #   inside a controller file is looked up in the helper
    #   table. Missing entries emit `unknown-helper` with a
    #   `DidYouMean` suggestion drawn from the table.
    # - **Helper arity** — the call's positional-argument count
    #   is matched against the helper's recorded arity (a
    #   trailing `KeywordHashNode` like `users_path(format: :json)`
    #   is excluded; same convention `rigor-rails-routes` uses).
    #   Mismatches emit `wrong-helper-arity`.
    # - **Trace** — recognised helpers also emit a
    #   `helper-call` info diagnostic naming the action and
    #   path, mirroring the trace shape of the upstream plugin.
    #
    # ## Limitations
    #
    # - Implicit-self calls only. `Rails.application.routes.url_helpers.users_path`
    #   and other explicit-receiver shapes are passed through;
    #   they're rare in controller code and the helper table
    #   doesn't include any extra context to validate them.
    # - Files outside `controller_search_paths` are skipped.
    #   The plugin doesn't try to detect "is this a controller?"
    #   by class hierarchy — Phase 1's strong-parameters work
    #   needs that, so it lives there. Phase 4's job is the
    #   single-purpose helper check.
    # - When `rigor-rails-routes` is not installed (or its
    #   helper table is empty), Phase 4 silently degrades to a
    #   no-op. No load-error diagnostic is emitted; the user
    #   gets the "no checks happened" failure mode rather than
    #   a wall of "is this configured right?" warnings.
    class Actionpack < Rigor::Plugin::Base
      manifest(
        id: "actionpack",
        version: "0.1.0",
        description: "Validates Action Pack route-helper calls inside controller files.",
        config_schema: {
          "controller_search_paths" => :array
        },
        consumes: [
          { plugin_id: "rails-routes", name: :helper_table, optional: true }
        ]
      )

      DEFAULT_CONTROLLER_SEARCH_PATHS = ["app/controllers"].freeze

      def init(services)
        @services = services
        @controller_search_paths = Array(
          config.fetch("controller_search_paths", DEFAULT_CONTROLLER_SEARCH_PATHS)
        ).map(&:to_s)
        @helper_table = nil
        @helper_table_resolved = false
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless controller_file?(path)

        table = helper_table
        return [] if table.nil? || table.empty?

        Analyzer.diagnose(path: path, root: root, helper_table: table)
                .map { |diag| build_diagnostic(diag) }
      end

      private

      # Lazily resolves the helper table from the cross-plugin
      # fact store. The cache is per-run because the runner
      # builds a fresh `FactStore` per invocation; memoizing on
      # the plugin instance saves the per-file `read` while
      # still picking up a freshly-published table on the next
      # `bundle exec rigor check` run.
      def helper_table
        return @helper_table if @helper_table_resolved

        @helper_table = @services.fact_store.read(
          plugin_id: "rails-routes", name: :helper_table
        )
        @helper_table_resolved = true
        @helper_table
      end

      def controller_file?(path)
        @controller_search_paths.any? do |root|
          # The runner may pass `path` as either an absolute
          # path (when `paths:` was configured absolutely) or a
          # relative one (when configured relatively). The
          # `controller_search_paths` knob is always project-
          # root-relative. Match the configured root as a
          # /-bracketed substring so both shapes resolve.
          path.include?("/#{root}/") || path.start_with?("#{root}/") || path == root
        end
      end

      def build_diagnostic(diag)
        Rigor::Analysis::Diagnostic.new(
          path: diag.path, line: diag.line, column: diag.column,
          message: diag.message, severity: diag.severity, rule: diag.rule
        )
      end
    end

    Rigor::Plugin.register(Actionpack)
  end
end
