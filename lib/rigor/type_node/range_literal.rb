# frozen_string_literal: true

module Rigor
  module TypeNode
    # Range-literal AST node: a Ruby `Range` literal in a type-arg position, spelled as Ruby spells
    # it (`1..10`, `1...10`, `1..`, `..10`, `nil..nil`). ADR-109 makes it the bound of the numeric
    # range refinements, `Integer[1..10]`; under any other head the resolver lifts it to a
    # `Constant<Range>` so a plugin resolver may consume it like the other leaf literals.
    #
    # The value is the `Range` object itself, which already carries `begin`, `end` and
    # `exclude_end?`; there is no second representation to keep in step. A missing endpoint is
    # `nil`, as in Ruby.
    class RangeLiteral < Data.define(:value)
      def initialize(value:)
        unless value.is_a?(Range)
          raise ArgumentError,
                "TypeNode::RangeLiteral value must be a Range, " \
                "got #{value.inspect}"
        end

        super
      end
    end
  end
end
