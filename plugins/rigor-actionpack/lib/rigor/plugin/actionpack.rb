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
        # Bumped 2026-06-02 — ADR-37 node_rule migration. The four
        # phases (helper / filter / render / strong-params) now run
        # per-call over the engine-owned walk instead of the
        # hand-rolled `diagnostics_for_file` traversal; the enclosing
        # controller is read from the node-rule `NodeContext` ancestors.
        # Nested-module qualification is preserved — a
        # `module Admin; class DomainBlocksController; end` file still
        # resolves as `Admin::DomainBlocksController` (matching the
        # `ControllerDiscoverer`), so render paths
        # (`admin/domain_blocks/new`) and filter-chain validation on
        # nested controllers are unchanged.
        version: "0.8.0",
        description: "Validates Action Pack route-helper calls and filter chains inside controllers.",
        config_schema: {
          "controller_search_paths" => :array,
          "view_search_paths" => :array
        },
        consumes: [
          { plugin_id: "rails-routes", name: :helper_table, optional: true },
          { plugin_id: "activerecord", name: :model_index, optional: true }
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
        @model_index_value = nil
        @model_index_resolved = false
      end

      # ADR-37 — the four Action Pack phases run per-call over the
      # engine-owned walk. Each rule gates on `controller_file?(path)` (the
      # plugin only validates files under `controller_search_paths`,
      # exactly as the former `diagnostics_for_file` top-level guard did),
      # then delegates to a per-node `Analyzer.*_violations_for` and
      # positions each location-free `Violation` with `Base#diagnostic`.
      # The filter / render phases read the enclosing controller from the
      # node-rule `NodeContext` ancestors (its fifth block argument).

      # Phase 4 — route-helper consumption.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        table = helper_table
        next [] if table.nil? || table.empty?

        Analyzer.helper_violations_for(call_node: node, helper_table: table).map do |v|
          diagnostic(node, path: path, location: v.location, message: v.message, severity: v.severity, rule: v.rule)
        end
      end

      # Phase 2 — filter-chain validation. Skips silently when the
      # controller index is absent or doesn't recognise the enclosing
      # class.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        index = controller_index_or_nil
        next [] if index.nil? || index.empty?

        Analyzer.filter_violations_for(call_node: node, ancestors: context.ancestors, controller_index: index).map do |v|
          diagnostic(node, path: path, location: v.location, message: v.message, severity: v.severity, rule: v.rule)
        end
      end

      # Phase 3 — render-target validation against the configured
      # `view_search_paths`. Recognised purely from the call site + the
      # enclosing controller name, so no per-controller pre-discovery is
      # needed; the controller index is consulted only to suppress
      # gem-shipped-view false positives.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        Analyzer.render_violations_for(
          call_node: node, ancestors: context.ancestors, path: path,
          view_search_roots: @view_search_paths, controller_index: controller_index_or_nil
        ).map do |v|
          diagnostic(node, path: path, location: v.location, message: v.message, severity: v.severity, rule: v.rule)
        end
      end

      # Phase 1 — strong-parameter validation. Reads the `:model_index`
      # fact from the cross-plugin fact store (published by
      # rigor-activerecord) and validates every
      # `params.require(:user).permit(:name, :email)` chain against the
      # User model's column list.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        index = model_index
        next [] if index.nil? || index.empty?

        Analyzer.permit_violations_for(call_node: node, model_index: index).map do |v|
          diagnostic(node, path: path, location: v.location, message: v.message, severity: v.severity, rule: v.rule)
        end
      end

      private

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

      # Phase 1 — lazily reads the cross-plugin :model_index
      # fact from rigor-activerecord. The cache is per-run
      # because the runner builds a fresh FactStore per
      # invocation; memoizing on the plugin instance saves the
      # per-file read while still picking up a freshly
      # published index on the next `bundle exec rigor check`.
      def model_index
        return @model_index_value if @model_index_resolved

        @model_index_value = @services.fact_store.read(
          plugin_id: "activerecord", name: :model_index
        )
        @model_index_resolved = true
        @model_index_value
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
    end

    Rigor::Plugin.register(Actionpack)
  end
end
