# frozen_string_literal: true

require "json"

module Rigor
  class CLI
    # Renders a {FusedProtectionReport} (ADR-70) as text or JSON. The text form leads with the fused protected ratio
    # (caught by *either* a type or a test), splits it into the two axes, then lists the unprotected breakages ("add a
    # type or a test here") and the least-protected files. The framing is always *where to add protection*, never "your
    # code is broken".
    class FusedProtectionRenderer
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
        pct = report.ratio ? (report.ratio * 100).round(1) : nil
        @out.puts "Fused protection (static type ∪ dynamic test)"
        @out.puts "  protected: #{report.protected_total} / #{report.grand_total}#{ratio_suffix(pct)}"
        @out.puts "    by type:  #{report.total_type_killed}"
        @out.puts "    by test:  #{report.total_test_killed}  (type-survivors a test caught)"
        @out.puts "  unprotected: #{report.total_unprotected}  (neither — add a type or a test)"
        render_unmeasured_files(report)
        render_harness_errors(report)
        render_unprotected(report)
        render_files(report)
      end

      # Issue #686 — see {MutationProtectionRenderer#ratio_suffix}.
      def ratio_suffix(pct)
        return "  (not measured)" if pct.nil?

        "  (#{pct}%)"
      end

      # Issue #686 — see {MutationProtectionRenderer#render_unmeasured_files}.
      def render_unmeasured_files(report)
        count = report.unmeasured_files
        return if count.zero?

        @out.puts "  unmeasured files: #{count} — every mutation of them failed inside the measurement " \
                  "harness, so they are not in the ratio above"
      end

      # #264 — see {MutationProtectionRenderer#render_harness_errors}; surfaced only when non-zero.
      def render_harness_errors(report)
        count = report.total_harness_errors
        return if count.zero?

        @out.puts "  harness errors: #{count} mutant(s) failed inside the measurement harness " \
                  "(excluded from the ratio — see --format=json's \"harness_errors\")"
      end

      def render_unprotected(report)
        unprotected = report.unprotected
        return if unprotected.empty?

        @out.puts "\nAdd protection here — breakages neither a type nor a test caught:"
        unprotected.first(TOP_CALLS).each do |call|
          @out.puts format("  %<count>-5d #%<method>s   e.g. %<sites>s",
                           count: call.count, method: call.method_name, sites: call.examples.join("  "))
        end
        @out.puts "  (#{unprotected.size - TOP_CALLS} more)" if unprotected.size > TOP_CALLS
      end

      def render_files(report)
        worst = report.files.reject { |f| f.unprotected.zero? }.sort_by(&:ratio).first(TOP_FILES)
        return if worst.empty?

        @out.puts "\nLeast-protected files:"
        worst.each do |file|
          total = file.type_killed + file.test_killed + file.unprotected
          protected_n = file.type_killed + file.test_killed
          @out.puts format("  %<pct>5.1f%%  %<path>s  (%<n>d/%<total>d protected)",
                           pct: file.ratio * 100, path: file.path, n: protected_n, total: total)
        end
      end
    end
  end
end
