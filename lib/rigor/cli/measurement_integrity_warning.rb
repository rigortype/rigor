# frozen_string_literal: true

module Rigor
  class CLI
    # The stderr half of "did this measurement actually happen" for `rigor coverage --protection --mutation`.
    #
    # Two counts, escalating, and the difference between them is the whole point:
    #
    # - `harness_errors` (#264) counts MUTANTS the harness rescued. Advisory and floored — a few are the
    #   transient the bucket exists to make visible, and `determine_protection_exit` deliberately ignores
    #   them so a `--threshold` build does not start failing for a reason unrelated to the ratio it pins.
    # - `unmeasured_files` (#686) counts FILES where nothing could be measured at all, because the clean
    #   baseline itself came back from a crashed analysis. No floor and not advisory: the ratio then answers
    #   a smaller question than the user asked, `determine_protection_exit` fails the run, and this says so.
    #   Without it, `killed + survived == 0` borrowed the vacuous-file convention's 1.0 and a run that
    #   measured nothing printed 100% and passed every threshold.
    #
    # Extracted from {CoverageMutation} rather than inlined there: that module sits at its length budget, and
    # a warning pair with its own escalation rule is a thing worth naming anyway.
    module MeasurementIntegrityWarning
      module_function

      # @rbs report: MutationProtectionReport | FusedProtectionReport -- Both expose the two counts.
      # @rbs err: IO -- The stream to warn on.
      # @rbs floor: Integer -- {CoverageMutation::HARNESS_ERROR_WARN_FLOOR}.
      def emit(report, err:, floor:)
        lines_for(report, floor: floor).each { |line| err.puts(line) }
      end

      # @rbs return: Array[String] -- The warnings this report earns, widest consequence first.
      def lines_for(report, floor:)
        lines = []
        unmeasured = report.respond_to?(:unmeasured_files) ? report.unmeasured_files : 0 # see CoverageCommand
        lines << unmeasured_line(unmeasured) if unmeasured.positive?
        harness_errors = report.total_harness_errors
        lines << harness_error_line(harness_errors, floor) if harness_errors >= floor
        lines
      end

      def unmeasured_line(count)
        "coverage: #{count} file(s) could not be measured at all — every mutation of them failed inside " \
          "the measurement harness, typically because Rigor's own analysis crashed while re-analysing " \
          "them. They contribute nothing to the ratio, so the effectiveness above is measured over the " \
          "REST of the project. Exiting non-zero: a ratio over part of what you asked about must not read " \
          "as a pass."
      end

      def harness_error_line(count, floor)
        "coverage: #{count} mutants failed inside the measurement harness (\"harness_errors\", at/above " \
          "the #{floor}-mutant floor) — excluded from the ratio like a parse-invalid mutant, but this many " \
          "suggests a harness defect rather than one-off noise. Investigate before trusting --threshold " \
          "on this run."
      end
    end
  end
end
