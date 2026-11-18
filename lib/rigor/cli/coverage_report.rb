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

      def call_sites
        total.call_sites
      end

      def dynamic_call_sites
        total.dynamic_call_sites
      end

      def dynamic_call_ratio
        total.dynamic_call_ratio
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
        @total_total = 0
        @total_tier_counts = Inference::PrecisionScanner::TIERS.to_h { |t| [t, 0] }
        @total_call_sites = 0
        @total_dynamic_call_sites = 0
      end

      def absorb(path, file_result)
        @per_file << { file: path, result: file_result }
        @total_total += file_result.total
        file_result.tier_counts.each { |tier, n| @total_tier_counts[tier] += n }
        @total_call_sites += file_result.call_sites
        @total_dynamic_call_sites += file_result.dynamic_call_sites
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
            tier_counts: @total_tier_counts,
            call_sites: @total_call_sites,
            dynamic_call_sites: @total_dynamic_call_sites
          )
        )
      end
    end
  end
end
