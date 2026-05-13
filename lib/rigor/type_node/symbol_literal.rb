# frozen_string_literal: true

module Rigor
  module TypeNode
    # Symbol-literal AST node. Used as a {Generic#args} entry for
    # parametric forms whose argument is a Symbol literal — namely
    # `Pick[T, :name]`, `pick_of[Shape, :a | :b]`, and downstream
    # plugin resolvers that accept literal key selectors.
    #
    # ADR-13 follow-up (`docs/CURRENT_WORK.md` engineering item
    # #2): the RBS::Extended grammar previously could not tokenise
    # `:name` inside a type-arg position; this addition closes the
    # gap so `ImportedRefinements.parse` produces a uniform AST.
    # The resolver translates this node to a `Type::Constant`
    # carrying the symbol value.
    class SymbolLiteral < Data.define(:value)
      def initialize(value:)
        unless value.is_a?(Symbol)
          raise ArgumentError,
                "TypeNode::SymbolLiteral value must be a Symbol, " \
                "got #{value.inspect}"
        end

        super
      end
    end
  end
end
