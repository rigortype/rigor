# frozen_string_literal: true

require_relative "../inference/dynamic_origin"

module Rigor
  class CLI
    # ADR-63 Tier 1 — aggregates per-file {Inference::ProtectionScanner} results into a project-level protection report:
    # the protected ratio, the per-file breakdown, and a ranked "add a type here" list keyed by the method called on an
    # unprotected (`Dynamic`) receiver — the highest-traffic untyped dispatches, where a receiver annotation buys the
    # most catching power.
    FileProtection = Data.define(:path, :protected_count, :unprotected_count, :ratio)
    UntypedCall = Data.define(:method_name, :count, :examples, :dynamic_origin)

    ProtectionReport = Data.define(:files, :untyped_calls, :parse_errors) do
      def total_protected = files.sum(&:protected_count)
      def total_unprotected = files.sum(&:unprotected_count)
      def grand_total = total_protected + total_unprotected
      def ratio = grand_total.zero? ? 1.0 : total_protected.to_f / grand_total

      # ADR-73 P6 — total dispatch-site count per tractability axis across the classified holes (those with a recorded
      # `dynamic_origin`), so a user sees at a glance how much of the untyped surface a type can actually close
      # (`add_rbs`) vs. needs a plugin (`enable_plugin`) vs. is an engine gap. Keys are omitted when zero; an
      # all-unclassified run yields `{}`.
      def tractability_summary
        untyped_calls.each_with_object(Hash.new(0)) do |c, acc|
          axis = c.dynamic_origin && Inference::DynamicOrigin.tractability(c.dynamic_origin)
          acc[axis] += c.count if axis
        end
      end

      def to_h
        {
          "protected" => total_protected,
          "unprotected" => total_unprotected,
          "protection_ratio" => ratio.round(4),
          "tractability_summary" => tractability_summary.transform_keys(&:to_s),
          "files" => files.map do |f|
            { "path" => f.path, "protected" => f.protected_count,
              "unprotected" => f.unprotected_count, "ratio" => f.ratio.round(4) }
          end,
          "add_a_type_here" => untyped_calls.map do |c|
            entry = { "method" => c.method_name, "count" => c.count, "examples" => c.examples }
            if c.dynamic_origin
              entry["dynamic_origin"] = c.dynamic_origin
              tractability = Inference::DynamicOrigin.tractability(c.dynamic_origin)
              entry["tractability"] = tractability if tractability
            end
            entry
          end,
          "parse_errors" => parse_errors
        }
      end
    end

    class ProtectionAccumulator
      def initialize
        @files = []
        @calls = Hash.new { |h, k| h[k] = { count: 0, examples: [], origins: Hash.new(0) } }
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
          bucket[:origins][site.dynamic_origin] += 1 if site.dynamic_origin
        end
      end

      def record_parse_error(path, errors)
        @parse_errors << { "path" => path, "errors" => errors.size }
      end

      def to_report
        calls = @calls.map do |method, v|
          origin = v[:origins].max_by { |_, count| count }&.first
          UntypedCall.new(method_name: method, count: v[:count], examples: v[:examples],
                          dynamic_origin: origin)
        end
        untyped = calls.sort_by { |c| [-c.count, c.method_name] }
        ProtectionReport.new(files: @files, untyped_calls: untyped, parse_errors: @parse_errors)
      end
    end
  end
end
