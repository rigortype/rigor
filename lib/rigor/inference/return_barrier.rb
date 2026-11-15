# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "genuine_send"

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
      #
      # Through `send`, the call is reflective only where the receiver's `send` is `Kernel#send`
      # ({GenuineSend.call?}, issue #3081): `def send(_name) = yield` makes `send(:lambda) { return nil }` an
      # ordinary block whose `return` exits the method. `scope` is the scope the call is typed in; without one,
      # or with `typed: false` (a caller holding the enclosing body's scope, not the call's) and an explicit
      # receiver, nothing proves the `send` genuine and the block is not a barrier, which can only widen the
      # method's return type. `__send__` and `public_send` are other methods and keep the reflective reading.
      def block_call?(call_node, scope: nil, typed: true)
        name = call_node.name
        return barrier_name?(name, call_node) unless SEND_CALLS.include?(name)

        sent = call_node.arguments&.arguments&.first
        return false unless sent.is_a?(Prism::SymbolNode)
        return false unless barrier_name?(sent.unescaped.to_sym, call_node)

        name != :send || GenuineSend.call?(call_node.receiver, scope, typed: typed)
      end

      # True when a call of `name` on `call_node`'s receiver keeps its block from the enclosing method.
      def barrier_name?(name, call_node)
        DEFINE_CALLS.include?(name) || (name == :lambda && kernel_receiver?(call_node.receiver))
      end
      private_class_method :barrier_name?

      # True when a `return` under `node` exits the enclosing method: one reachable without crossing a barrier node
      # or a barrier call's block. Allocation-free and early-exiting, for a caller that asks it of every block body.
      # `scope` is the enclosing body's, so a `send` barrier is judged by its `self` alone ({.block_call?}).
      def exits_method?(node, scope = nil)
        return false if node.nil? || node?(node)
        return true if node.is_a?(Prism::ReturnNode)

        barrier_block = node.block if node.is_a?(Prism::CallNode) && block_call?(node, scope: scope, typed: false)
        node.rigor_each_child do |child|
          next if child.equal?(barrier_block)
          return true if exits_method?(child, scope)
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
