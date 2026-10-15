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
    # token expansion and match per-file analysis uses ({CheckRules.config_disabled?}), but only to a built-in
    # check-rule row (see {.check_rule_row?}): the rows the diagnostic policy already says `disable:` reaches. Most
    # are filtered where they were produced; this catches the ones that are not (the `effect.annotations-unchecked`
    # residual under `disable: [all]`) on every run shape (sequential, pool, `--incremental`, a warm cache hit).
    # The run-level rows outside the check-rule catalogue (`rbs.coverage.*`, `dynamic.dependency-source.*`, the
    # plugin loader, `plugin_trust.*`, `plugin.<id>.*`) keep answering to `severity_overrides:` only.
    #
    # Extracted (ADR-87 WD4) so the miss path ({Runner::DiagnosticAggregator}) and the boot-slimming hit path
    # ({RunCacheProbe}, which never loads the aggregator) apply the IDENTICAL final filter — a warm HIT's
    # served diagnostics are byte-identical to what a full run would print.
    module SeverityStamp
      module_function

      CHECK_RULES = CheckRules::ALL_RULES.to_set.freeze
      private_constant :CHECK_RULES

      def apply(diagnostics, configuration)
        disabled = CheckRules.expand_rule_tokens(configuration.disabled_rules)
        diagnostics.filter_map do |diagnostic|
          next nil if check_rule_row?(diagnostic) && CheckRules.config_disabled?(diagnostic.rule, disabled)

          stamp(diagnostic, configuration)
        end
      end

      # A built-in check-rule row: its id is in the CheckRules catalogue and no plugin emitted it. Only these answer
      # to `disable:` here; whether the other rule-bearing rows should (and by bare or qualified id) is open.
      def check_rule_row?(diagnostic)
        diagnostic.source_family == Diagnostic::DEFAULT_SOURCE_FAMILY && CHECK_RULES.include?(diagnostic.rule)
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
