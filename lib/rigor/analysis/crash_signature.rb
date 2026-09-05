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
    # ## Only ONE shape discards a file's analysis
    #
    # {.discards_file_analysis?} answers true for `:check_rule` alone, and the distinction is not pedantry —
    # it decides whether a consumer may still read the run's diagnostics.
    #
    # - `:check_rule` — `Runner#analyze_file_body` rescues around the WHOLE per-file body, so what comes
    #   back is `[crash_row]` and every diagnostic that file would have produced is gone. Nothing is left to
    #   read.
    # - `:plugin` — `collect_plugin_diagnostics` replaces only the raising PLUGIN's contribution;
    #   `CheckRules.diagnose` has already returned, and `invoke_plugin_prepare` adds one row at `.rigor.yml`
    #   and lets the run proceed. The builtin rules ran, and their diagnostics are all still there. A
    #   consumer that refuses the whole run over this throws away a real measurement — and because the
    #   prepare row is appended to every sequential run, it would refuse every run for the life of the
    #   process.
    # - `:rbs_build` — the analysis ran to completion and every rule fired, over a type universe missing one
    #   class (`rbs.coverage.definition-build-failed`) or all of them
    #   (`rbs.coverage.environment-build-failed`). A degradation the user causes and the diagnostic itself
    #   reports; a project can sit on it for a release while it fixes its `sig/`.
    #
    # The two consumer tiers therefore differ on purpose. The ADR-69 kill oracles arm `:check_rule` only:
    # refusing a run they could still have measured is the same "manufactures work" error as scoring an
    # unmeasured mutant a survivor, pointed the other way (issue #686 review). The spec harness additionally
    # arms `:plugin`, which is suite POLICY rather than a claim about the diagnostics — no spec has a reason
    # to want a plugin crashing under it, and `allow_plugin_crash:` is the opt-out for the handful whose
    # subject IS the isolation envelope.
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

      # The one reason that means a file's whole diagnostic list was replaced by a crash row. `:plugin` and
      # `:rbs_build` both leave a readable run behind — see the class doc.
      DISCARDS_FILE_ANALYSIS_REASON = :check_rule

      module_function

      # @return [Symbol, nil] `:check_rule`, `:plugin`, `:rbs_build`, or nil for an ordinary diagnostic.
      def reason(diagnostic)
        return :check_rule if diagnostic.message.to_s.start_with?(CHECK_RULE_MESSAGE_PREFIX)
        return :plugin if plugin_isolation_row?(diagnostic)
        return :rbs_build if RBS_BUILD_FAILURE_RULES.include?(diagnostic.rule)

        nil
      end

      # True when `diagnostic` is the rescue row that REPLACED a file's analysis — the only shape after which
      # the run's diagnostics say nothing about the code. NOT a general "something went wrong" predicate; see
      # the class doc for why `:plugin` and `:rbs_build` are excluded.
      def discards_file_analysis?(diagnostic)
        reason(diagnostic) == DISCARDS_FILE_ANALYSIS_REASON
      end

      # A one-line "<reason> at <path>:<line>: <message>" for a failure message, so whoever reads the raise
      # sees which shape fired and where without re-deriving it.
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
