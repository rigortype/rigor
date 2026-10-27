# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Inference
    # Issue #2039 — the instance variables an implicit-self or `self.` call's callee visibly assigns a value that may
    # be `nil`, read without a proof. {SelfCallIvarWrites.of} declines for any reason it cannot rule out another
    # write (a `yield` or a call on a parameter in the callee, `include Comparable`, `method_missing`, a reopening);
    # the statement reset (`InterveningIvarReset.widen` under `mark: :unproven`) still leaves a name this answers
    # unmarked, since a callee that writes `@tag = nil` where the program shows it makes the read nil-reportable
    # whatever else it runs.
    #
    # The callee is the first `def` of the call's name found on `self`'s class or, failing that, a project entry of
    # its instance chain (`Scope#user_def_for`). An implicit-self or `self.` call in a read body is read the same
    # way (`def reset = clear_tag`), up to {DEF_BUDGET} bodies. A `define_method`, `attr_writer`,
    # `instance_variable_set`, `send` or `method_missing` writer shows no write node and answers nothing.
    module DirectIvarWrites
      # Value nodes that never evaluate to `nil`.
      NON_NIL_VALUES = [
        Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode, Prism::InterpolatedXStringNode,
        Prism::SymbolNode, Prism::InterpolatedSymbolNode, Prism::IntegerNode, Prism::FloatNode,
        Prism::RationalNode, Prism::ImaginaryNode, Prism::ArrayNode, Prism::HashNode, Prism::TrueNode,
        Prism::FalseNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode,
        Prism::RangeNode, Prism::LambdaNode, Prism::SelfNode
      ].freeze
      # Bodies that do not run where they are written, or run on another `self`.
      NON_RUNNING_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      # The most `def` bodies one read follows.
      DEF_BUDGET = 8
      private_constant :NON_NIL_VALUES, :NON_RUNNING_NODES, :DEF_BUDGET

      module_function

      # The names, as a `Set`, of the instance variables the callee of `call_node` assigns a possibly-nil value in
      # its own body; empty when the callee resolves to no `def` the tables hold.
      def of(call_node, scope)
        names = Set.new
        self_type = scope.self_type
        return names unless self_type.is_a?(Type::Nominal)

        read_callee(call_node, self_type.class_name.to_s, scope, names, {}.compare_by_identity)
        names
      rescue StandardError
        Set.new
      end

      def read_callee(call_node, class_name, scope, names, visited)
        def_node = callee_def(call_node, class_name, scope)
        return if def_node.nil? || visited.key?(def_node) || visited.size >= DEF_BUDGET

        visited[def_node] = true
        collect(def_node.body, names) do |call|
          read_callee(call, class_name, scope, names, visited)
        end
      end

      def callee_def(call_node, class_name, scope)
        return nil unless call_node.is_a?(Prism::CallNode)

        name = call_node.name
        own = def_node(scope.user_def_for(class_name, name))
        return own if own

        Scope::ResolutionChain.for(scope, class_name, :instance, :methods).search(scope) do |entry|
          entry.external? ? nil : def_node(scope.user_def_for(entry.name, name))
        end
      end

      def def_node(node) = node.is_a?(Prism::DefNode) && node.receiver.nil? ? node : nil

      def collect(node, names, &on_self_call)
        return unless node.is_a?(Prism::Node)
        return if NON_RUNNING_NODES.any? { |klass| node.is_a?(klass) }

        name = nil_able_write(node)
        names << name if name
        on_self_call.call(node) if self_call?(node)
        node.rigor_each_child { |child| collect(child, names, &on_self_call) }
      end

      def self_call?(node)
        node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      def nil_able_write(node)
        case node
        when Prism::InstanceVariableTargetNode then node.name
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
          node.name unless NON_NIL_VALUES.any? { |klass| node.value.is_a?(klass) }
        end
      end
      private_class_method :read_callee, :callee_def, :def_node, :collect, :self_call?, :nil_able_write
    end
  end
end
