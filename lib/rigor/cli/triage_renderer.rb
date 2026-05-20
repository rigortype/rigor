# frozen_string_literal: true

require "json"

require_relative "../triage"

module Rigor
  class CLI
    # ADR-23 — renders a {Rigor::Triage::Report} as the `rigor
    # triage` text report or as `--format json`.
    class TriageRenderer
      BAR_WIDTH = 24

      def initialize(report, sections:)
        @report = report
        @sections = sections # subset of %i[distribution hotspots hints]
      end

      def json
        JSON.pretty_generate(Triage.report_to_h(@report))
      end

      def text
        blocks = []
        blocks << distribution_block if @sections.include?(:distribution)
        blocks << hotspots_block     if @sections.include?(:hotspots)
        blocks << hints_block        if @sections.include?(:hints)
        "#{blocks.join("\n\n")}\n"
      end

      private

      def distribution_block
        s = @report.summary
        max = @report.distribution.map(&:count).max || 1
        lines = ["Diagnostic distribution — #{s.total} total " \
                 "(#{s.error} error / #{s.warning} warning#{" / #{s.info} info" if s.info.positive?})"]
        @report.distribution.each do |row|
          lines << format("  %<rule>-32s %<count>5d  %<bar>s",
                          rule: row.rule, count: row.count, bar: bar(row.count, max))
        end
        lines.join("\n")
      end

      def hotspots_block
        return "Hotspot files\n  (none)" if @report.hotspots.empty?

        lines = ["Hotspot files"]
        @report.hotspots.each do |spot|
          by_rule = spot.by_rule.map { |rule, count| "#{rule}×#{count}" }.join("  ")
          lines << format("  %<file>-40s %<count>4d  %<rules>s",
                          file: spot.file, count: spot.count, rules: by_rule)
        end
        lines.join("\n")
      end

      def hints_block
        return "Hints\n  (no heuristic hints)" if @report.hints.empty?

        lines = ["Hints — heuristics, verify before acting"]
        @report.hints.each do |hint|
          lines << ""
          lines << "  [#{hint.confidence} #{hint.id}]  #{hint.diagnostic_count} diagnostic(s)"
          lines << "    #{hint.summary}"
          lines << "    → #{hint.action}"
        end
        lines.join("\n")
      end

      def bar(count, max)
        filled = max.zero? ? 0 : (count * BAR_WIDTH / max)
        filled = 1 if filled.zero? && count.positive?
        "█" * filled
      end
    end
  end
end
