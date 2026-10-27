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
    # A write counts only when its value can be `nil` by its syntax alone ({.nil_value?}): a `nil` literal, a
    # safe-navigation call, or a conditional with a missing arm or an arm that is one of these. A method call's
    # result, a parameter or any other computed value does not (`@tag = @tag.strip` rewrites a value the guard
    # proved present). A multiple assignment counts a target whose own value in a literal list is one of these, or
    # is missing; a splat or a value that is not a literal list counts nothing.
    #
    # The callee is the first `def` of the call's name found on `self`'s class or, failing that, a project entry of
    # its instance chain (`Scope#user_def_for`). An implicit-self or `self.` call in a read body is read the same
    # way (`def reset = clear_tag`), up to {DEF_BUDGET} bodies. A `define_method`, `attr_writer`,
    # `instance_variable_set`, `send` or `method_missing` writer shows no write node and answers nothing, and so
    # does a nil-writer deeper than the budget.
    module DirectIvarWrites
      # Bodies that do not run where they are written, or run on another `self`; a lambda literal's body runs only
      # when it is called.
      NON_RUNNING_NODES = [
        Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::LambdaNode
      ].freeze
      # The most `def` bodies one read follows.
      DEF_BUDGET = 8
      private_constant :NON_RUNNING_NODES, :DEF_BUDGET

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

      # Whether `node`, a value, can be `nil` by its syntax alone: a `nil` literal, a safe-navigation call, or an
      # `if` / `unless` / ternary / `case` with a missing arm or an arm whose value is one of these.
      def nil_value?(node)
        case node
        when nil, Prism::NilNode then true
        when Prism::CallNode then node.safe_navigation?
        when Prism::ParenthesesNode then nil_value?(last_value(node.body))
        when Prism::IfNode then nil_value?(last_value(node.statements)) || else_nil?(node.subsequent)
        when Prism::UnlessNode then nil_value?(last_value(node.statements)) || else_nil?(node.else_clause)
        when Prism::CaseNode, Prism::CaseMatchNode
          node.conditions.any? { |arm| nil_value?(last_value(arm.statements)) } || else_nil?(node.else_clause)
        else false
        end
      end

      def read_callee(call_node, class_name, scope, names, visited)
        def_node = callee_def(call_node, class_name, scope)
        return if def_node.nil? || visited.key?(def_node) || visited.size >= DEF_BUDGET

        visited[def_node] = true
        collect(def_node.body, names) do |call|
          read_callee(call, class_name, scope, names, visited)
        end
      end

      # The chain fallback passes over an external entry rather than stopping at it: a `def` found past one only
      # keeps a reset unmarked, which reports no more than the reset did before #2039.
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

        nil_writes(node, names)
        on_self_call.call(node) if self_call?(node)
        node.rigor_each_child { |child| collect(child, names, &on_self_call) }
      end

      def self_call?(node)
        node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      def nil_writes(node, names)
        case node
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
          names << node.name if nil_value?(node.value)
        when Prism::MultiWriteNode then multi_nil_writes(node, names)
        end
      end

      # A target of `@a, @b = 1, nil` against its own element of a literal list; a missing element is `nil`.
      def multi_nil_writes(node, names)
        values = node.value
        return unless values.is_a?(Prism::ArrayNode)
        return if values.elements.any?(Prism::SplatNode) || !node.rest.nil?

        node.lefts.each_with_index do |target, index|
          next unless target.is_a?(Prism::InstanceVariableTargetNode)

          names << target.name if nil_value?(values.elements[index])
        end
      end

      def last_value(statements)
        statements.is_a?(Prism::StatementsNode) ? statements.body.last : statements
      end

      # Whether an `else` clause (or `elsif`) leaves the conditional's value possibly `nil`: missing, or its value
      # is.
      def else_nil?(clause)
        case clause
        when nil then true
        when Prism::ElseNode then nil_value?(last_value(clause.statements))
        else nil_value?(clause)
        end
      end
      private_class_method :read_callee, :callee_def, :def_node, :collect, :self_call?, :nil_writes,
                           :multi_nil_writes, :last_value, :else_nil?
    end
  end
end
