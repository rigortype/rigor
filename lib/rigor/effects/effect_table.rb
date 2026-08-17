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
      #
      # `declared` is the transitive `≤` lane: it travels the same edges as `proven` (ADR-103 WD1), so a
      # caller two hops above an attributed gem call reads the claim rather than only the taint it left.
      # The lanes are kept **raw** here — a declared label a proven one already subsumes is dropped where
      # output is rendered ({LabelSet#excluding_subsumed_by}), never in the table, because a further join
      # has to see what was actually declared.
      class Entry < Data.define(:key, :direct, :proven, :undischarged, :declared, :exhaustive, :causes,
                                :edges)
        def initialize(undischarged: nil, declared: nil, **rest)
          super(undischarged: undischarged || rest.fetch(:proven), declared: declared || LabelSet::EMPTY,
                **rest)
        end

        # The declared labels worth printing beside `proven` — the rendering rule, in one place so the
        # report and the snapshot cannot disagree about it.
        def rendered_declared
          declared.excluding_subsumed_by(proven)
        end

        def exhaustive?
          exhaustive
        end

        # Whether the report omits this row by default: exhaustive, proving nothing beyond frame-local
        # mutation, and claiming nothing the proven lane does not already admit ({Summary#trivial?} for
        # the reasoning behind the declared half). `--full` lists it anyway.
        def trivial?
          exhaustive && proven.subsumed_by?(Summary::TRIVIAL_BOUND) && rendered_declared.empty?
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
