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
    Generic = Data.define(:head, :args) do
      def initialize(head:, args:)
        unless head.is_a?(String) && !head.empty?
          raise ArgumentError,
                "TypeNode::Generic head must be a non-empty String, " \
                "got #{head.inspect}"
        end

        unless args.is_a?(Array) && args.all? { |a| a.is_a?(Identifier) || a.is_a?(Generic) }
          raise ArgumentError,
                "TypeNode::Generic args must be an Array of " \
                "TypeNode::Identifier or TypeNode::Generic, " \
                "got #{args.inspect}"
        end

        super(head: head, args: args.freeze)
      end
    end
  end
end
