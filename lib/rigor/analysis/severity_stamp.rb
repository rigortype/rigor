# frozen_string_literal: true

require_relative "diagnostic"
require_relative "../configuration/severity_profile"

module Rigor
  module Analysis
    # ADR-8 § "Severity profile" — re-stamps each diagnostic's severity from the configured profile + per-rule
    # overrides and drops any diagnostic resolving to `:off`. Rules emit with their authored severity; the
    # profile is the final filter.
    #
    # Extracted (ADR-87 WD4) so the miss path ({Runner::DiagnosticAggregator}) and the boot-slimming hit path
    # ({RunCacheProbe}, which never loads the aggregator) apply the IDENTICAL final filter — a warm HIT's
    # served diagnostics are byte-identical to what a full run would print.
    module SeverityStamp
      module_function

      def apply(diagnostics, configuration)
        diagnostics.filter_map { |diagnostic| stamp(diagnostic, configuration) }
      end

      def stamp(diagnostic, configuration)
        return diagnostic if diagnostic.rule.nil?

        resolved = Configuration::SeverityProfile.resolve(
          rule: diagnostic.rule,
          authored_severity: diagnostic.severity,
          profile: configuration.severity_profile,
          overrides: configuration.severity_overrides,
          bleeding_edge_overrides: configuration.bleeding_edge_severity_overrides
        )
        return nil if resolved == :off
        return diagnostic if resolved == diagnostic.severity

        Diagnostic.new(
          path: diagnostic.path, line: diagnostic.line, column: diagnostic.column,
          message: diagnostic.message, severity: resolved, rule: diagnostic.rule,
          source_family: diagnostic.source_family, receiver_type: diagnostic.receiver_type,
          method_name: diagnostic.method_name, project_definition_site: diagnostic.project_definition_site
        )
      end
    end
  end
end
