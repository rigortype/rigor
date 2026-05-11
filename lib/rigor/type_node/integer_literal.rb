# frozen_string_literal: true

module Rigor
  module TypeNode
    # Integer-literal AST node. Used as a {Generic#args} entry for
    # parametric forms whose arguments are bare integers — namely
    # `int<5, 10>` (angle-bracketed integer bounds for
    # {Type::IntegerRange}) and `int_mask[1, 2, 4]` (square-
    # bracketed bitflag union for {Type::Combinator.int_mask}).
    #
    # ADR-13 slice 3 introduces this node so the parser can emit a
    # uniform AST regardless of bracket flavour: the resolver pass
    # then dispatches to the appropriate built-in builder by head
    # name. Plugin resolvers receive the same shape and MAY treat
    # integer literals as input to custom carriers (e.g. an
    # opinionated `port_number<8000>` plugin).
    IntegerLiteral = Data.define(:value) do
      def initialize(value:)
        unless value.is_a?(Integer)
          raise ArgumentError,
                "TypeNode::IntegerLiteral value must be an Integer, " \
                "got #{value.inspect}"
        end

        super
      end
    end
  end
end
