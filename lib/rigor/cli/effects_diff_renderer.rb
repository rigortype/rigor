# frozen_string_literal: true

require "json"

require_relative "../effects/definition_lines"
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
    # It is deliberately not a diagnostic format: no severities and no exit-code weight of its own — the
    # exit code comes from the gate. A row carries a position for a reader to jump to, never one a
    # `# rigor:disable` or a baseline could act on.
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
      #   A drift row names `file:line` so a reviewer does not have to search for the method (#435). The
      #   file rides the cached summary entry and is free; the line is resolved by parsing the row's own
      #   file ({Effects::DefinitionLines}), which is why a fresh report — no rows — still parses nothing
      #   and the whole-project parse ADR-104 removed from this command stays removed.
      # @param lines [Effects::DefinitionLines] seam for the specs; the default parses on demand.
      def initialize(out:, path:, sources: nil, lines: Effects::DefinitionLines.new)
        @out = out
        @path = path
        @sources = sources || {}
        @lines = lines
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

      # One parenthetical, never two: where the unit is defined, and — under `tolerated:`, which pools
      # both tables — which table the event came from. A row with no known source under `tolerated:`
      # renders exactly as it did before this suffix existed.
      #
      # A unit defined by a reopening spans several files and the row names them all rather than picking
      # one; which of them a reviewer wants is exactly what the row cannot know.
      def annotation(event, qualified)
        parts = sources_of(event.symbol).map { |path, line| line ? "#{path}:#{line}" : path }
        parts << event.table if qualified
        parts.empty? ? "" : "  (#{parts.join(', ')})"
      end

      # Where a symbol is defined, as the two renderings share it — one implementation, so the text form
      # and the JSON one cannot disagree about a position (WD3's rule).
      #
      # **A removed symbol has no entry here at all**, and cannot: `sources` is the CURRENT run's, and a
      # method that no longer exists was not defined by it. Such a row renders exactly as it did before
      # this suffix existed.
      #
      # @return [Array<Array(String, Integer)>] `[relative path, line]` per file, the line nil when that
      #   file spells the key with no `def` — an accessor, or a definition the nesting cannot name.
      def sources_of(symbol)
        Array(@sources[symbol]).map do |path|
          [Effects::Snapshot.relativize(path, Dir.pwd), @lines.for(key: symbol, path: path)]
        end
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

      # The machine form carries the same position the text one prints (#435): a bot that annotates a pull
      # request is the consumer with the most use for a line and the least ability to find one itself.
      # `sources` is omitted rather than emitted empty when the row names nothing — a removed symbol.
      def event_json(event)
        row = event.to_h
        sources = sources_of(event.symbol)
        return row if sources.empty?

        row.merge("sources" => sources.map do |path, line|
          line ? { "path" => path, "line" => line } : { "path" => path }
        end)
      end

      def render_json(diff)
        @out.puts(JSON.pretty_generate(
                    "fresh" => diff.fresh?,
                    "events" => diff.events.map { |event| event_json(event) },
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
