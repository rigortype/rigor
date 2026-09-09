# frozen_string_literal: true

require_relative "../analysis/crash_signature"

module Rigor
  module Protection
    # Issue #686 — raised when an oracle's re-analysis came back from a crashed run, so its diagnostics say
    # nothing about the code that was analysed.
    #
    # A named class, not a bare RuntimeError: {MutationScanner#classify} already folds a per-mutant
    # `StandardError` into the `:harness_error` bucket, and the scanner's file-level rescue must catch THIS
    # and nothing else, so the two failure modes stay distinguishable at every site that handles either.
    #
    # Issue #790 — it says WHICH of the two refusals below fired, because they want different recovery. A
    # crashed check rule left the Environment as it found it; an analyzer defect (the #784 HKT registry
    # build) recorded itself ON that Environment and is memoised there, so the caller that owns the
    # Environment has to replace it before the next mutant is scored. {#analyzer_defect?} is how a caller
    # tells the two apart without re-deriving the classification from the message it was handed.
    class AnalyzerCrashed < StandardError
      def initialize(message = nil, analyzer_defect: false)
        super(message)
        @analyzer_defect = analyzer_defect
      end

      # True when the refusal was an analyzer defect rather than a crashed check rule — the shape whose
      # cause outlives the run that observed it.
      def analyzer_defect?
        @analyzer_defect
      end
    end

    # The kill oracles' guard against judging a mutant by a run that never happened.
    #
    # A kill oracle answers one question: did re-analysing the mutant produce a diagnostic the clean
    # baseline did not carry? When a check rule raises, `Runner#analyze_file_body` rescues it into ONE
    # `internal analyzer error` diagnostic for the whole file and discards the rest — deterministically, on
    # the SAME file, for the SAME reason. So the baseline and the mutant come back carrying the identical
    # synthetic row, the set difference is empty, and the oracle reports the mutant SURVIVED. Not "we could
    # not tell": survived. Every mutant in the affected file scores the same way, which inflates the
    # survivor count — the mutation harness's headline signal — in the direction that manufactures work,
    # and the harness has no way to notice.
    #
    # An indeterminate run must not be scored as either killed or survived, so the oracles raise here and
    # let {MutationScanner} put the mutant in the `harness_errors` bucket (#264), which is already excluded
    # from `killed + survived` and already surfaced by the CLI. A crash then READS as a crash.
    #
    # Two shapes are armed, and only two.
    #
    # {Analysis::Result#crashed?} — the check-rule rescue, the one shape that REPLACES a file's whole
    # diagnostic list. Refusing more than the shapes below is the same error pointed the other way, and it
    # was measured: on a project whose plugin `prepare` raises, refusing the `:plugin` row took a file from
    # `killed=1 survived=6` to `killed=0 survived=0 harness_errors=7` — the builtin rules had run, their
    # diagnostics were all present, and a real measurement was thrown away. `invoke_plugin_prepare` appends
    # its row to every sequential run, so arming it would have refused every run for the life of the
    # process. The user-caused `:rbs_build` rungs are excluded for the same reason plus one more: the site
    # filter that admits mutations already drops receivers whose type did not resolve, so a class whose
    # definition failed to build contributes no measured sites to begin with.
    #
    # {Analysis::CrashSignature.analyzer_defect?} (issue #790) — the one `:rbs_build` rung whose cause is
    # Rigor rather than the user's `sig/`: post-#788 a mutant that makes the implicit HKT scan raise no
    # longer produces a per-file `internal analyzer error` but ONE readable `rbs.coverage.hkt-scan-failed`
    # row, so `Result#crashed?` stays false and the mutant was scored as a measurement over a silently
    # degraded universe — issue #776 was exactly such a mutant. The run is readable (every rule fired), so
    # it stays out of `#crashed?`, which answers the user-facing "may I read these diagnostics?"; what this
    # guard asks is the narrower "is this a valid measurement OF RIGOR?", and it is not.
    #
    # The refusal is asked off {Analysis::CrashSignature} rather than off a second string match here, so a
    # reworded row or a fourth rung added to `ANALYZER_DEFECT_RULES` cannot disarm one copy and leave the
    # others armed (#696).
    #
    # The defect half is asked TWICE, of two surfaces, because each covers the other's blind spot. The row
    # is severity-stamped like every other diagnostic, so `severity_overrides:` resolving `rbs` (or the
    # exact rule id) to `off` drops it from the run entirely — and a harness that exists to find analyzer
    # defects must not be the one thing a project's config can hide one from. {Rigor::Environment} records
    # the failure BEFORE any severity resolution, so `#hkt_scan_failure` still answers. Conversely that slot
    # only ever describes THIS process's Environment: under the fork pool the defect happens in a worker's
    # own Environment and reaches the parent as the row alone.
    module AnalysisGuard
      module_function

      # Takes the whole {Analysis::Result} rather than its diagnostics so the crash question is asked
      # through {Analysis::Result#crashed?} — the same predicate the spec-side guard reads, off the same
      # {Analysis::CrashSignature} table. Hands back the diagnostics, which is all a kill comparison wants.
      #
      # @param result — one analysis run.
      # @param context — which oracle call produced it, so the raise points at the right seam.
      # @param environment — the Environment the run was made over, read for the pre-severity record of a
      #   shared-build failure. Optional: a caller that has none loses only the severity-override case.
      # @return the run's diagnostics, when the run was healthy.
      # @raise AnalyzerCrashed
      def checked(result, context:, environment: nil)
        refuse_crash(result, context) if result.crashed?
        defect = result.diagnostics.find { |diagnostic| Analysis::CrashSignature.analyzer_defect?(diagnostic) }
        refuse_defect(context, Analysis::CrashSignature.describe(defect)) if defect

        failure = shared_build_failure(environment)
        refuse_defect(context, failure) if failure

        result.diagnostics
      end

      # The pre-severity record, described the way {Analysis::CrashSignature.describe} describes a row, so
      # the two refusals read alike whichever surface saw the defect.
      def shared_build_failure(environment)
        return nil unless environment.respond_to?(:hkt_scan_failure)

        failure = environment.hkt_scan_failure
        return nil if failure.nil?

        error_class, message, frame, stage = failure
        "#{stage} HKT registry build raised #{error_class}: #{message}#{" at #{frame}" if frame}"
      end
      private_class_method :shared_build_failure

      def refuse_crash(result, context)
        raise AnalyzerCrashed,
              "#{context}: the analyzer crashed, so this run's diagnostics say nothing about the code " \
              "(#{Analysis::CrashSignature.describe(result.crash_diagnostics.first)}). A kill comparison " \
              "against it would score the mutant a survivor it was never measured against. See issue #686."
      end
      private_class_method :refuse_crash

      # The run is readable, so the message says what is wrong with it instead: the universe it was produced
      # over is missing the type constructors the RBS `type` aliases and the loaded plugins would have
      # contributed, and the BASELINE this mutant is compared against carries the identical degradation — so
      # the set difference is empty for a reason that has nothing to do with the mutation.
      def refuse_defect(context, description)
        refusal = AnalyzerCrashed.new(
          "#{context}: the analyzer degraded its own type universe, so this run is readable but is not a " \
          "measurement of Rigor (#{description}). Scoring a mutant against it reports the analyzer's own " \
          "defect as the mutant's survival. See issue #790.",
          analyzer_defect: true
        )
        raise refusal
      end
      private_class_method :refuse_defect
    end
  end
end
