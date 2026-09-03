# frozen_string_literal: true

module Rigor
  module Analysis
    # Issues #665 / #674 / #683 / #686 / #696 — the ONE definition of "an internal failure made this run
    # report less than it should have".
    #
    # Every member of that family shares a defect: the run still exits 0 and its diagnostic list still
    # looks like an answer, so an absence assertion (`not_to include(...)`, `be_empty`, `all(eq(...))`)
    # holds on it and a comparison of two such runs (`baseline == mutant`, `recheck == full_run`) reports
    # "no difference" — because both sides carry the same synthetic row, not because the code agreed. Four
    # separate consumers needed to recognise these shapes, and before this module each recognised them by
    # matching a diagnostic MESSAGE with its own string literal. A fourth copy is what this exists to stop:
    # a reworded message silently disarms whichever copies were not updated, and nothing goes red.
    #
    # ## The three shapes
    #
    # - `:check_rule` — message begins `internal analyzer error`, `rule: nil`. Built by
    #   `Runner#analyze_file_body` / `WorkerSession#analyze_body`'s `rescue StandardError`.
    # - `:plugin` — `severity: :error`, `source_family: :plugin_loader`, `rule: "runtime-error"`. Built by
    #   `Runner#collect_plugin_diagnostics` / `Runner::ProjectPrePasses#invoke_plugin_prepare`.
    # - `:rbs_build` — `rule` in {RBS_BUILD_FAILURE_RULES}. Recorded by `Environment::RbsLoader`'s
    #   env-build and definition-build rescues, surfaced by {Runner::DiagnosticAggregator}.
    #
    # The `:plugin` shape is keyed on the structured `(severity, source_family, rule)` triple rather than on
    # the bare rule name: a plugin is free to define its OWN `"runtime-error"` (or `"load-error"`) under its
    # own `source_family: "plugin.<id>"`, and several specs legitimately assert on one. Only the
    # `:plugin_loader` family paired with `"runtime-error"` is the isolation envelope's own row.
    #
    # ## Why `:rbs_build` is classified but NOT a crash
    #
    # {.analyzer_failed?} — the predicate every consumer arms today — answers true for `:check_rule` and
    # `:plugin` only. Those two mean *the analysis did not run*: the rescue discards every other diagnostic
    # the file would have produced, so what comes back is not a weaker answer, it is no answer. `:rbs_build`
    # is a different condition: the analysis ran to completion and every rule fired, over a type universe
    # missing one class (`rbs.coverage.definition-build-failed`) or all of them
    # (`rbs.coverage.environment-build-failed`). That is a degradation the user causes, that the diagnostic
    # itself reports, and that a project can sit on for a release while it fixes its `sig/` — treating it as
    # a crash would make a legitimate, self-reported state fail every consumer that guards against a bug.
    # It is classified here anyway, and deliberately: the next consumer that needs to tell a degraded run
    # from a healthy one extends this table instead of adding the fourth string match.
    module CrashSignature
      # The `rescue StandardError` in `Runner#analyze_file_body` / `WorkerSession#analyze_body` folds a
      # raising check rule (or a plugin's node-rule contribution) into ONE diagnostic per file with this
      # message prefix. Matched on the prefix alone, exactly as the pre-#696 guards did: adding a `rule.nil?`
      # conjunct would NARROW the match, and the whole point of a guard against a bug is that it stays armed
      # when the shape shifts.
      CHECK_RULE_MESSAGE_PREFIX = "internal analyzer error"

      PLUGIN_SOURCE_FAMILY = :plugin_loader
      PLUGIN_RULE = "runtime-error"

      # The `rbs.coverage.*` rules that mean declared types went missing from this run — an env-wide
      # collapse and its per-class sibling (#696). Ordered widest consequence last, the way the two rows sit
      # in `docs/type-specification/diagnostic-policy.md`.
      RBS_BUILD_FAILURE_RULES = %w[
        rbs.coverage.definition-build-failed
        rbs.coverage.environment-build-failed
      ].freeze

      # The reasons that mean NO real diagnostics were produced. See the class doc for why `:rbs_build` is
      # not one of them.
      ANALYZER_FAILED_REASONS = %i[check_rule plugin].freeze

      module_function

      # @param diagnostic [Rigor::Analysis::Diagnostic]
      # @return [Symbol, nil] `:check_rule`, `:plugin`, `:rbs_build`, or nil for an ordinary diagnostic.
      def reason(diagnostic)
        return :check_rule if diagnostic.message.to_s.start_with?(CHECK_RULE_MESSAGE_PREFIX)
        return :plugin if plugin_isolation_row?(diagnostic)
        return :rbs_build if RBS_BUILD_FAILURE_RULES.include?(diagnostic.rule)

        nil
      end

      # True when `diagnostic` is one of the two rescue-produced rows that mean the analysis never ran.
      #
      # @param diagnostic [Rigor::Analysis::Diagnostic]
      def analyzer_failed?(diagnostic)
        ANALYZER_FAILED_REASONS.include?(reason(diagnostic))
      end

      # A one-line "<reason> at <path>:<line>: <message>" for a failure message, so whoever reads the raise
      # sees which shape fired and where without re-deriving it.
      #
      # @param diagnostic [Rigor::Analysis::Diagnostic]
      # @return [String]
      def describe(diagnostic)
        "#{reason(diagnostic) || :unknown} at #{diagnostic.path}:#{diagnostic.line}: #{diagnostic.message}"
      end

      def plugin_isolation_row?(diagnostic)
        diagnostic.severity == :error &&
          diagnostic.source_family == PLUGIN_SOURCE_FAMILY &&
          diagnostic.rule == PLUGIN_RULE
      end
      private_class_method :plugin_isolation_row?
    end
  end
end
