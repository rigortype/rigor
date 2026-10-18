# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Inference
    # The constructs whose body `return` leaves only that body, not the enclosing method. A `return` anywhere else —
    # an ordinary block included — exits the method (control-flow-analysis.md § "Non-local exits").
    # `StatementEvaluator`'s return sink and `DefReturnTyper`'s return collection both stop here; each used to carry
    # its own list, and sig-gen's treated every block as a barrier (issue #1382).
    module ReturnBarrier
      # A nested `def` and a `->` literal: the body is its own method or lambda.
      NODES = Set[Prism::DefNode, Prism::LambdaNode].freeze

      # The block calls whose body `return` leaves only the block: the method a `define_method` /
      # `define_singleton_method` block defines, on whatever receiver (`klass.define_method(:m) { … }`), and
      # `Kernel#lambda` — called bare, on `self`, or on `Kernel`. Each also counts through `send`
      # (`klass.send(:define_method, :m) { … }`). A `lambda` on any other receiver is some other method.
      DEFINE_CALLS = %i[define_method define_singleton_method].to_set.freeze
      SEND_CALLS = %i[send public_send __send__].to_set.freeze
      private_constant :DEFINE_CALLS, :SEND_CALLS

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
          return false unless sent.is_a?(Prism::SymbolNode)

          name = sent.unescaped.to_sym
        end
        DEFINE_CALLS.include?(name) || (name == :lambda && kernel_receiver?(call_node.receiver))
      end

      # True when a `return` under `node` exits the enclosing method: one reachable without crossing a barrier node
      # or a barrier call's block. Allocation-free and early-exiting, for a caller that asks it of every block body.
      def exits_method?(node)
        return false if node.nil? || node?(node)
        return true if node.is_a?(Prism::ReturnNode)

        barrier_block = node.block if node.is_a?(Prism::CallNode) && block_call?(node)
        node.rigor_each_child do |child|
          next if child.equal?(barrier_block)
          return true if exits_method?(child)
        end
        false
      end

      # True when a `lambda` call on `receiver` reaches `Kernel#lambda`: no receiver, `self`, `Kernel` or `::Kernel`.
      def kernel_receiver?(receiver)
        case receiver
        when nil, Prism::SelfNode then true
        when Prism::ConstantReadNode then receiver.name == :Kernel
        when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == :Kernel
        else false
        end
      end
      private_class_method :kernel_receiver?
    end
  end
end
