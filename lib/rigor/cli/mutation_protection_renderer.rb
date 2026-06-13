# frozen_string_literal: true

require "json"

module Rigor
  class CLI
    # Renders a {MutationProtectionReport} (ADR-63 Tier 2) as text or JSON. The
    # text form leads with the effectiveness ratio (caught breakages), then the
    # breakages Rigor missed ("add a type here"), then the least-effective files.
    # The framing is always *where to add a type*, never "your code is broken".
    class MutationProtectionRenderer
      TOP_CALLS = 15
      TOP_FILES = 10

      def initialize(out:)
        @out = out
      end

      def render(report, format:)
        format == "json" ? render_json(report) : render_text(report)
      end

      private

      def render_json(report)
        @out.puts(JSON.pretty_generate(report.to_h))
      end

      def render_text(report)
        pct = (report.ratio * 100).round(1)
        @out.puts "Type-protection effectiveness (Tier 2 — mutation kill rate)"
        @out.puts "  caught breakages: #{report.total_killed} / #{report.grand_total}  (#{pct}%)"
        @out.puts "  (effectiveness = when a type-visible bug was introduced, Rigor caught it)"
        render_missed(report)
        render_files(report)
      end

      def render_missed(report)
        missed = report.missed
        return if missed.empty?

        @out.puts "\nAdd a type here — breakages Rigor missed (a wrong call that stayed silent):"
        missed.first(TOP_CALLS).each do |call|
          @out.puts format("  %<count>-5d #%<method>s   e.g. %<sites>s",
                           count: call.count, method: call.method_name, sites: call.examples.join("  "))
        end
        @out.puts "  (#{missed.size - TOP_CALLS} more)" if missed.size > TOP_CALLS
      end

      def render_files(report)
        worst = report.files.reject { |f| f.survived.zero? }.sort_by(&:ratio).first(TOP_FILES)
        return if worst.empty?

        @out.puts "\nLeast-effective files:"
        worst.each do |file|
          total = file.killed + file.survived
          @out.puts format("  %<pct>5.1f%%  %<path>s  (%<n>d/%<total>d breakages caught)",
                           pct: file.ratio * 100, path: file.path, n: file.killed, total: total)
        end
      end
    end
  end
end
