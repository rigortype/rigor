# frozen_string_literal: true

require "json"

require_relative "renderable"

module Rigor
  class CLI
    # Prints an {EffectsReport}. Text is the review surface; JSON is what a bot reads.
    #
    # The text form says three things per method and nothing else: what it is proven to do, what a source
    # Rigor trusts merely *claims* it does (`≤`, the declared lane), and whether the list is complete. The
    # `…?` suffix is the exhaustiveness bit — "these effects, and possibly more" — and the indented lines
    # under it are the closed-enum causes behind it. Deliberately not a diagnostic format: no severities,
    # no positions, no exit-code weight.
    class EffectsRenderer
      include Renderable

      def initialize(out:, why: false)
        @out = out
        @why = why
      end

      private

      # The reason block is **collapsed to a count** by default (#434). It was 86.5 % of the bytes of a
      # 31,191-line Redmine run, and it answers a question a reader asks about one row after reading many
      # — so `--why` expands it, and the count is what stays on the line that made them curious.
      def render_text(report)
        report.rows.each do |row|
          @out.puts("#{row.key}: [#{row.effects.join(', ')}]#{declared(row)}#{hedge(row)}")
          next unless @why

          row.causes.each { |cause, detail| @out.puts("    #{cause}#{" (#{detail})" if detail}") }
          row.attribution.each { |origin, labels| @out.puts("    #{origin} → [#{labels.join(', ')}]") }
        end
        render_footer(report.totals)
      end

      def hedge(row)
        return "" if row.exhaustive?
        return " …?" if @why || row.causes.empty?

        " …? (#{row.causes.length} #{row.causes.length == 1 ? 'reason' : 'reasons'}, --why)"
      end

      # The footer a 31,191-line report never had, and the reason it counts the two lanes apart: a
      # declared label can never fail a build (ADR-103 § WD17), so a reader who sees one total cannot tell
      # which half of the report is a policy surface and which half is a record to review the diff of.
      def render_footer(totals)
        return if totals.nil?

        @out.puts("──")
        @out.puts("#{totals.printed} of #{totals.units} units printed#{omitted(totals)}")
        @out.puts("#{totals.proven} carry a proven label · #{totals.declared} carry a declared (≤) one " \
                  "· #{totals.exhaustive} are exhaustive")
      end

      # Two ways a row can be missing, counted apart because `--full` answers only one of them.
      def omitted(totals)
        parts = []
        parts << "#{totals.omitted} omitted (--full)" if totals.omitted.positive?
        parts << "#{totals.unselected} not selected" if totals.unselected.positive?
        parts << "#{totals.truncated} cut by --limit" if totals.truncated.positive?
        parts.empty? ? "" : "; #{parts.join(', ')}"
      end

      # `≤` is the lane's spelling everywhere in the model — an upper bound, not an observation — so the
      # report writes it rather than inventing a second word for it.
      def declared(row)
        row.declared.empty? ? "" : " ≤ [#{row.declared.join(', ')}]"
      end

      def render_json(report)
        payload = {
          "methods" => report.rows.to_h do |row|
            [row.key, {
              "effects" => row.effects,
              "declared" => row.declared,
              "exhaustive" => row.exhaustive?,
              "causes" => row.causes.map { |cause, detail| [cause, detail] },
              "direct" => row.direct,
              "attribution" => row.attribution
            }]
          end
        }
        payload["totals"] = report.totals.to_h.transform_keys(&:to_s) if report.totals
        @out.puts(JSON.pretty_generate(payload))
      end
    end
  end
end
