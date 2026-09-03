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
    class AnalyzerCrashed < StandardError; end

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
    # Only {Analysis::CrashSignature.analyzer_failed?} is armed — an escaped exception, where nothing ran. A
    # `:rbs_build` degradation is not refused: the analysis ran, and the site filter that admits mutations
    # already keeps only receivers Rigor holds a concrete type for, so a class whose RBS definition failed
    # to build contributes no measured sites in the first place. Refusing on it would turn a partially
    # useful measurement into no measurement, which is the wrong trade under ADR-5.
    module AnalysisGuard
      module_function

      # Takes the whole {Analysis::Result} rather than its diagnostics so the question is asked through
      # {Analysis::Result#crashed?} — the same predicate the spec-side guard reads, off the same
      # {Analysis::CrashSignature} table. Hands back the diagnostics, which is all a kill comparison wants.
      #
      # @param result [Rigor::Analysis::Result] one analysis run.
      # @param context [String] which oracle call produced it, so the raise points at the right seam.
      # @return [Array<Rigor::Analysis::Diagnostic>] the run's diagnostics, when the run was healthy.
      # @raise [AnalyzerCrashed]
      def checked(result, context:)
        return result.diagnostics unless result.crashed?

        raise AnalyzerCrashed,
              "#{context}: the analyzer crashed, so this run's diagnostics say nothing about the code " \
              "(#{Analysis::CrashSignature.describe(result.crash_diagnostics.first)}). A kill comparison " \
              "against it would score the mutant a survivor it was never measured against. See issue #686."
      end
    end
  end
end
