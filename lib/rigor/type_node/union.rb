# frozen_string_literal: true

module Rigor
  module TypeNode
    # Union AST node. Carries the nodes of a `T1 | T2 | …` union
    # expression authored at type-arg position.
    #
    # ADR-13 follow-up (`docs/CURRENT_WORK.md` engineering item
    # #2): together with {SymbolLiteral} / {StringLiteral} this
    # closes the parser-side gap that prevented `Pick[T, :a | :b]`
    # / `Pick[T, "a" | "b"]` from tokenising. The resolver pass
    # recurses through each node and folds them via
    # `Type::Combinator.union`.
    #
    # The field is named `:nodes` (not `:members`) to avoid
    # shadowing `Data#members`, which is the introspection method
    # every `Data.define` mix-in inherits.
    #
    # Nodes are themselves any of the {TypeNode} carriers — the
    # parser builds a flat list (left-associative); nested
    # `Union` nodes are permitted but the parser does not
    # synthesise them by itself.
    class Union < Data.define(:nodes)
      def initialize(nodes:)
        unless nodes.is_a?(Array) && nodes.size >= 2 && nodes.all? { |m| valid_member?(m) }
          raise ArgumentError,
                "TypeNode::Union nodes must be an Array (size >= 2) of " \
                "TypeNode carriers, got #{nodes.inspect}"
        end

        super(nodes: nodes.freeze)
      end

      private

      def valid_member?(node)
        node.is_a?(Identifier) || node.is_a?(Generic) || node.is_a?(IntegerLiteral) ||
          node.is_a?(IndexedAccess) || node.is_a?(SymbolLiteral) || node.is_a?(StringLiteral)
      end
    end
  end
end
