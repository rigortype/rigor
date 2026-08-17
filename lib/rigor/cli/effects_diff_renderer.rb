# frozen_string_literal: true

require "json"

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

      CLOSING_LINE = "Run `rigor effects update` and commit the result if this change is intended."

      def initialize(out:, path:)
        @out = out
        @path = path
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
        events.each do |event|
          suffix = qualified ? "  (#{event.table})" : ""
          @out.puts("  #{render_event(event)}#{suffix}")
        end
      end

      def section_name(table)
        case table
        when "header" then "regeneration"
        when "snapshot" then "snapshot"
        else table
        end
      end

      def render_event(event)
        marker = marker_for(event)
        event.symbol.nil? ? marker : "#{event.symbol}  #{marker}"
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
        unless footer[:added_symbols].zero? && footer[:removed_symbols].zero?
          @out.puts("symbols: +#{footer[:added_symbols]} / -#{footer[:removed_symbols]} " \
                    "(a rename is one of each)")
        end
        @out.puts(CLOSING_LINE)
      end

      def render_json(diff)
        @out.puts(JSON.pretty_generate(
                    "fresh" => diff.fresh?,
                    "events" => diff.events.map(&:to_h),
                    "footer" => {
                      "added_symbols" => diff.footer[:added_symbols],
                      "removed_symbols" => diff.footer[:removed_symbols]
                    },
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
