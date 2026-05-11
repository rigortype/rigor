# frozen_string_literal: true

module Rigor
  module TypeNode
    # A parameterised named-type reference (`Pick<T, K>`,
    # `non-empty-array[Integer]`, `pick_of[T, "name" | "email"]`,
    # …) in an RBS::Extended payload. The `head` is the parser-
    # observed name (no bracket type); `args` is the ordered
    # sequence of type-argument nodes already produced by the
    # parser at one level of depth.
    #
    # Args are themselves {TypeNode::Identifier} or
    # {TypeNode::Generic}. Nested generics ride the same shape:
    # `Pick<Address, "name" | "surname">` reaches the resolver as
    # `Generic("Pick", [Identifier("Address"), Generic("Union", [...])])`
    # — actually the union spelling depends on the parser's
    # eventual convention (slice 3 pins it); for now the field
    # set is the only public commitment.
    #
    # The carrier is intentionally permissive about `args.size`.
    # The grammar-level rule "no brackets ⇒ Identifier; brackets ⇒
    # Generic" lives on the parser side; nothing here forbids a
    # zero-arg Generic so plugins can synthesise nodes for
    # diagnostic or testing purposes without the parser fighting
    # back.
    class Generic < Data.define(:head, :args)
      def initialize(head:, args:)
        unless head.is_a?(String) && !head.empty?
          raise ArgumentError,
                "TypeNode::Generic head must be a non-empty String, " \
                "got #{head.inspect}"
        end

        unless args.is_a?(Array) && args.all? { |a| valid_arg?(a) }
          raise ArgumentError,
                "TypeNode::Generic args must be an Array of " \
                "TypeNode::Identifier / TypeNode::Generic / " \
                "TypeNode::IntegerLiteral, got #{args.inspect}"
        end

        super(head: head, args: args.freeze)
      end

      private

      # ADR-13 slice 3 expanded the accepted set to include
      # {IntegerLiteral} so the parser can emit a uniform AST for
      # `int<5, 10>` (angle bounds) and `int_mask[1, 2, 4]`
      # (square-bracketed bitflag union). Slice 1 originally
      # accepted only `Identifier` / `Generic`; this addition is
      # additive — every slice-1-shape Generic remains valid.
      def valid_arg?(arg)
        arg.is_a?(Identifier) || arg.is_a?(Generic) || arg.is_a?(IntegerLiteral)
      end
    end
  end
end
