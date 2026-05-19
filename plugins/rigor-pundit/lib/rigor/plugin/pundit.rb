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
          "policy_search_paths" => :array,
          "policy_base_classes" => :array
        }
      )

      DEFAULT_POLICY_SEARCH_PATHS = ["app/policies"].freeze
      DEFAULT_POLICY_BASE_CLASSES = %w[ApplicationPolicy].freeze

      producer :policy_index do |_params|
        PolicyDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @policy_search_paths,
          base_classes: @policy_base_classes
        ).discover
      end

      def init(_services)
        @policy_search_paths = Array(config.fetch("policy_search_paths", DEFAULT_POLICY_SEARCH_PATHS)).map(&:to_s)
        @policy_base_classes = Array(config.fetch("policy_base_classes", DEFAULT_POLICY_BASE_CLASSES)).map(&:to_s)
        @policy_index = nil
        @load_error = nil
      end

      def diagnostics_for_file(path:, scope:, root:)
        index = policy_index_or_nil
        return [load_error_diagnostic(path)] if index.nil? && @load_error
        return [] if index.nil? || index.empty?

        Analyzer.diagnose(
          path: path,
          root: root,
          policy_index: index,
          scope: scope
        ).map { |diag| build_diagnostic(diag) }
      end

      private

      def policy_index_or_nil
        return @policy_index if @policy_index

        @policy_index = cache_for(:policy_index, params: {}).call
      rescue StandardError => e
        @load_error = "rigor-pundit: failed to discover policies: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: @load_error,
          severity: :warning,
          rule: "load-error"
        )
      end

      def build_diagnostic(diag)
        Rigor::Analysis::Diagnostic.new(
          path: diag.path, line: diag.line, column: diag.column,
          message: diag.message, severity: diag.severity, rule: diag.rule
        )
      end
    end

    Rigor::Plugin.register(Pundit)
  end
end
