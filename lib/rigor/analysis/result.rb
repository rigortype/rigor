# frozen_string_literal: true

module Rigor
  module Analysis
    class Result
      attr_reader :diagnostics, :stats

      # @param stats [Rigor::Analysis::RunStats, nil] end-of-run
      #   telemetry (target file count, RBS class breakdown,
      #   wall + RSS) collected by the Runner. Nil when stats
      #   collection wasn't requested or wasn't applicable
      #   (early-exit paths like `validate_target_ruby` failure).
      def initialize(diagnostics: [], stats: nil)
        @diagnostics = diagnostics
        @stats = stats
      end

      def success?
        diagnostics.none?(&:error?)
      end

      def error_count
        diagnostics.count(&:error?)
      end

      def to_h
        hash = {
          "success" => success?,
          "error_count" => error_count,
          "diagnostics" => diagnostics.map(&:to_h)
        }
        hash["stats"] = @stats.to_h if @stats
        hash
      end
    end
  end
end
