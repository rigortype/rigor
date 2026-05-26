# frozen_string_literal: true

module Rigor
  class CLI
    # Aggregated precision-coverage report assembled by `CoverageCommand`.
    # Holds per-file breakdowns and accumulated totals; consumed by
    # `CoverageRenderer` for text and JSON output.
    class CoverageReport < Data.define(
      :files,
      :parse_errors,
      :per_file,
      :total
    )
      # Sum of all per-file totals.
      def grand_total
        total.total
      end

      def precise_count
        total.precise_count
      end

      def opaque_count
        total.opaque_count
      end

      def precision_ratio
        total.precision_ratio
      end

      def opaque_ratio
        total.opaque_ratio
      end

      def tier_count(tier)
        total.tier_counts.fetch(tier, 0)
      end
    end

    # Mutable accumulator used while scanning files.
    class CoverageAccumulator
      require_relative "../inference/precision_scanner"

      def initialize
        @per_file = []
        @parse_errors = []
        # Accumulated totals across all files.
        @total_total = 0
        @total_tier_counts = Inference::PrecisionScanner::TIERS.to_h { |t| [t, 0] }
      end

      def absorb(path, file_result)
        @per_file << { file: path, result: file_result }
        @total_total += file_result.total
        file_result.tier_counts.each { |tier, n| @total_tier_counts[tier] += n }
      end

      def record_parse_error(path, errors)
        @parse_errors << { file: path, errors: errors.map(&:message) }
      end

      def to_report(files, _options)
        CoverageReport.new(
          files: files,
          parse_errors: @parse_errors,
          per_file: @per_file,
          total: Inference::PrecisionScanner::FileResult.new(
            total: @total_total,
            tier_counts: @total_tier_counts
          )
        )
      end
    end
  end
end
