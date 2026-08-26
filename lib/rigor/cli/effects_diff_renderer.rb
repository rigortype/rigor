# frozen_string_literal: true

require "json"

require_relative "../effects/snapshot"
require_relative "../effects/snapshot_diff"
require_relative "renderable"

module Rigor
  class CLI
    # Prints a {Rigor::Effects::SnapshotDiff} — what `rigor effects check` and `rigor effects diff` show a
    # reviewer (ADR-103 WD7).
    #
    # The text form is grouped by table and then by policy: real drift under `methods:` / `reach:`,
    # policy-discharged drift under `tolerated:`, and a regeneration event — a record written by a
    # different Rigor, vocabulary or `effects:` block — under `regeneration:` above both. It closes with
    # the one line the whole workflow turns on: intent is expressed by regenerating and committing the
    # file, not by annotating the code.
    #
    # It is deliberately not a diagnostic format: no severities, no positions, no exit-code weight of its
    # own. The exit code comes from the gate.
    class EffectsDiffRenderer
      include Renderable

      # How each category renders as the marker after the symbol. Steins' event vocabulary, made
      # symmetric: `≤` is the declared lane, and a hedged removal says why it is hedged.
      MARKERS = {
        Effects::SnapshotDiff::LABEL_ADDED => "+ %<label>s",
        Effects::SnapshotDiff::LABEL_REMOVED => "- %<label>s",
        Effects::SnapshotDiff::DECLARED_ADDED => "≤+ %<label>s",
        Effects::SnapshotDiff::DECLARED_REMOVED => "≤- %<label>s",
        Effects::SnapshotDiff::MATERIALISED => "materialised %<label>s (declared → proven)",
        Effects::SnapshotDiff::SYMBOL_ADDED => "+symbol %<detail>s",
        Effects::SnapshotDiff::SYMBOL_REMOVED => "-symbol %<detail>s"
      }.freeze

      HEDGED_REMOVAL = "-? %<label>s (current summary is not exhaustive)"

      # Both commands, because they answer the two questions a drift report raises and a reader almost
      # always asks them in this order (#435). `explain` is the one the manual's own narrative reaches for
      # first, and the footer used to name only the one that makes the report go away.
      CLOSING_LINE = "Run `rigor effects explain` to see what caused this, and `rigor effects update` to " \
                     "accept it."

      # A regeneration event routes to `update` alone: `explain` answers "what caused this label to
      # appear", and the answer here is "the record was written under different rules", which explain
      # cannot expand and the line above already said.
      REGENERATION_CLOSING_LINE = "Run `rigor effects update` to regenerate the record under the current " \
                                  "rules."

      # @param sources [Hash{String=>Array<String>}] `Runner#effect_sources` — where each unit is defined.
      #   A drift row names the file so a reviewer does not have to search for the method (#435); it is
      #   the file and not `file:line` because a line would cost a whole-project parse this command no
      #   longer does (ADR-104), and the method key already locates the definition within the file.
      def initialize(out:, path:, sources: nil)
        @out = out
        @path = path
        @sources = sources || {}
      end

      private

      def render_text(diff)
        if diff.fresh?
          @out.puts("No effect drift against #{@path}.")
          return
        end

        @out.puts("Effect drift against #{@path}:")
        %w[snapshot header methods reach].each { |table| render_section(table, diff.events_for(table)) }
        render_section("tolerated", diff.tolerated_events, qualified: true)
        render_footer(diff)
      end

      # `qualified:` names each event's table inline, which the `tolerated:` heading needs: it pools events
      # from both tables, and one symbol commonly appears in each.
      def render_section(table, events, qualified: false)
        return if events.empty?

        @out.puts("")
        @out.puts("#{section_name(table)}:")
        events.each { |event| @out.puts("  #{render_event(event, qualified: qualified)}") }
      end

      def section_name(table)
        case table
        when "header" then "regeneration"
        when "snapshot" then "snapshot"
        else table
        end
      end

      def render_event(event, qualified: false)
        marker = marker_for(event)
        return marker if event.symbol.nil?

        "#{event.symbol}  #{marker}#{annotation(event, qualified)}"
      end

      # One parenthetical, never two: the file the unit is defined in, and — under `tolerated:`, which
      # pools both tables — which table the event came from. A row with no known source under
      # `tolerated:` renders exactly as it did before this suffix existed.
      #
      # A unit defined by a reopening spans several files and the row names them all rather than picking
      # one; which of them a reviewer wants is exactly what the row cannot know.
      def annotation(event, qualified)
        parts = Array(@sources[event.symbol]).map { |path| Effects::Snapshot.relativize(path, Dir.pwd) }
        parts << event.table if qualified
        parts.empty? ? "" : "  (#{parts.join(', ')})"
      end

      def marker_for(event)
        return format(HEDGED_REMOVAL, label: event.label) if
          event.category == Effects::SnapshotDiff::LABEL_REMOVED && event.hedged?

        template = MARKERS[event.category]
        return event.detail.to_s unless template

        format(template, label: event.label.to_s, detail: event.detail.to_s)
      end

      def render_footer(diff)
        footer = diff.footer
        @out.puts("")
        @out.puts(withheld_line(footer)) if diff.regeneration?
        unless footer[:added_symbols].zero? && footer[:removed_symbols].zero?
          @out.puts("symbols: +#{footer[:added_symbols]} / -#{footer[:removed_symbols]} " \
                    "(a rename is one of each)")
        end
        @out.puts(diff.regeneration? ? REGENERATION_CLOSING_LINE : CLOSING_LINE)
      end

      # What a regeneration withheld, said as a count. The counts below it are still printed, so the
      # reader sees the scale of the difference without reading it row by row.
      def withheld_line(footer)
        suppressed = footer[:suppressed]
        return "The two records are not comparable, so no per-method difference is shown." if
          suppressed.zero?

        noun = suppressed == 1 ? "1 per-method difference is" : "#{suppressed} per-method differences are"
        "The two records were computed under different rules and are not comparable, so #{noun} not shown."
      end

      def render_json(diff)
        @out.puts(JSON.pretty_generate(
                    "fresh" => diff.fresh?,
                    "events" => diff.events.map(&:to_h),
                    "footer" => {
                      "added_symbols" => diff.footer[:added_symbols],
                      "removed_symbols" => diff.footer[:removed_symbols],
                      "suppressed" => diff.footer[:suppressed]
                    },
                    "regeneration" => diff.regeneration?,
                    "header" => {
                      "snapshot" => @path,
                      "gate" => diff.gate.to_s,
                      "recorded" => diff.recorded&.header,
                      "current" => diff.current.header
                    }
                  ))
      end
    end
  end
end
