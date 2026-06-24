# frozen_string_literal: true

require "json"

module Rigor
  class CLI
    # Renders an {ProtectionReport} (ADR-63 Tier 1) as text or JSON. The text
    # form leads with the protected ratio, then the highest-traffic untyped
    # dispatches ("add a type here"), then the lowest-protected files. The
    # framing is always *where to add a type*, never "your code is broken".
    class ProtectionRenderer
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
        @out.puts "Type-protection coverage (Tier 1 — dispatch-site receiver concreteness)"
        @out.puts "  protected dispatch sites: #{report.total_protected} / #{report.grand_total}  (#{pct}%)"
        @out.puts "  (protected = Rigor can catch a wrong call here; an upper bound on real protection)"
        render_untyped_calls(report)
        render_files(report)
      end

      def render_untyped_calls(report)
        calls = report.untyped_calls
        return if calls.empty?

        @out.puts "\nAdd a type here — methods most often called on an untyped receiver:"
        calls.first(TOP_CALLS).each do |call|
          label = origin_label(call.dynamic_origin)
          @out.puts format("  %<count>-5d #%<method>s   e.g. %<sites>s%<label>s",
                           count: call.count, method: call.method_name,
                           sites: call.examples.join("  "), label: label)
        end
        @out.puts "  (#{calls.size - TOP_CALLS} more)" if calls.size > TOP_CALLS
      end

      def origin_label(origin)
        return "" if origin.nil?

        "  [#{origin.to_s.tr('_', '-')}]"
      end

      def render_files(report)
        worst = report.files.reject { |f| f.unprotected_count.zero? }.sort_by(&:ratio).first(TOP_FILES)
        return if worst.empty?

        @out.puts "\nLeast-protected files:"
        worst.each do |file|
          total = file.protected_count + file.unprotected_count
          @out.puts format("  %<pct>5.1f%%  %<path>s  (%<n>d/%<total>d protected)",
                           pct: file.ratio * 100, path: file.path, n: file.protected_count, total: total)
        end
      end
    end
  end
end
