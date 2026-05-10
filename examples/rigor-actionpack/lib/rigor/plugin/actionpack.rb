# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionpack/analyzer"
require_relative "actionpack/controller_discoverer"
require_relative "actionpack/controller_index"

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
        description: "Validates Action Pack route-helper calls and filter chains inside controllers.",
        config_schema: {
          "controller_search_paths" => :array,
          "view_search_paths" => :array
        },
        consumes: [
          { plugin_id: "rails-routes", name: :helper_table, optional: true }
        ]
      )

      DEFAULT_CONTROLLER_SEARCH_PATHS = ["app/controllers"].freeze
      DEFAULT_VIEW_SEARCH_PATHS = ["app/views"].freeze

      # Phase 2 cached producer — the controller index built
      # from `controller_search_paths`. The IoBoundary records
      # a `FileEntry` digest for every file the discoverer
      # reads, so the cache invalidates when any controller
      # file changes.
      producer :controller_index do |_params|
        ControllerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @controller_search_paths
        ).discover
      end

      def init(services)
        @services = services
        @controller_search_paths = Array(
          config.fetch("controller_search_paths", DEFAULT_CONTROLLER_SEARCH_PATHS)
        ).map(&:to_s)
        @view_search_paths = Array(
          config.fetch("view_search_paths", DEFAULT_VIEW_SEARCH_PATHS)
        ).map(&:to_s)
        @helper_table = nil
        @helper_table_resolved = false
        @controller_index = nil
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless controller_file?(path)

        helper_diagnostics(path, root) +
          filter_diagnostics(path, root) +
          render_diagnostics(path, root)
      end

      private

      def helper_diagnostics(path, root)
        table = helper_table
        return [] if table.nil? || table.empty?

        Analyzer.diagnose(path: path, root: root, helper_table: table)
                .map { |diag| build_diagnostic(diag) }
      end

      # Phase 2 — runs the filter-chain validator over the
      # controller's class body using the cached
      # {ControllerIndex}. Skips silently when the index is
      # absent or doesn't recognise the file's top-level class.
      def filter_diagnostics(path, root)
        index = controller_index_or_nil
        return [] if index.nil? || index.empty?

        Analyzer.diagnose_filters(path: path, root: root, controller_index: index)
                .map { |diag| build_diagnostic(diag) }
      end

      # Phase 3 — runs the render-target validator against the
      # configured `view_search_paths`. Always invoked
      # regardless of whether the controller is in the index;
      # render shapes are recognised purely from the call site
      # + class name, no per-controller pre-discovery needed.
      def render_diagnostics(path, root)
        Analyzer.diagnose_renders(path: path, root: root, view_search_roots: @view_search_paths)
                .map { |diag| build_diagnostic(diag) }
      end

      def controller_index_or_nil
        return @controller_index if @controller_index

        # Read project source first so the IoBoundary's
        # FileEntry digests get captured into the descriptor
        # before `cache_for` snapshots it (mirrors
        # rigor-rails-routes / rigor-pundit's pattern).
        prime_io_boundary_for_index
        @controller_index = cache_for(:controller_index, params: {}).call
      rescue StandardError
        nil
      end

      def prime_io_boundary_for_index
        @controller_search_paths.each do |root|
          absolute = File.expand_path(root)
          next unless File.directory?(absolute)

          Dir.glob(File.join(absolute, "**", "*.rb")).each do |path|
            io_boundary.read_file(path)
          rescue Plugin::AccessDeniedError, Errno::ENOENT
            nil
          end
        end
      end

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
