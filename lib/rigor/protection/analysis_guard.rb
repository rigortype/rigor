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
    # Only {Analysis::Result#crashed?} is armed — the check-rule rescue, the one shape that REPLACES a
    # file's whole diagnostic list. Refusing more than that is the same error pointed the other way, and it
    # was measured: on a project whose plugin `prepare` raises, refusing the `:plugin` row took a file from
    # `killed=1 survived=6` to `killed=0 survived=0 harness_errors=7` — the builtin rules had run, their
    # diagnostics were all present, and a real measurement was thrown away. `invoke_plugin_prepare` appends
    # its row to every sequential run, so arming it would have refused every run for the life of the
    # process. `:rbs_build` is excluded for the same reason plus one more: the site filter that admits
    # mutations already drops receivers whose type did not resolve, so a class whose definition failed to
    # build contributes no measured sites to begin with.
    module AnalysisGuard
      module_function

      # Takes the whole {Analysis::Result} rather than its diagnostics so the question is asked through
      # {Analysis::Result#crashed?} — the same predicate the spec-side guard reads, off the same
      # {Analysis::CrashSignature} table. Hands back the diagnostics, which is all a kill comparison wants.
      #
      # @rbs result: Rigor::Analysis::Result -- One analysis run.
      # @rbs context: String -- Which oracle call produced it, so the raise points at the right seam.
      # @rbs return: Array[Rigor::Analysis::Diagnostic] --
      #   The run's diagnostics, when the run was healthy. Raises AnalyzerCrashed
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
