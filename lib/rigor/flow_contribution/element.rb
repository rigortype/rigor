# frozen_string_literal: true

module Rigor
  class FlowContribution
    # Tagged element flattening of a {FlowContribution} bundle —
    # the analyzer-internal representation [ADR-2 § "Flow
    # Contribution Bundle"](../../../docs/adr/2-extension-api.md)
    # routes through the {Merger}.
    #
    # The flattening is **mechanical, deterministic, and round-
    # trippable** with the bundle: every non-empty slot expands
    # into one or more elements keyed by `(target, edge, kind)`,
    # and an array of elements rebuilds an equivalent bundle when
    # routed through `Merger.merge`.
    #
    # Plugin authors should not depend on the element shape — the
    # bundle is the public contract; the element list is the
    # implementation surface the merge policy operates over.
    ELEMENT_VALID_EDGES = %i[normal truthy falsey post_return exceptional].freeze
    ELEMENT_VALID_KINDS = %i[
      return_type
      truthy_fact
      falsey_fact
      post_return_fact
      mutation
      invalidation
      exception
      role
    ].freeze

    Element = Data.define(:target, :edge, :kind, :payload, :provenance) do
      def initialize(target:, edge:, kind:, payload:, provenance:)
        unless ELEMENT_VALID_EDGES.include?(edge)
          raise ArgumentError,
                "FlowContribution::Element edge must be one of " \
                "#{ELEMENT_VALID_EDGES.inspect}, got #{edge.inspect}"
        end

        unless ELEMENT_VALID_KINDS.include?(kind)
          raise ArgumentError,
                "FlowContribution::Element kind must be one of " \
                "#{ELEMENT_VALID_KINDS.inspect}, got #{kind.inspect}"
        end

        super
      end

      def merge_key
        [target, edge, kind]
      end
    end
  end
end
