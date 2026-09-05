# frozen_string_literal: true

module Rigor
  module Protection
    # Issue #686 — the single definition of "was this file measured at all", and the one place the two
    # counts' escalation rule is written down rather than restated.
    #
    # `killed + survived == 0` means two different things, and telling them apart is the whole point:
    #
    # - with no `harness_errors`, the file had no type-relevant mutation, and the vacuous-file convention
    #   scores it fully effective — there was no breakage available to miss;
    # - with `harness_errors`, every mutant it had failed inside the harness, so the file measured the
    #   HARNESS and says nothing about the code. Borrowing the first's 1.0 made a wholly crashed file report
    #   100% effective and pass `--threshold`.
    #
    # The predicate lives here because four call sites need the same answer — the per-file results, the exit
    # gate, the stderr warning and both renderers — and four independent spellings of
    # `harness_errors.positive? && total.zero?` agree only by coincidence (issue #696 review, second pass).
    module MeasurementIntegrity
      module_function

      # @return [Boolean] false only when nothing could be measured AND something failed trying.
      def measured?(total:, harness_errors:)
        !(total.zero? && harness_errors.positive?)
      end

      # The report-level companion: a project ratio computed over nothing, where something went wrong.
      # Distinct from an empty project, which is legitimately vacuous.
      def ratio_unmeasurable?(grand_total:, unmeasured_files:)
        grand_total.zero? && unmeasured_files.positive?
      end
    end
  end
end
