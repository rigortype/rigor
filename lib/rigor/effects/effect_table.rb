# frozen_string_literal: true

require_relative "label_set"
require_relative "summary"

module Rigor
  module Effects
    # The whole-project effect graph after propagation: every method key the run collected, with its
    # direct summary and its transitive closure (ADR-103 WD12).
    #
    # An EffectTable is **not a diagnostic and never enters `rigor check`'s stream**. It hangs off the
    # runner for the report of this slice and the snapshot of #381 to read, exactly as
    # [ADR-102](../adr/102-unused-code-reachability-report.md) draws the report-versus-diagnostic line.
    class EffectTable
      # One method's row.
      #
      # `direct` is the {Summary} the collector produced for this method's own body — what a snapshot
      # records, because a diff over direct summaries stays attributable to the pull request's own lines.
      # `proven` / `exhaustive` / `causes` are the transitive readings: this method's own labels joined
      # with every project method it reaches, and the exhaustiveness bit ANDed along the same edges.
      #
      # `undischarged` is the same transitive reading with the origin bundles `effects.tolerated:`
      # discharges removed at their source (#385; {Discharge}) — what a *judgment* reads, where `proven`
      # is what the record holds. The two are the same set for a project that tolerates nothing, and
      # `--no-tolerated-effects` is the switch that makes a judgment read `proven` anyway.
      class Entry < Data.define(:key, :direct, :proven, :undischarged, :exhaustive, :causes, :edges)
        def initialize(undischarged: nil, **rest)
          super(undischarged: undischarged || rest.fetch(:proven), **rest)
        end

        def exhaustive?
          exhaustive
        end

        # Whether the report omits this row by default: exhaustive, and proving nothing beyond frame-local
        # mutation. `--full` lists it anyway.
        def trivial?
          exhaustive && proven.subsumed_by?(Summary::TRIVIAL_BOUND)
        end
      end

      EMPTY_ENTRIES = {}.freeze
      private_constant :EMPTY_ENTRIES

      def self.empty
        @empty ||= new(EMPTY_ENTRIES)
      end

      # @param entries [Hash{String => Entry}]
      def initialize(entries)
        @entries = entries.sort_by { |key, _| key }.to_h.freeze
        freeze
      end

      def [](key)
        @entries[key]
      end

      def keys
        @entries.keys
      end

      def each(&)
        @entries.each_value(&)
      end
      include Enumerable

      def size
        @entries.size
      end

      def empty?
        @entries.empty?
      end
    end
  end
end
