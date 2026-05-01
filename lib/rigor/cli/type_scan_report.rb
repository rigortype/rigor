# frozen_string_literal: true

module Rigor
  class CLI
    # Aggregated report assembled by `TypeScanCommand` and consumed by
    # `TypeScanRenderer`. The struct holds per-file paths, accumulated
    # per-class counts, located fallback events, and any parse errors.
    Report = Data.define(
      :files,
      :parse_errors,
      :visits,
      :unrecognized,
      :events,
      :options
    ) do
      def visited_count
        visits.values.sum
      end

      def unrecognized_count
        unrecognized.values.sum
      end

      def unrecognized_ratio
        total = visited_count
        return 0.0 if total.zero?

        unrecognized_count.fdiv(total)
      end
    end
  end
end
