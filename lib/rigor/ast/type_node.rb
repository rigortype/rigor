# frozen_string_literal: true

module Rigor
  module AST
    # A virtual node that wraps a Rigor::Type. Allows callers to ask
    # "what would the analyzer infer at this position if the value's type
    # were T?" without constructing a real Prism expression.
    #
    # Rigor::Scope#type_of(TypeNode.new(t)) MUST return a structurally-
    # equal t. The engine MUST NOT modify or annotate the wrapped type.
    #
    # Inspired by PHPStan's TypeExpr (a synthetic Expr that returns a
    # specific Type from $scope->getType). The Rigor counterpart is
    # spelled "TypeNode" to align with Prism's "Node" suffix convention.
    class TypeNode
      include Node

      attr_reader :type

      def initialize(type)
        raise ArgumentError, "TypeNode requires a non-nil Rigor::Type" if type.nil?

        @type = type
        freeze
      end

      def ==(other)
        other.is_a?(TypeNode) && type == other.type
      end
      alias eql? ==

      def hash
        [TypeNode, type].hash
      end

      def inspect
        "#<Rigor::AST::TypeNode #{type.describe(:short)}>"
      end
    end
  end
end
