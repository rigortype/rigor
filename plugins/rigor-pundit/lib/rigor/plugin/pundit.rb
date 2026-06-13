# frozen_string_literal: true

require "rigor/plugin"

require_relative "pundit/policy_index"
require_relative "pundit/policy_discoverer"
require_relative "pundit/analyzer"

module Rigor
  module Plugin
    # rigor-pundit — validates Pundit `authorize` /
    # `policy` / `policy_scope` calls against the project's
    # `app/policies/` tree.
    #
    # Tier 3B of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers policy classes by walking
    # `policy_search_paths` and parsing each file with
    # Prism — no `pundit` runtime dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-pundit
    #         config:
    #           policy_search_paths: ["app/policies"]    # default; optional
    #           policy_base_classes: ["ApplicationPolicy"]  # default; optional
    #
    # ## What it checks
    #
    # 1. **Policy class existence** — `authorize(record, ...)`
    #    looks up `<inferred-type>Policy` in the index.
    #    Missing policies emit `unknown-policy-class` with
    #    a did-you-mean suggestion.
    # 2. **Predicate method existence** — for the
    #    `authorize(record, :action)` form, validates that
    #    `<Policy>#<action>?` is defined. Missing methods
    #    emit `unknown-policy-method` listing the known
    #    predicates.
    #
    # ## Limitations (v0.1.0)
    #
    # - Records whose inferred type is NOT a `Nominal[T]`
    #   (untyped local variables, untyped instance
    #   variables) are silently passed through. The plugin
    #   only validates what it can prove from the static
    #   carrier.
    # - The two-argument form
    #   `authorize(record, :action_symbol)` is the only
    #   one validated. The implicit form
    #   `authorize(record)` (which Pundit resolves at
    #   runtime against the controller's current action) is
    #   passed through with the policy-class check only.
    # - Direct-superclass match for `policy_base_classes`.
    #   Indirect inheritance (`AdminPolicy <
    #   ApplicationPolicy`) needs `AdminPolicy` listed in
    #   `policy_base_classes` if subclasses inherit from
    #   it.
    class Pundit < Rigor::Plugin::Base
      manifest(
        id: "pundit",
        version: "0.1.0",
        description: "Validates Pundit policy / authorize calls.",
        config_schema: {
          "policy_search_paths" => { kind: :array, default: ["app/policies"] },
          "policy_base_classes" => { kind: :array, default: %w[ApplicationPolicy] }
        }
      )

      producer :policy_index, watch: -> { [[@policy_search_paths, "**/*.rb"]] } do |_params|
        PolicyDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @policy_search_paths,
          base_classes: @policy_base_classes
        ).discover
      end

      def init(_services)
        @policy_search_paths = Array(config.fetch("policy_search_paths")).map(&:to_s)
        @policy_base_classes = Array(config.fetch("policy_base_classes")).map(&:to_s)
      end

      # File-level only: the load-error emission. The per-call policy
      # validation runs over the engine-owned walk via the node_rule
      # below (ADR-37). The index is lazily loaded + memoised by
      # `producer_value`, so both surfaces share one load.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:policy_index)
        return [load_error_diagnostic(path)] if index.nil? && producer_error(:policy_index)

        []
      end

      node_rule Prism::CallNode do |node, scope, path|
        index = producer_value(:policy_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(
          Analyzer.violations_for(call_node: node, policy_index: index, scope: scope), path: path, node: node
        )
      end

      private

      def load_error_diagnostic(path)
        error = producer_error(:policy_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-pundit: failed to discover policies: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Pundit)
  end
end
