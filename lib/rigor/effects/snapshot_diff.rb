# frozen_string_literal: true

require_relative "label_set"
require_relative "snapshot"

module Rigor
  module Effects
    # Compares a committed {Snapshot} with the one this run computes, and judges the difference
    # (ADR-103 WD7; the event vocabulary is design note § 9.4).
    #
    # The comparison itself is exact — drift between two observations by the same tool is 100 % precise.
    # What is *judged* is whether the drift matters, and that has two knobs, applied here and never while
    # writing the record:
    #
    # - the **gate**. `symmetric` (the default) fails on any drift, the `db/schema.rb` model: a removal is
    #   news too, because a job that stopped enqueueing is a bug rather than an improvement. `additions`
    #   is the ratchet: only growth fails.
    # - the **tolerated set**. An event whose labels are all admitted by `effects.tolerated:` is reported
    #   under its own heading and does not fail the gate unless `strict_tolerated:` is set.
    #
    # **Additions are judged per origin; removals by label.** The file is flat — origins are `explain`'s
    # job and a record keyed by them would churn on every refactor — but the *current* side of a
    # comparison is a live effect table, so the caller can hand over `undischarged:`, the labels that
    # survive per-origin discharge for each current symbol (#385). An added label is then tolerated
    # exactly when every origin that introduces it is discharged, which is the same answer the envelope
    # check gives, rather than the coarser "the label is on the list". A **removal** has no current-side
    # origins to consult — the thing that produced it is gone — so it stays judged by label. Without the
    # index (a caller that has no table, and every parse-only spec) both fall back to the label reading.
    #
    # A header mismatch is neither: it is a **regeneration event** — the record was written by a different
    # Rigor, a different vocabulary or a different `effects:` block, so the two sides are not comparable
    # in the first place. It fails under both gates, because there is nothing to ratchet against.
    class SnapshotDiff
      # Categories, in the order a text rendering emits them. The strings are the JSON contract.
      MISSING_SNAPSHOT = "missing-snapshot"
      REGENERATION = "regeneration"
      SYMBOL_ADDED = "symbol-added"
      SYMBOL_REMOVED = "symbol-removed"
      LABEL_ADDED = "label-added"
      LABEL_REMOVED = "label-removed"
      DECLARED_ADDED = "declared-added"
      DECLARED_REMOVED = "declared-removed"
      MATERIALISED = "materialised"
      EXHAUSTIVE_LOST = "exhaustive-lost"
      EXHAUSTIVE_GAINED = "exhaustive-gained"

      # What the `additions` ratchet still fails on: growth in either lane, a new symbol, and a method
      # that stopped being exhaustive (someone introduced a call the analyzer cannot follow — the one
      # "removal-shaped" change that is unambiguously a loss of knowledge).
      ADDITIVE_CATEGORIES = [SYMBOL_ADDED, LABEL_ADDED, DECLARED_ADDED, EXHAUSTIVE_LOST,
                             MISSING_SNAPSHOT, REGENERATION].freeze

      TABLES = %w[methods reach].freeze

      # One difference.
      #
      # `symbol` is the method key (nil for a header event), `label` the label it is about (nil for the
      # symbol- and exhaustiveness-shaped ones), `detail` any extra the renderer prints verbatim, and
      # `tolerated` whether policy discharged it.
      class Event < Data.define(:category, :symbol, :label, :table, :tolerated, :detail, :hedged)
        def tolerated?
          tolerated
        end

        # Whether the current side could not prove an absence. A removal read off a non-exhaustive summary
        # is rendered hedged — "possibly more" cannot prove that something stopped happening.
        def hedged?
          hedged
        end

        def to_h
          row = { "category" => category, "symbol" => symbol, "table" => table, "tolerated" => tolerated }
          row["label"] = label if label
          row["detail"] = detail if detail
          row["hedged"] = true if hedged
          row
        end
      end

      # The categories the per-origin judgment is exact for: both are additions in the PROVEN lane, so the
      # current side's undischarged labels answer them directly. The declared lane's additions are not
      # here — nothing declared has a proven origin to discharge.
      ORIGIN_JUDGED_CATEGORIES = [SYMBOL_ADDED, LABEL_ADDED].freeze
      private_constant :ORIGIN_JUDGED_CATEGORIES

      # Compares `current` against `recorded`. `recorded` may be nil — no snapshot on disk at all, which
      # is drift with a routed message rather than an error.
      #
      # @param undischarged [Hash] `{table name => {symbol => [label]}}` — the current side's labels that
      #   survive per-origin discharge ({Snapshot.undischarged_index}). Optional; omitting it judges every
      #   event by label.
      def self.compare(recorded:, current:, tolerated: [], gate: :symmetric, strict_tolerated: false,
                       undischarged: nil)
        new(recorded: recorded, current: current, tolerated: tolerated, gate: gate,
            strict_tolerated: strict_tolerated, undischarged: undischarged)
      end

      attr_reader :events, :recorded, :current, :gate

      def initialize(recorded:, current:, tolerated: [], gate: :symmetric, strict_tolerated: false,
                     undischarged: nil)
        @recorded = recorded
        @current = current
        @gate = gate
        @strict_tolerated = strict_tolerated
        @tolerated = LabelSet.new(tolerated)
        @undischarged = undischarged
        @added_symbols = 0
        @removed_symbols = 0
        @events = build_events.freeze
        freeze
      end

      # Whether the record matches what this run computed. A tolerated-only difference is NOT fresh — the
      # file still needs regenerating — it merely does not fail the gate.
      def fresh?
        @events.empty?
      end

      # Whether `rigor effects check` exits non-zero.
      def drift?
        @events.any? { |event| gating?(event) }
      end

      # Renames are a removal plus an addition and are never reported as a lost effect; the footer is
      # where the reviewer sees that the two counts balance.
      def footer
        { added_symbols: @added_symbols, removed_symbols: @removed_symbols }
      end

      def events_for(table)
        @events.select { |event| event.table == table && !event.tolerated? }
      end

      def tolerated_events
        @events.select(&:tolerated?)
      end

      private

      def gating?(event)
        return false if event.tolerated? && !@strict_tolerated
        return true if @gate == :symmetric

        ADDITIVE_CATEGORIES.include?(event.category)
      end

      def build_events
        return [missing_snapshot_event] if @recorded.nil?

        header_events + TABLES.flat_map { |table| table_events(table) }
      end

      def missing_snapshot_event
        event(MISSING_SNAPSHOT, symbol: nil, table: "snapshot",
                                detail: "no snapshot; run `rigor effects update`")
      end

      # The header says which record this is. A mismatch on any of its four fields means the recorded
      # sets were computed under different rules, so every downstream comparison would be noise.
      def header_events
        %w[schema rigor vocabulary config_digest].filter_map do |field|
          was = @recorded.header[field]
          now = @current.header[field]
          next if was == now

          event(REGENERATION, symbol: nil, table: "header", detail: "#{field}: #{was.inspect} → #{now.inspect}")
        end
      end

      def table_events(table)
        was = @recorded.table(table)
        now = @current.table(table)
        (was.keys | now.keys).sort.flat_map do |symbol|
          before = was[symbol]
          after = now[symbol]
          if before.nil? then added_symbol(symbol, after, table)
          elsif after.nil? then removed_symbol(symbol, before, table)
          else changed_symbol(symbol, before, after, table)
          end
        end
      end

      def added_symbol(symbol, entry, table)
        @added_symbols += 1
        return [] if quiet?(entry)

        [event(SYMBOL_ADDED, symbol: symbol, table: table, labels: entry.effects,
                             detail: render_labels(entry))]
      end

      def removed_symbol(symbol, entry, table)
        @removed_symbols += 1
        return [] if quiet?(entry)

        [event(SYMBOL_REMOVED, symbol: symbol, table: table, labels: entry.effects,
                               detail: render_labels(entry))]
      end

      # A row carrying nothing — no labels, nothing declared, exhaustive — appears only under `--full`.
      # Its coming and going is not news; the footer still counts it, so a rename still balances.
      def quiet?(entry)
        entry.effects.empty? && entry.declared.empty? && entry.exhaustive?
      end

      def changed_symbol(symbol, before, after, table)
        materialised = before.declared & (after.effects - before.effects)
        lane_events(symbol, before, after, table, materialised) +
          exhaustiveness_events(symbol, before, after, table)
      end

      # The proven and declared lanes, with materialisation lifted out of both: a label that was an
      # authored upper bound and is now proven is ONE event, never a removal plus an addition.
      def lane_events(symbol, before, after, table, materialised)
        [[MATERIALISED, materialised],
         [LABEL_ADDED, after.effects - before.effects - materialised],
         [LABEL_REMOVED, before.effects - after.effects],
         [DECLARED_ADDED, after.declared - before.declared],
         [DECLARED_REMOVED, before.declared - after.declared - materialised]].flat_map do |category, labels|
          hedged = category == LABEL_REMOVED && !after.exhaustive?
          labels.map { |label| event(category, symbol: symbol, table: table, label: label, hedged: hedged) }
        end
      end

      def exhaustiveness_events(symbol, before, after, table)
        return [] if before.exhaustive? == after.exhaustive?

        category = after.exhaustive? ? EXHAUSTIVE_GAINED : EXHAUSTIVE_LOST
        [event(category, symbol: symbol, table: table,
                         detail: after.exhaustive? ? "not → exhaustive" : "exhaustive → not")]
      end

      def render_labels(entry)
        "[#{entry.effects.join(', ')}]#{' …?' unless entry.exhaustive?}"
      end

      # Policy discharge, at judgment time. A single-label event is tolerated when the policy discharges
      # that label; a symbol event when it discharges every label the symbol carries — and never when it
      # carries none, because an empty set is discharged by nothing.
      def event(category, symbol:, table:, label: nil, labels: nil, detail: nil, hedged: false)
        Event.new(category: category, symbol: symbol, label: label, table: table, detail: detail,
                  hedged: hedged, tolerated: tolerated?(category, symbol, table, label, labels))
      end

      def tolerated?(category, symbol, table, label, labels)
        members = labels || (label ? [label] : nil)
        return false if members.nil? || members.empty? || @tolerated.empty?

        surviving = surviving_labels(category, symbol, table)
        return members.none? { |member| surviving.include?(member) } if surviving

        members.all? { |member| @tolerated.admits?(member) }
      end

      # The current side's undischarged labels for one symbol, or nil when this event is not one the
      # per-origin judgment answers — no index, a removal, or a lane with no proven origins.
      def surviving_labels(category, symbol, table)
        return nil if @undischarged.nil? || symbol.nil?
        return nil unless ORIGIN_JUDGED_CATEGORIES.include?(category)

        @undischarged.dig(table, symbol)
      end
    end
  end
end
