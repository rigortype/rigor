# frozen_string_literal: true

module Rigor
  class FlowContribution
    # Result of folding any number of {FlowContribution} bundles
    # through {Merger.merge}. Surfaces the merged content slot-by-
    # slot, the ordered list of contributing provenances, and the
    # {Conflict} list collected along the way.
    #
    # The merge result is a sibling shape of {FlowContribution} —
    # the analyzer reads from it to drive narrowing / dispatch /
    # diagnostics, and the formatter reads from it to surface
    # plugin / RBS::Extended provenance. The shape is derived per
    # ADR-2 § "Plugin Contribution Merging"; see
    # [`docs/internal-spec/flow-contribution-merger.md`](../../../docs/internal-spec/flow-contribution-merger.md)
    # for the slice-3 normative description.
    class MergeResult
      attr_reader :return_type, :truthy_facts, :falsey_facts, :post_return_facts,
                  :mutations, :invalidations, :exceptional, :role_conformance,
                  :provenances, :conflicts

      # rubocop:disable Metrics/ParameterLists
      def initialize(return_type: nil, truthy_facts: [], falsey_facts: [],
                     post_return_facts: [], mutations: [], invalidations: [],
                     exceptional: nil, role_conformance: [],
                     provenances: [], conflicts: [])
        # rubocop:enable Metrics/ParameterLists
        @return_type = return_type
        @truthy_facts = truthy_facts.dup.freeze
        @falsey_facts = falsey_facts.dup.freeze
        @post_return_facts = post_return_facts.dup.freeze
        @mutations = mutations.dup.freeze
        @invalidations = invalidations.dup.freeze
        @exceptional = exceptional
        @role_conformance = role_conformance.dup.freeze
        @provenances = provenances.dup.freeze
        @conflicts = conflicts.dup.freeze
        freeze
      end

      def conflict?
        !@conflicts.empty?
      end

      def empty?
        @return_type.nil? && @truthy_facts.empty? && @falsey_facts.empty? &&
          @post_return_facts.empty? && @mutations.empty? && @invalidations.empty? &&
          @exceptional.nil? && @role_conformance.empty?
      end

      def to_h
        {
          "return_type" => return_type,
          "truthy_facts" => truthy_facts,
          "falsey_facts" => falsey_facts,
          "post_return_facts" => post_return_facts,
          "mutations" => mutations,
          "invalidations" => invalidations,
          "exceptional" => exceptional,
          "role_conformance" => role_conformance,
          "provenances" => provenances.map { |p| p.respond_to?(:to_h) ? p.to_h : p },
          "conflicts" => conflicts.map(&:to_h)
        }
      end
    end
  end
end
