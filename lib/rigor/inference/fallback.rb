# frozen_string_literal: true

module Rigor
  module Inference
    FALLBACK_FAMILIES = %i[prism virtual].freeze
    private_constant :FALLBACK_FAMILIES

    # Immutable value object recorded by the typer whenever Scope#type_of
    # falls back to Dynamic[Top] for a node it does not yet recognise. The
    # contract for emitting these events lives in
    # docs/internal-spec/inference-engine.md (Fail-Soft Policy).
    #
    # Fields:
    # - node_class: the Ruby class of the node that triggered the
    #   fallback (e.g. Prism::CallNode, or a Rigor::AST::Node subclass).
    # - location: the Prism source location for real Prism nodes, or
    #   nil for synthetic nodes.
    # - family: :prism for real Prism nodes, :virtual for nodes
    #   that include Rigor::AST::Node.
    # - inner_type: the Rigor::Type returned to the caller (currently
    #   always Dynamic[Top]; later slices may carry richer fallback
    #   types).
    Fallback = Data.define(:node_class, :location, :family, :inner_type) do
      def initialize(node_class:, location:, family:, inner_type:)
        raise ArgumentError, "node_class must be a Class, got #{node_class.class}" unless node_class.is_a?(Class)

        unless FALLBACK_FAMILIES.include?(family)
          raise ArgumentError, "family must be one of #{FALLBACK_FAMILIES.inspect}, got #{family.inspect}"
        end

        super
      end
    end
  end
end
