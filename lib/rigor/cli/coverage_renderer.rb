# frozen_string_literal: true

require "json"
require_relative "renderable"

module Rigor
  class CLI
    # Renders a `CoverageReport` as terminal-friendly text or JSON.
    class CoverageRenderer
      include Renderable

      TIER_LABELS = {
        constant: "constant",
        nominal: "nominal",
        shaped: "shaped (Tuple/Hash/Range/generic)",
        refined: "refined",
        bot: "bot (unreachable)",
        dynamic_specific: "dynamic — partial info",
        dynamic_top: "dynamic — opaque (untyped)",
        top: "top"
      }.freeze

      def initialize(out:)
        @out = out
      end

      private

      def render_text(report)
        render_text_header(report)
        render_text_summary(report)
        render_text_tier_table(report)
        render_text_per_file(report) if report.per_file.size > 1
        render_text_parse_errors(report)
      end

      def render_text_header(report)
        n = report.files.size
        suffix = n == 1 ? "" : "s"
        @out.puts("Type coverage: #{n} file#{suffix}")
        report.files.first(5).each { |f| @out.puts("  - #{f}") }
        @out.puts("  ... (#{n - 5} more)") if n > 5
        @out.puts
      end

      def render_text_summary(report)
        g = report.grand_total
        p = report.precise_count
        o = report.opaque_count
        @out.puts("Summary:")
        @out.puts("  files processed:      #{report.files.size - report.parse_errors.size}")
        @out.puts("  parse errors:         #{report.parse_errors.size}")
        @out.puts("  expressions typed:    #{g}")
        @out.puts("  precise:              #{p}#{pct(p, g)}")
        @out.puts("  dynamic (opaque):     #{o}#{pct(o, g)}")
        @out.puts("  precision ratio:      #{(report.precision_ratio * 100).round(2)}%")
        @out.puts
      end

      def render_text_tier_table(report)
        @out.puts("Tier breakdown:")
        g = report.grand_total
        Inference::PrecisionScanner::TIERS.each do |tier|
          n = report.tier_count(tier)
          next if n.zero?

          label = TIER_LABELS.fetch(tier, tier.to_s).ljust(36)
          @out.puts("  #{label} #{n.to_s.rjust(7)}#{pct(n, g)}")
        end
        @out.puts
      end

      def render_text_per_file(report)
        @out.puts("Per-file breakdown:")
        width = report.per_file.map { |e| e[:file].size }.max || 0
        report.per_file.sort_by { |e| e[:result].precision_ratio }.each do |entry|
          r = entry[:result]
          next if r.total.zero?

          ratio_str = "#{(r.precision_ratio * 100).round(1)}%".rjust(6)
          @out.puts("  #{entry[:file].ljust(width)}  #{ratio_str}  (#{r.precise_count}/#{r.total})")
        end
        @out.puts
      end

      def render_text_parse_errors(report)
        return if report.parse_errors.empty?

        @out.puts("Parse errors:")
        report.parse_errors.each do |entry|
          @out.puts("  #{entry[:file]}: #{entry[:errors].join('; ')}")
        end
      end

      def render_json(report)
        @out.puts(JSON.pretty_generate(json_payload(report)))
      end

      def json_payload(report)
        g = report.grand_total
        {
          summary: json_summary(report, g),
          by_tier: tier_payload(g) { |tier| report.tier_count(tier) },
          by_file: report.per_file.map { |e| file_payload(e) },
          parse_errors: report.parse_errors.map { |e| { file: e[:file], errors: e[:errors] } }
        }
      end

      def json_summary(report, grand_total)
        g = grand_total
        dsc = report.total.dynamic_specific_count
        {
          files_processed: report.files.size - report.parse_errors.size,
          parse_errors: report.parse_errors.size,
          expressions_typed: g,
          precise_count: report.precise_count,
          precise_ratio: ratio_f(report.precision_ratio),
          dynamic_opaque_count: report.opaque_count,
          dynamic_opaque_ratio: ratio_f(report.opaque_ratio),
          dynamic_specific_count: dsc,
          dynamic_specific_ratio: ratio_f(dsc.fdiv(g.nonzero? || 1))
        }
      end

      def tier_payload(grand_total)
        g = grand_total
        Inference::PrecisionScanner::TIERS.to_h do |tier|
          n = yield tier
          [tier, { count: n, ratio: ratio_f(n.fdiv(g.nonzero? || 1)) }]
        end
      end

      def file_payload(entry)
        r = entry[:result]
        {
          file: entry[:file],
          expressions_typed: r.total,
          precise_count: r.precise_count,
          precise_ratio: ratio_f(r.precision_ratio),
          dynamic_opaque_count: r.opaque_count,
          dynamic_opaque_ratio: ratio_f(r.opaque_ratio),
          by_tier: tier_payload(r.total) { |tier| r.tier_counts.fetch(tier, 0) }
        }
      end

      def pct(numerator, denominator)
        return "" if denominator.zero?

        " (#{(numerator.fdiv(denominator) * 100).round(1)}%)"
      end

      def ratio_f(val)
        val.round(4)
      end
    end
  end
end
