# frozen_string_literal: true

require_relative "conflict"
require_relative "fact"
require_relative "merge_result"

module Rigor
  class FlowContribution
    # Composes any number of {FlowContribution} bundles into a
    # single {MergeResult} per ADR-2 § "Plugin Contribution
    # Merging". The merger is the **single point of integration**
    # the analyzer uses to combine contributions from built-in
    # narrowing rules, `RBS::Extended` annotations, and plugins;
    # slice 4 routes the existing internal narrowing through it
    # and slice 6 wires plugin-side cache producers around it.
    #
    # ## Authority tiers
    #
    # - Tier 0: `:builtin` — Core Ruby semantics and accepted RBS
    #   contracts. Authoritative; lower tiers may not contradict.
    # - Tier 1: `:rbs_extended` (`RBS::Extended` directive bundles,
    #   v0.0.9 group D reference impl) and `:generated` (generated
    #   signatures / metadata).
    # - Tier 2: `:plugin` and `plugin.<id>` source families.
    # - Tier 3: anything else — treated as the lowest tier.
    #
    # Within a tier, contributions are merged in deterministic
    # order: provenance-supplied `plugin_id` alphabetical (nil
    # plugin ids sort first to keep `:rbs_extended` / `:generated`
    # pre-plugin contributions stable), then by their original
    # input position as the final tie-break.
    #
    # ## Composition rules (ADR-2)
    #
    # - `:return_type` — Intersect via `Type::Combinator.intersection`;
    #   collapse to bot raises `:return_type_collapse`.
    # - `:truthy_fact` / `:falsey_fact` / `:post_return_fact` —
    #   Edge-local; accumulate while deduping by payload equality.
    # - `:mutation` / `:invalidation` / `:role` — Union; dedupe by
    #   equality.
    # - `:exception` — Single-valued. Two non-`nil` non-equal
    #   exceptional effects raise `:exceptional_disagreement`.
    #
    # ## Cross-tier contradictions
    #
    # Lower tiers may refine higher tiers but must not weaken them.
    # Slice 3 surfaces contradictions through `:lower_tier_contradiction`
    # when:
    #
    # - the higher tier already pinned a `return_type` and a lower
    #   tier's intersection collapses to `bot`;
    # - the higher tier set `exceptional` to a non-`nil` value and a
    #   lower tier disagrees.
    #
    # In every conflict case the result keeps the higher-tier value
    # for that slot, records a {Conflict} with both provenances, and
    # continues processing the remaining slots / contributions.
    module Merger # rubocop:disable Metrics/ModuleLength
      AUTHORITY_TIERS = {
        builtin: 0,
        rbs_extended: 1,
        generated: 1
      }.freeze

      module_function

      # @param contributions [Array<FlowContribution>]
      # @return [MergeResult]
      def merge(contributions)
        contributions = Array(contributions)
        return MergeResult.new if contributions.empty?

        ordered = order_contributions(contributions)
        state = MergeState.new
        ordered.each do |contribution|
          tier = tier_for(contribution.provenance)
          fold_into(state, contribution, tier)
        end
        state.to_result
      end

      def tier_for(provenance)
        family = provenance.respond_to?(:source_family) ? provenance.source_family : nil
        return AUTHORITY_TIERS[family] if AUTHORITY_TIERS.key?(family)
        return 2 if family == :plugin || family.to_s.start_with?("plugin.")

        3
      end

      class << self
        private

        def order_contributions(contributions)
          # Stable sort: tier ascending, then provenance plugin_id
          # alphabetical (nil first), then original input position.
          contributions.each_with_index
                       .sort_by { |c, i| [tier_for(c.provenance), plugin_id_key(c.provenance), i] }
                       .map { |c, _| c }
        end

        def plugin_id_key(provenance)
          id = provenance.respond_to?(:plugin_id) ? provenance.plugin_id : nil
          [id.nil? ? 0 : 1, id.to_s]
        end

        def fold_into(state, contribution, tier)
          state.add_provenance(contribution.provenance)
          fold_return_type(state, contribution, tier)
          fold_facts(state, contribution)
          fold_effects(state, contribution)
          fold_exceptional(state, contribution, tier)
          fold_role_conformance(state, contribution)
        end

        def fold_return_type(state, contribution, tier) # rubocop:disable Metrics/AbcSize
          incoming = contribution.return_type
          return if incoming.nil?

          if state.return_type.nil?
            state.return_type = incoming
            state.return_type_tier = tier
            state.return_type_provenance = contribution.provenance
            return
          end

          if intersection_empty?(state.return_type, incoming)
            reason = tier > state.return_type_tier ? :lower_tier_contradiction : :return_type_collapse
            state.conflicts << build_conflict(
              target: :return,
              edge: :normal,
              kind: :return_type,
              reason: reason,
              provenances: [state.return_type_provenance, contribution.provenance],
              message: return_type_conflict_message(reason, state.return_type, incoming)
            )
            return
          end

          state.return_type = Rigor::Type::Combinator.intersection(state.return_type, incoming)
          state.return_type_tier = [state.return_type_tier, tier].min
        end

        # Two types' intersection collapses to bot when neither
        # accepts the other under gradual mode — i.e. the value
        # domains are disjoint. `Rigor::Type::Combinator.intersection`
        # itself does not collapse incompatible nominals (`String ∩
        # Integer` builds a structurally-empty `Intersection`
        # carrier), so the merger checks the disjointness condition
        # directly via the `accepts` trinary.
        def intersection_empty?(lhs, rhs)
          return false if lhs.equal?(rhs)

          lhs_no = lhs.accepts(rhs).no?
          rhs_no = rhs.accepts(lhs).no?
          lhs_no && rhs_no
        rescue StandardError
          false
        end

        def fold_facts(state, contribution)
          accumulate(state.truthy_facts, contribution.truthy_facts)
          accumulate(state.falsey_facts, contribution.falsey_facts)
          accumulate(state.post_return_facts, contribution.post_return_facts)
        end

        def fold_effects(state, contribution)
          accumulate(state.mutations, contribution.mutations)
          accumulate(state.invalidations, contribution.invalidations)
        end

        def fold_exceptional(state, contribution, tier)
          incoming = contribution.exceptional
          return if incoming.nil?

          if state.exceptional.nil?
            state.exceptional = incoming
            state.exceptional_tier = tier
            state.exceptional_provenance = contribution.provenance
            return
          end

          return if state.exceptional == incoming

          reason = tier > state.exceptional_tier ? :lower_tier_contradiction : :exceptional_disagreement
          state.conflicts << build_conflict(
            target: :raise,
            edge: :exceptional,
            kind: :exception,
            reason: reason,
            provenances: [state.exceptional_provenance, contribution.provenance],
            message: "exceptional effect disagreement: #{state.exceptional.inspect} vs #{incoming.inspect}"
          )
        end

        def fold_role_conformance(state, contribution)
          accumulate(state.role_conformance, contribution.role_conformance)
        end

        def accumulate(target, incoming)
          Array(incoming).each do |item|
            target << item unless target.include?(item)
          end
        end

        def build_conflict(target:, edge:, kind:, reason:, provenances:, message:) # rubocop:disable Metrics/ParameterLists
          Conflict.new(target: target, edge: edge, kind: kind, reason: reason,
                       provenances: provenances, message: message)
        end

        def return_type_conflict_message(reason, lhs, rhs)
          case reason
          when :return_type_collapse
            "return-type intersection collapses to bot: #{describe(lhs)} vs #{describe(rhs)}"
          when :lower_tier_contradiction
            "lower-tier return-type #{describe(rhs)} contradicts higher-tier proof #{describe(lhs)}"
          end
        end

        def describe(type)
          if type.respond_to?(:describe)
            type.describe(:short)
          else
            type.inspect
          end
        rescue StandardError
          type.inspect
        end
      end

      # Internal accumulator carried through a single merge call.
      # Not part of the public API; folds into a {MergeResult} at
      # the end via {#to_result}.
      class MergeState
        attr_accessor :return_type, :return_type_tier, :return_type_provenance,
                      :exceptional, :exceptional_tier, :exceptional_provenance
        attr_reader :truthy_facts, :falsey_facts, :post_return_facts,
                    :mutations, :invalidations, :role_conformance,
                    :provenances, :conflicts

        def initialize
          @return_type = nil
          @return_type_tier = nil
          @return_type_provenance = nil
          @truthy_facts = []
          @falsey_facts = []
          @post_return_facts = []
          @mutations = []
          @invalidations = []
          @exceptional = nil
          @exceptional_tier = nil
          @exceptional_provenance = nil
          @role_conformance = []
          @provenances = []
          @conflicts = []
        end

        def add_provenance(provenance)
          @provenances << provenance
        end

        def to_result
          MergeResult.new(
            return_type: @return_type,
            truthy_facts: @truthy_facts,
            falsey_facts: @falsey_facts,
            post_return_facts: @post_return_facts,
            mutations: @mutations,
            invalidations: @invalidations,
            exceptional: @exceptional,
            role_conformance: @role_conformance,
            provenances: @provenances,
            conflicts: @conflicts
          )
        end
      end
      private_constant :MergeState
    end
  end
end
