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
    #   class (`rbs.coverage.definition-build-failed`), all of them
    #   (`rbs.coverage.environment-build-failed`), or only the implicit HKT registrations `type` aliases
    #   would have contributed (`rbs.coverage.hkt-scan-failed`, issue #784). The first two are degradations
    #   the user causes and the diagnostic itself reports; a project can sit on one for a release while it
    #   fixes its `sig/`. The third is NOT the user's: post-#783 the scan raising is an analyzer defect. It
    #   still belongs here rather than under `:check_rule`, because the question this classification
    #   answers is "may a consumer still read the run's diagnostics?" — and it may: every rule fired. What
    #   differs is whether the run is a valid measurement OF RIGOR, which is {.analyzer_defect?}'s question.
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

      # The `rbs.coverage.*` rules that mean declared types went missing from this run — the implicit-HKT
      # scan over `type` aliases (#784), a per-class definition build (#696), and the env-wide collapse.
      # Ordered widest consequence last, the way the rows sit in `docs/type-specification/diagnostic-policy.md`.
      RBS_BUILD_FAILURE_RULES = %w[
        rbs.coverage.hkt-scan-failed
        rbs.coverage.definition-build-failed
        rbs.coverage.environment-build-failed
      ].freeze

      # The one reason that means a file's whole diagnostic list was replaced by a crash row. `:plugin` and
      # `:rbs_build` both leave a readable run behind — see the class doc.
      DISCARDS_FILE_ANALYSIS_REASON = :check_rule

      # The `:rbs_build` rules whose cause is Rigor, not the user's `sig/` (issue #784). Readable for the
      # user — every rule fired — but NOT a valid measurement of Rigor itself, so a harness that scores
      # Rigor's behaviour should treat one of these as a crash finding the way it treats `:check_rule`, or
      # a mutant that re-breaks the HKT scan (#776 was one) scores as a measurement over a silently degraded
      # universe. What consults it today: `tool/mutation`'s fuzz crash detector — on the severity-resolved
      # stream, so a `severity_overrides: rbs: off` hides the row from it. What does NOT yet: the ADR-69
      # kill oracle (`Protection::AnalysisGuard` reads `Result#crashed?`, which excludes every
      # `:rbs_build` row), and both harnesses still reuse one Environment across mutants, which memoises
      # the degraded registry after the first defect. Arming the oracle, inspecting the pre-severity row,
      # and resetting the Environment are issue #790.
      ANALYZER_DEFECT_RULES = %w[
        rbs.coverage.hkt-scan-failed
      ].freeze

      module_function

      # The message `Runner#analyze_file_body` / `WorkerSession#analyze_body` fold a raised `StandardError`
      # into. Built here, not at either rescue site, so the two twins cannot drift (issue #665) — and so
      # the appended crash frame is derived identically on the sequential and pooled paths. Keeps the
      # {CHECK_RULE_MESSAGE_PREFIX} prefix every consumer matches on; the frame is a trailing hint.
      #
      # @param error [StandardError]
      # @return [String]
      def check_rule_message(error)
        base = "#{CHECK_RULE_MESSAGE_PREFIX}: #{error.class}: #{error.message}"
        frame = crash_frame(error)
        frame ? "#{base} (#{frame})" : base
      end

      # The first `lib/rigor/` backtrace frame — the raise site, path made repo-relative so it reads the
      # same whether Rigor runs from a checkout or an installed gem. A LOCATION, not an attribution: a
      # bundled or third-party plugin also lives under `lib/rigor/<plugin>/`, so a frame here says where
      # the raise was, never whose defect it is. Falls back to the raw top frame when the crash is entirely
      # inside a dependency, and to nil when there is no backtrace at all.
      #
      # @param error [Exception]
      # @return [String, nil]
      def crash_frame(error)
        frames = error.backtrace
        return nil if frames.nil? || frames.empty?

        relativize_frame(frames.find { |f| f.include?("/lib/rigor/") } || frames.first)
      end

      # The repo-relative half of {.crash_frame}, pulled out on its own so a second caller — the #784
      # `rbs.coverage.hkt-scan-failed` diagnostic, which stores its raw frame across a `Marshal` boundary
      # (the fork pool) rather than deriving it fresh from a live `Exception` — can relativize the frame it
      # already has without re-deriving `.crash_frame`'s "which frame" choice. Nil-safe, and a no-op (`sub`
      # never matches) on a frame with no `lib/rigor/` segment at all.
      #
      # @param frame [String, nil]
      # @return [String, nil]
      def relativize_frame(frame)
        frame&.sub(%r{\A.*/(lib/rigor/)}, '\1')
      end

      # @param diagnostic [Rigor::Analysis::Diagnostic]
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
      #
      # @param diagnostic [Rigor::Analysis::Diagnostic]
      def discards_file_analysis?(diagnostic)
        reason(diagnostic) == DISCARDS_FILE_ANALYSIS_REASON
      end

      # True when `diagnostic` reports a failure inside Rigor that left the run readable but invalid as a
      # measurement of Rigor — see {ANALYZER_DEFECT_RULES}. Orthogonal to {.discards_file_analysis?}: the
      # user-facing tier reads the run; the Rigor-measuring tier should refuse it (the mutation fuzz does,
      # the ADR-69 kill oracle does not yet — #790).
      #
      # @param diagnostic [Rigor::Analysis::Diagnostic]
      def analyzer_defect?(diagnostic)
        ANALYZER_DEFECT_RULES.include?(diagnostic.rule)
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
