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
    # safe-navigation call, a conditional with a missing arm or an arm that is one of these, an `a || b` whose `b` is
    # one and whose `a` is no truthy literal, or an `a && b` whose `a` is one, or whose `b` is one and whose `a` is
    # not `false`. A method call's result, a parameter or any other computed value does not (`@tag = @tag.strip`
    # rewrites a value the guard proved present), nor does a call past a safe-navigation call (`@peer&.tag.upcase`
    # raises on a `nil` receiver rather than answering `nil`). A multiple assignment counts a target whose own value
    # in a literal list is one of these, or is missing; every target when the value is one of these; every target
    # after the first when the value is a literal Ruby does not splat (`@a, @b = 1`); and a nested target
    # (`(@a, @b), @c = ...`) on the same rule against its own value. A splat, a rest target, or any other value
    # (`@a, @b = pair`, which Ruby splats when it is an Array) counts nothing.
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
      # Literals that are never `nil` or `false` and that a multiple assignment does not splat (no Array literal).
      TRUTHY_LITERALS = [
        Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode, Prism::StringNode,
        Prism::InterpolatedStringNode, Prism::XStringNode, Prism::InterpolatedXStringNode, Prism::SymbolNode,
        Prism::InterpolatedSymbolNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode,
        Prism::TrueNode, Prism::HashNode, Prism::RangeNode, Prism::SourceFileNode, Prism::SourceLineNode,
        Prism::SourceEncodingNode
      ].freeze
      # The most `def` bodies one read follows.
      DEF_BUDGET = 8
      private_constant :NON_RUNNING_NODES, :TRUTHY_LITERALS, :DEF_BUDGET

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

      # Whether `node`, a value, can be `nil` by its syntax alone: a `nil` literal, a safe-navigation call, an
      # `if` / `unless` / ternary / `case` with a missing arm or an arm whose value is one of these (a `case ... in`
      # with no `else` raises instead), or an `||` / `&&` that can answer one of these.
      def nil_value?(node)
        case node
        when nil, Prism::NilNode then true
        when Prism::CallNode then node.safe_navigation?
        when Prism::ParenthesesNode then nil_value?(last_value(node.body))
        when Prism::IfNode then nil_value?(last_value(node.statements)) || else_nil?(node.subsequent)
        when Prism::UnlessNode then nil_value?(last_value(node.statements)) || else_nil?(node.else_clause)
        when Prism::CaseNode, Prism::CaseMatchNode then case_nil?(node)
        when Prism::OrNode, Prism::AndNode then logical_nil?(node)
        else false
        end
      end

      # A `case ... in` with no `else` raises NoMatchingPatternError rather than answering `nil`.
      def case_nil?(node)
        return true if node.conditions.any? { |arm| nil_value?(last_value(arm.statements)) }
        return false if node.is_a?(Prism::CaseMatchNode) && node.else_clause.nil?

        else_nil?(node.else_clause)
      end

      # `a || b` answers `b` unless `a` is truthy; `a && b` answers `a` unless `a` is truthy, and `b` otherwise.
      def logical_nil?(node)
        if node.is_a?(Prism::OrNode)
          nil_value?(node.right) && !truthy_literal?(node.left)
        else
          nil_value?(node.left) || (nil_value?(node.right) && !node.left.is_a?(Prism::FalseNode))
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

      def multi_nil_writes(node, names) = destructure_nil_writes(node, node.value, names)

      # The targets of `targets` (a `MultiWriteNode`, or a nested `MultiTargetNode`) that `value` (nil for a missing
      # element) may bind to `nil`: each against its own element of a literal list (a missing element is `nil`),
      # every one when `value` itself may be `nil`, and every one after the first when `value` is a literal Ruby does
      # not splat. A splat, a rest target or a computed value answers nothing, since it may be an Array.
      def destructure_nil_writes(targets, value, names)
        return unless targets.rest.nil?

        if value.is_a?(Prism::ArrayNode)
          return if value.elements.any?(Prism::SplatNode)

          targets.lefts.each_with_index { |target, index| target_nil_write(target, value.elements[index], names) }
        elsif nil_value?(value)
          targets.lefts.each { |target| target_nil_write(target, nil, names) }
        elsif truthy_literal?(value)
          first, *others = targets.lefts
          target_nil_write(first, value, names)
          others.each { |target| target_nil_write(target, nil, names) }
        end
      end

      def target_nil_write(target, value, names)
        case target
        when Prism::InstanceVariableTargetNode then names << target.name if nil_value?(value)
        when Prism::MultiTargetNode then destructure_nil_writes(target, value, names)
        end
      end

      # Whether `node` is a literal that is never `nil` or `false` and is no Array literal: `1 || nil` is never `nil`,
      # and `@a, @b = 1` does not splat its value.
      def truthy_literal?(node) = TRUTHY_LITERALS.any? { |klass| node.is_a?(klass) }

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
                           :case_nil?, :logical_nil?, :multi_nil_writes,
                           :destructure_nil_writes,
                           :target_nil_write, :truthy_literal?, :last_value, :else_nil?
    end
  end
end
