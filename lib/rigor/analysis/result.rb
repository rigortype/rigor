# frozen_string_literal: true

module Rigor
  module Analysis
    class Result
      attr_reader :diagnostics

      def initialize(diagnostics: [])
        @diagnostics = diagnostics
      end

      def success?
        diagnostics.none?(&:error?)
      end

      def error_count
        diagnostics.count(&:error?)
      end

      def to_h
        {
          "success" => success?,
          "error_count" => error_count,
          "diagnostics" => diagnostics.map(&:to_h)
        }
      end
    end
  end
end
