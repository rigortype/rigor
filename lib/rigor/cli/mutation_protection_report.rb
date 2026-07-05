# frozen_string_literal: true

module Rigor
  class CLI
    # ADR-63 Tier 2 — aggregates per-file {Protection::MutationScanner} results into a project-level *effectiveness*
    # report: the kill ratio (when a type-visible bug was introduced, how often Rigor caught it), the per-file
    # breakdown, and a ranked "add a type here" list keyed by the method whose breakage Rigor most often *missed* — the
    # sites where a receiver annotation would buy real catching power.
    #
    # The framing is load-bearing (ADR-63 Criterion A / ADR-62 Criterion A): the number is *effectiveness*, the
    # survivors are *missed breakages / where to add a type*, never "your code is broken".
    FileEffectiveness = Data.define(:path, :killed, :survived, :ratio)
    MissedBreakage = Data.define(:method_name, :count, :examples)

    MutationProtectionReport = Data.define(:files, :missed, :parse_errors) do
      def total_killed = files.sum(&:killed)
      def total_survived = files.sum(&:survived)
      def grand_total = total_killed + total_survived
      def ratio = grand_total.zero? ? 1.0 : total_killed.to_f / grand_total

      def to_h
        {
          "mode" => "mutation",
          "killed" => total_killed,
          "survived" => total_survived,
          "effectiveness_ratio" => ratio.round(4),
          "files" => files.map do |f|
            { "path" => f.path, "killed" => f.killed,
              "survived" => f.survived, "ratio" => f.ratio.round(4) }
          end,
          "add_a_type_here" => missed.map do |m|
            { "method" => m.method_name, "count" => m.count, "examples" => m.examples }
          end,
          "parse_errors" => parse_errors
        }
      end
    end

    class MutationProtectionAccumulator
      def initialize
        @files = []
        @missed = Hash.new { |h, k| h[k] = { count: 0, examples: [] } }
        @parse_errors = []
      end

      def absorb(file_result)
        @files << FileEffectiveness.new(
          path: file_result.path, killed: file_result.killed,
          survived: file_result.survived, ratio: file_result.ratio
        )
        file_result.sites.each do |site|
          bucket = @missed[site.method_name]
          bucket[:count] += 1
          bucket[:examples] << "#{file_result.path}:#{site.line}" if bucket[:examples].size < 3
        end
      end

      def record_parse_error(path, errors)
        @parse_errors << { "path" => path, "errors" => errors.size }
      end

      def to_report
        missed = @missed
                 .map { |method, v| MissedBreakage.new(method_name: method, count: v[:count], examples: v[:examples]) }
                 .sort_by { |m| [-m.count, m.method_name] }
        MutationProtectionReport.new(files: @files, missed: missed, parse_errors: @parse_errors)
      end
    end
  end
end
