# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # The constructs whose body `return` leaves only that body, not the enclosing method. A `return` anywhere else —
    # an ordinary block included — exits the method (control-flow-analysis.md § "Non-local exits").
    # `StatementEvaluator`'s return sink and `DefReturnTyper`'s return collection both stop here; each used to carry
    # its own list, and sig-gen's treated every block as a barrier (issue #1382).
    module ReturnBarrier
      # A nested `def` and a `->` literal: the body is its own method or lambda.
      NODES = Set[Prism::DefNode, Prism::LambdaNode].freeze

      # The block calls whose body `return` leaves only the block: `lambda { … }`, and the method a
      # `define_method` / `define_singleton_method` block defines, called directly or through `send`
      # (`klass.send(:define_method, :m) { … }`).
      BLOCK_CALLS = %i[lambda define_method define_singleton_method].to_set.freeze
      SEND_CALLS = %i[send public_send __send__].to_set.freeze
      private_constant :BLOCK_CALLS, :SEND_CALLS

      module_function

      # True when `node` is a nested `def` or a lambda literal.
      def node?(node)
        NODES.include?(node.class)
      end

      # True when the block `call_node` carries is a return barrier.
      def block_call?(call_node)
        name = call_node.name
        if SEND_CALLS.include?(name)
          sent = call_node.arguments&.arguments&.first
          sent.is_a?(Prism::SymbolNode) && BLOCK_CALLS.include?(sent.unescaped.to_sym)
        else
          BLOCK_CALLS.include?(name) && (call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode))
        end
      end
    end
  end
end
