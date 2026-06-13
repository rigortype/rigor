# frozen_string_literal: true

module Rigor
  class CLI
    # ADR-63 Tier 1 — aggregates per-file {Inference::ProtectionScanner}
    # results into a project-level protection report: the protected ratio, the
    # per-file breakdown, and a ranked "add a type here" list keyed by the
    # method called on an unprotected (`Dynamic`) receiver — the highest-traffic
    # untyped dispatches, where a receiver annotation buys the most catching
    # power.
    FileProtection = Data.define(:path, :protected_count, :unprotected_count, :ratio)
    UntypedCall = Data.define(:method_name, :count, :examples)

    ProtectionReport = Data.define(:files, :untyped_calls, :parse_errors) do
      def total_protected = files.sum(&:protected_count)
      def total_unprotected = files.sum(&:unprotected_count)
      def grand_total = total_protected + total_unprotected
      def ratio = grand_total.zero? ? 1.0 : total_protected.to_f / grand_total

      def to_h
        {
          "protected" => total_protected,
          "unprotected" => total_unprotected,
          "protection_ratio" => ratio.round(4),
          "files" => files.map do |f|
            { "path" => f.path, "protected" => f.protected_count,
              "unprotected" => f.unprotected_count, "ratio" => f.ratio.round(4) }
          end,
          "add_a_type_here" => untyped_calls.map do |c|
            { "method" => c.method_name, "count" => c.count, "examples" => c.examples }
          end,
          "parse_errors" => parse_errors
        }
      end
    end

    class ProtectionAccumulator
      def initialize
        @files = []
        @calls = Hash.new { |h, k| h[k] = { count: 0, examples: [] } }
        @parse_errors = []
      end

      def absorb(path, file_result)
        @files << FileProtection.new(
          path: path, protected_count: file_result.protected_count,
          unprotected_count: file_result.unprotected_count, ratio: file_result.ratio
        )
        file_result.sites.each do |site|
          bucket = @calls[site.method_name]
          bucket[:count] += 1
          bucket[:examples] << "#{path}:#{site.line}" if bucket[:examples].size < 3
        end
      end

      def record_parse_error(path, errors)
        @parse_errors << { "path" => path, "errors" => errors.size }
      end

      def to_report
        untyped = @calls
                  .map { |method, v| UntypedCall.new(method_name: method, count: v[:count], examples: v[:examples]) }
                  .sort_by { |c| [-c.count, c.method_name] }
        ProtectionReport.new(files: @files, untyped_calls: untyped, parse_errors: @parse_errors)
      end
    end
  end
end
