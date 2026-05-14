# frozen_string_literal: true

module Rigor
  module TypeNode
    # String-literal AST node. Used as a {Generic#args} entry for
    # parametric forms whose argument is a String literal — namely
    # `Pick[T, "name"]`, `pick_of[Shape, "a" | "b"]`, and downstream
    # plugin resolvers that accept literal key selectors.
    #
    # ADR-13 follow-up (`docs/CURRENT_WORK.md` engineering item
    # #2): the RBS::Extended grammar previously could not tokenise
    # `"name"` inside a type-arg position. The resolver translates
    # this node to a `Type::Constant` carrying the string value.
    # Slice 1 supports double-quoted strings without escape
    # sequences (the most common shape — TS-style key unions
    # are bare identifier-ish names).
    class StringLiteral < Data.define(:value)
      def initialize(value:)
        unless value.is_a?(String)
          raise ArgumentError,
                "TypeNode::StringLiteral value must be a String, " \
                "got #{value.inspect}"
        end

        # Freeze the String field so the Data object is
        # `Ractor.shareable?` regardless of caller frozen-
        # string-literal state.
        super(value: value.frozen? ? value : value.dup.freeze)
      end
    end
  end
end
