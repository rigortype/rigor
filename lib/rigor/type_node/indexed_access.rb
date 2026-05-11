# frozen_string_literal: true

module Rigor
  module TypeNode
    # AST wrapper for the trailing `T[K]` indexed-access projection
    # chain. The parser emits a left-associative chain by wrapping
    # the receiver AST in successive `IndexedAccess` nodes
    # (`Tuple[A, B][1][0]` parses to
    # `IndexedAccess(IndexedAccess(Generic(Tuple, [A, B]), 1), 0)`).
    #
    # `receiver` and `key` are themselves any AST node — the
    # indexed-access chain is applied at resolution time, after the
    # receiver has been resolved to a {Rigor::Type} carrier and the
    # key has been resolved (typically to a `Constant<Integer>` or
    # a constant String/Symbol singleton).
    class IndexedAccess < Data.define(:receiver, :key)
      def initialize(receiver:, key:)
        unless valid_node?(receiver)
          raise ArgumentError,
                "TypeNode::IndexedAccess receiver must be a TypeNode " \
                "node, got #{receiver.inspect}"
        end

        unless valid_node?(key)
          raise ArgumentError,
                "TypeNode::IndexedAccess key must be a TypeNode " \
                "node, got #{key.inspect}"
        end

        super
      end

      private

      def valid_node?(node)
        node.is_a?(Identifier) || node.is_a?(Generic) ||
          node.is_a?(IntegerLiteral) || node.is_a?(IndexedAccess)
      end
    end
  end
end
