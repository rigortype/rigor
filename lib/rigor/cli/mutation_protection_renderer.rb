# frozen_string_literal: true

require "json"

module Rigor
  class CLI
    # Renders a {MutationProtectionReport} (ADR-63 Tier 2) as text or JSON. The text form leads with the effectiveness
    # ratio (caught breakages), then the breakages Rigor missed ("add a type here"), then the least-effective files. The
    # framing is always *where to add a type*, never "your code is broken".
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
        @out.puts "  caught breakages: #{report.total_killed} / #{report.grand_total}#{ratio_suffix(report, pct)}"
        @out.puts "  (effectiveness = when a type-visible bug was introduced, Rigor caught it)"
        render_unmeasured_files(report)
        render_harness_errors(report)
        render_missed(report)
        render_files(report)
      end

      # Issue #686 — `0 / 0` is `ratio` 1.0 by the vacuous-file convention, and printing "100.0%" over a run
      # that measured nothing is the exact shape this issue exists to end. When nothing was measured AND a
      # file went unmeasured, the percentage is withheld rather than invented.
      def ratio_suffix(report, pct)
        return "  (not measured)" if report.grand_total.zero? && report.unmeasured_files.positive?

        "  (#{pct}%)"
      end

      # Issue #686 — the count that makes the command exit non-zero, on stdout beside the ratio it qualifies
      # (the stderr twin in `CoverageMutation#warn_unmeasured_files` carries the explanation).
      def render_unmeasured_files(report)
        count = report.unmeasured_files
        return if count.zero?

        @out.puts "  unmeasured files: #{count} — every mutation of them failed inside the measurement " \
                  "harness, so they are not in the ratio above"
      end

      # #264 — surfaced only when non-zero: a harness-level failure is a defect in the measurement itself, not
      # in the code being measured, and a clean run should not carry a permanent line about a bucket that is
      # always empty.
      def render_harness_errors(report)
        count = report.total_harness_errors
        return if count.zero?

        @out.puts "  harness errors: #{count} mutant(s) failed inside the measurement harness " \
                  "(excluded from the ratio — see --format=json's \"harness_errors\")"
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
