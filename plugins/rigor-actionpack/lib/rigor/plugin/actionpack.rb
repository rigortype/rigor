# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionpack/analyzer"
require_relative "actionpack/controller_discoverer"
require_relative "actionpack/controller_index"

module Rigor
  module Plugin
    # rigor-actionpack — validates Action Pack DSL calls in controller files.
    #
    # **Phase 4 of the Action Pack plugin family** (route-helper consumption). Reads the `:helper_table`
    # fact published by `rigor-rails-routes` (ADR-9 cross-plugin API) and validates every implicit-self
    # `*_path` / `*_url` call inside files under `controller_search_paths` (default `app/controllers`).
    #
    # Tier 2 of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Phase 1 (strong-parameters → AR column validation), Phase 2 (filter chains), and Phase 3 (render
    # targets) ship as separate slices; each phase composes additively under the same plugin id.
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
    # - **Helper existence** — every `*_path` / `*_url` call inside a controller file is looked up in
    #   the helper table. Missing entries emit `unknown-helper` with a `DidYouMean` suggestion drawn
    #   from the table.
    # - **Helper arity** — the call's positional-argument count is matched against the helper's
    #   recorded arity (a trailing `KeywordHashNode` like `users_path(format: :json)` is excluded; same
    #   convention `rigor-rails-routes` uses). Mismatches emit `wrong-helper-arity`.
    # - **Trace** — recognised helpers also emit a `helper-call` info diagnostic naming the action and
    #   path, mirroring the trace shape of the upstream plugin.
    #
    # ## Limitations
    #
    # - Implicit-self calls only. `Rails.application.routes.url_helpers.users_path` and other
    #   explicit-receiver shapes are passed through; they're rare in controller code and the helper
    #   table doesn't include any extra context to validate them.
    # - Files outside `controller_search_paths` are skipped. The plugin doesn't try to detect "is this
    #   a controller?" by class hierarchy — Phase 1's strong-parameters work needs that, so it lives
    #   there. Phase 4's job is the single-purpose helper check.
    # - When `rigor-rails-routes` is not installed (or its helper table is empty), Phase 4 silently
    #   degrades to a no-op. No load-error diagnostic is emitted; the user gets the "no checks
    #   happened" failure mode rather than a wall of "is this configured right?" warnings.
    class Actionpack < Rigor::Plugin::Base
      manifest(
        id: "actionpack",
        # ADR-37: the four phases (helper / filter / render / strong-params) run per-call over the
        # engine-owned walk; the enclosing controller is read from the node-rule `NodeContext`
        # ancestors. Nested-module qualification is preserved — `module Admin; class
        # DomainBlocksController` resolves as `Admin::DomainBlocksController` (matching the
        # `ControllerDiscoverer`), so render paths and filter-chain validation on nested controllers are
        # correct.
        version: "0.9.0",
        description: "Validates Action Pack route-helper calls and filter chains inside controllers, and types the request-context readers (`params` / `session` / `request`).",
        config_schema: {
          "controller_search_paths" => { kind: :array, default: ["app/controllers"] },
          "view_search_paths" => { kind: :array, default: ["app/views"] }
        },
        consumes: [
          { plugin_id: "rails-routes", name: :helper_table, optional: true },
          { plugin_id: "activerecord", name: :model_index, optional: true }
        ]
      )

      # Phase 2 cached producer — the controller index built from `controller_search_paths`. `watch:`
      # (ADR-60 WD3) covers every `.rb` file under those roots so the cache invalidates when a
      # controller is added, removed, or edited; the discoverer's in-block `io_boundary` reads are
      # captured into the dependency descriptor too, so no explicit priming is needed.
      producer :controller_index, watch: -> { [[@controller_search_paths, "**/*.rb"]] } do |_params|
        ControllerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @controller_search_paths
        ).discover
      end

      def init(_services)
        @controller_search_paths = Array(config.fetch("controller_search_paths")).map(&:to_s)
        @view_search_paths = Array(config.fetch("view_search_paths")).map(&:to_s)
      end

      # ADR-37 — the four Action Pack phases run per-call over the engine-owned walk. Each rule gates on
      # `controller_file?(path)` (the plugin only validates files under `controller_search_paths`,
      # exactly as the former `diagnostics_for_file` top-level guard did), then delegates to a per-node
      # `Analyzer.*_violations_for` and positions each location-free `Violation` with `Base#diagnostic`.
      # The filter / render phases read the enclosing controller from the node-rule `NodeContext`
      # ancestors (its fifth block argument).

      # Phase 4 — route-helper consumption. `:helper_table` is rigor-rails-routes's published fact
      # (ADR-9), read lazily via `read_fact`.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        table = read_fact(plugin_id: "rails-routes", name: :helper_table)
        next [] if table.nil? || table.empty?

        diagnostics_for(Analyzer.helper_violations_for(call_node: node, helper_table: table), path: path, node: node)
      end

      # Phase 2 — filter-chain validation. Skips silently when the controller index is absent or
      # doesn't recognise the enclosing class.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        index = producer_value(:controller_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(
          Analyzer.filter_violations_for(call_node: node, ancestors: context.ancestors, controller_index: index),
          path: path, node: node
        )
      end

      # Phase 3 — render-target validation against the configured `view_search_paths`. Recognised purely
      # from the call site + the enclosing controller name, so no per-controller pre-discovery is
      # needed; the controller index is consulted only to suppress gem-shipped-view false positives.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        diagnostics_for(
          Analyzer.render_violations_for(
            call_node: node, ancestors: context.ancestors, path: path,
            view_search_roots: @view_search_paths, controller_index: producer_value(:controller_index)
          ),
          path: path, node: node
        )
      end

      # Phase 1 — strong-parameter validation. Reads the `:model_index` fact from the cross-plugin fact
      # store (published by rigor-activerecord) and validates every `params.require(:user).permit(:name,
      # :email)` chain against the User model's column list.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        index = read_fact(plugin_id: "activerecord", name: :model_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.permit_violations_for(call_node: node, model_index: index), path: path, node: node)
      end

      # Phase 5 (2026-07-04) — type the implicit-self request-context readers (`params`, `session`,
      # `request`, `flash`, `cookies`) inside controllers. The typing-obstacle probe
      # (docs/notes/20260704-rails-coverage-onboarding-carrier-trap.md, obstacle O3) found `params`
      # typing to `Dynamic[top]` the single largest protection-coverage hole on real Rails apps:
      # `params[:x]` is the #1 dispatch cluster (redmine app+lib: `[]` 2378 sites) and `session[:x] =` a
      # large share of the `[]=` cluster, all unprotected because the receiver is Dynamic.
      #
      # Each returns a bare nominal with NO bundled RBS on purpose. That makes the reader a *concrete*
      # receiver (so `coverage --protection` counts the site as protected and the dispatch resolves
      # against a named class) while its method surface stays engine-lenient — Rigor does not fire
      # `undefined-method` on a class it has no RBS for, so `params.require(...).permit(...)`,
      # `session.delete(:x)`, `request.xhr?`, and every other method on these stay FP-safe. Shipping a
      # partial RBS would re-introduce the carrier-additivity trap (a declared class drops every member
      # the RBS omits → false `undefined-method`). ADR-5: this types the container, never the caller's
      # argument, so the values stay lenient.
      REQUEST_CONTEXT_READER_TYPES = {
        params: "ActionController::Parameters",
        session: "ActionDispatch::Request::Session",
        request: "ActionDispatch::Request",
        flash: "ActionDispatch::Flash::FlashHash",
        cookies: "ActionDispatch::Cookies::CookieJar"
      }.freeze

      dynamic_return methods: REQUEST_CONTEXT_READER_TYPES.keys do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver.nil?   # the implicit-self reader
        next nil unless call_node.arguments.nil?  # `params`, not `params(x)`
        next nil unless controller_scope?(scope)

        class_name = REQUEST_CONTEXT_READER_TYPES[call_node.name]
        next nil if class_name.nil?

        Rigor::Type::Combinator.nominal_of(class_name)
      end

      private

      # True when the current `self` is a controller — the enclosing class is one the discoverer
      # indexed, or its name follows the Rails `*Controller` convention (covering controllers outside
      # `controller_search_paths`, e.g. one shipped by an engine). Typing `params` is precision-additive,
      # so the name-convention fallback is FP-safe.
      def controller_scope?(scope)
        self_type = scope&.self_type
        return false unless self_type.respond_to?(:class_name)

        name = self_type.class_name
        return false if name.nil?

        index = producer_value(:controller_index)
        return true if index && (index.find(name) || index.find("::#{name}"))

        name.end_with?("Controller")
      end

      def controller_file?(path)
        @controller_search_paths.any? do |root|
          # The runner may pass `path` as either an absolute path (when `paths:` was configured
          # absolutely) or a relative one (when configured relatively). The `controller_search_paths`
          # knob is always project-root-relative. Match the configured root as a /-bracketed substring
          # so both shapes resolve.
          path.include?("/#{root}/") || path.start_with?("#{root}/") || path == root
        end
      end
    end

    Rigor::Plugin.register(Actionpack)
  end
end
