# frozen_string_literal: true

require_relative "check_rules/rule_ids"
require_relative "diagnostic"
require_relative "../configuration/severity_profile"

module Rigor
  module Analysis
    # ADR-8 § "Severity profile" — re-stamps each diagnostic's severity from the configured profile + per-rule
    # overrides and drops any diagnostic resolving to `:off`. Rules emit with their authored severity; the
    # profile is the final filter.
    #
    # Issue #1895 — the `.rigor.yml` `disable:` list is applied here too, ahead of the profile, with the same
    # token expansion and match per-file analysis uses ({CheckRules.config_disabled?}). Per-file rows were
    # already filtered where they were produced; the run-level rows (plugin load / prepare, dependency-source,
    # `rbs.coverage.*`, pool-degraded, ...) are assembled outside any per-file filter, and this is the one
    # stamp every run shape (sequential, pool, `--incremental`, a warm cache hit) passes its stream through.
    #
    # Extracted (ADR-87 WD4) so the miss path ({Runner::DiagnosticAggregator}) and the boot-slimming hit path
    # ({RunCacheProbe}, which never loads the aggregator) apply the IDENTICAL final filter — a warm HIT's
    # served diagnostics are byte-identical to what a full run would print.
    module SeverityStamp
      module_function

      def apply(diagnostics, configuration)
        disabled = CheckRules.expand_rule_tokens(configuration.disabled_rules)
        diagnostics.filter_map do |diagnostic|
          next nil if CheckRules.config_disabled?(diagnostic.rule, disabled)

          stamp(diagnostic, configuration)
        end
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
