# frozen_string_literal: true

module Rigor
  class CLI
    # ADR-70 — aggregates per-file {Protection::MutationScanner::FusedFileResult} into a project-level **fused**
    # protection report: how many type-visible breakages were caught by the type checker, how many of the
    # *type-survivors* were caught by the test suite, and which sites neither axis caught — the ranked "add a type OR a
    # test here" list.
    #
    # Framing (ADR-63 / ADR-62 Criterion A, extended): the payload is the **attribution** — which protection axis is
    # missing — never raw survival. An unprotected site is "add protection here", never "your code is broken".
    FusedFileProtection = Data.define(:path, :type_killed, :test_killed, :unprotected, :ratio)
    UnprotectedBreakage = Data.define(:method_name, :count, :examples)

    FusedProtectionReport = Data.define(:files, :unprotected, :parse_errors) do
      def total_type_killed = files.sum(&:type_killed)
      def total_test_killed = files.sum(&:test_killed)
      def total_unprotected = files.sum(&:unprotected)
      def grand_total = total_type_killed + total_test_killed + total_unprotected
      def protected_total = total_type_killed + total_test_killed
      def ratio = grand_total.zero? ? 1.0 : protected_total.to_f / grand_total

      def to_h
        {
          "mode" => "protection-fused",
          "type_killed" => total_type_killed,
          "test_killed" => total_test_killed,
          "unprotected" => total_unprotected,
          "protected_ratio" => ratio.round(4),
          "files" => files.map do |f|
            { "path" => f.path, "type_killed" => f.type_killed, "test_killed" => f.test_killed,
              "unprotected" => f.unprotected, "ratio" => f.ratio.round(4) }
          end,
          "add_protection_here" => unprotected.map do |m|
            { "method" => m.method_name, "count" => m.count, "examples" => m.examples }
          end,
          "parse_errors" => parse_errors
        }
      end
    end

    class FusedProtectionAccumulator
      def initialize
        @files = []
        @unprotected = Hash.new { |h, k| h[k] = { count: 0, examples: [] } }
        @parse_errors = []
      end

      def absorb(file_result)
        @files << FusedFileProtection.new(
          path: file_result.path, type_killed: file_result.type_killed,
          test_killed: file_result.test_killed, unprotected: file_result.unprotected,
          ratio: file_result.ratio
        )
        file_result.sites.each do |site|
          bucket = @unprotected[site.method_name]
          bucket[:count] += 1
          bucket[:examples] << "#{file_result.path}:#{site.line}" if bucket[:examples].size < 3
        end
      end

      def record_parse_error(path, errors)
        @parse_errors << { "path" => path, "errors" => errors.size }
      end

      def to_report
        unprotected = @unprotected
                      .map { |m, v| UnprotectedBreakage.new(method_name: m, count: v[:count], examples: v[:examples]) }
                      .sort_by { |m| [-m.count, m.method_name] }
        FusedProtectionReport.new(files: @files, unprotected: unprotected, parse_errors: @parse_errors)
      end
    end
  end
end
