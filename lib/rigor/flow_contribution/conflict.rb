# frozen_string_literal: true

module Rigor
  class FlowContribution
    # Records a contradiction between two or more flow contributions
    # detected during {Merger.merge}. Carried on {MergeResult#conflicts}
    # so the analyzer / formatter can surface a `:contribution_merge`
    # diagnostic per ADR-2 § "Plugin Contribution Merging".
    #
    # ADR-2 § "Plugin Contribution Merging" rules out first-wins /
    # last-wins behaviour: when contributions conflict, both sources
    # are reported and the merger falls back to the nearest non-
    # conflicting higher-tier (or default) value for the affected
    # `(target, edge, kind)` slot. The conflict object is the
    # carrier of that report.
    #
    # Slice-3 conflict reasons:
    #
    # - `:return_type_collapse` — two return-type contributions
    #   intersect to `bot`.
    # - `:exceptional_disagreement` — two contributions assert
    #   incompatible non-`nil` exceptional effects.
    # - `:lower_tier_contradiction` — a lower-tier contribution
    #   would weaken or contradict a higher-tier proof.
    CONFLICT_VALID_REASONS = %i[
      return_type_collapse
      exceptional_disagreement
      lower_tier_contradiction
    ].freeze

    Conflict = Data.define(:target, :edge, :kind, :reason, :provenances, :message) do
      def initialize(target:, edge:, kind:, reason:, provenances:, message:) # rubocop:disable Metrics/ParameterLists
        unless CONFLICT_VALID_REASONS.include?(reason)
          raise ArgumentError,
                "FlowContribution::Conflict reason must be one of " \
                "#{CONFLICT_VALID_REASONS.inspect}, got #{reason.inspect}"
        end

        super(target: target, edge: edge, kind: kind, reason: reason,
              provenances: provenances.dup.freeze, message: message.to_s.dup.freeze)
      end

      def to_h
        {
          "target" => target.to_s,
          "edge" => edge.to_s,
          "kind" => kind.to_s,
          "reason" => reason.to_s,
          "sources" => provenances.map { |p| p.respond_to?(:to_h) ? p.to_h : p.to_s },
          "message" => message
        }
      end
    end
  end
end
