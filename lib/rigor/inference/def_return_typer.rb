# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../source/node_children"
require_relative "return_barrier"
require_relative "optimistic_origin"

module Rigor
  module Inference
    # Returns the inferred return type of a `Prism::DefNode`, or nil when no type can be derived (empty body,
    # scope-lookup miss, or any failure during inference — caller surfaces "no annotation" on a nil).
    #
    # The inferred type is the union of:
    #
    # - the body's last-statement type, and
    # - the type of every explicit `return value` that exits the method. A `return` inside an ordinary block does
    #   (control-flow-analysis.md § "Non-local exits"); one inside a {ReturnBarrier} — a nested `def`, a lambda,
    #   or a `define_method` body — does not. The barriers are the ones `StatementEvaluator`'s return sink stops
    #   at, so the proposal and `rigor check`'s view of callers agree (issue #1382).
    #
    # Extracted from `Rigor::SigGen::Generator#infer_return_type` so `LineTypeCollector` (`rigor annotate`'s
    # def-line annotator) and the sig-generator share one source of truth.
    #
    # `keep_lookup_nil: true` is the reading a signature needs (#2197). The engine reads a lookup that can miss
    # (`Hash#[]`, `Array#first`, the {OptimisticOrigin} family) as nil-free on purpose, so `if h[k]` stays
    # silent, but a `-> V` written into `sig/` is a contract that every caller's `nil` check is dead code. Each
    # returned expression whose value is such a lookup therefore contributes `nil` beside its type. Only the
    # value positions a lookup's `nil` reaches the return through are followed ({#optimistic_value?}).
    module DefReturnTyper
      module_function

      def call(def_node, scope_index, keep_lookup_nil: false)
        body = def_node.body
        return nil if body.nil?

        last = body_last_expression(body)
        return nil if last.nil?

        inner_scope = scope_index[last] || scope_index[body] || scope_index[def_node]
        return nil if inner_scope.nil?

        last_type = safe_type_of(inner_scope, last)
        return nil if last_type.nil?

        lookup_context = keep_lookup_nil ? LookupContext.new(scope_index, truthy_guards(body)) : nil
        last_type = with_lookup_nil(last_type, last, inner_scope, lookup_context) if lookup_context
        union_with_explicit_returns(body, last_type, scope_index, lookup_context: lookup_context)
      rescue StandardError
        nil
      end

      # What {#optimistic_value?} reads beside a node's scope: the engine's per-node scopes, and for each lookup
      # under a guard the source of the guarding predicates ({#truthy_guards}).
      LookupContext = Data.define(:scope_index, :guards)

      def with_lookup_nil(type, node, scope, context = nil)
        return type unless optimistic_value?(node, scope, context)

        Type::Combinator.union(type, Type::Combinator.constant_of(nil))
      end

      # Whether `node`'s value can be the `nil` an optimistic lookup's miss returns: the lookup itself (a call
      # the dispatcher marked, or `recv&.m` over one), a local or ivar bound to one, or a branch or operand that
      # hands its value on. `a && b` hands on either operand (a falsy `a`, a missed lookup's `nil` included, is
      # the result); `a || b` hands on `b` only, since `a` is returned only when truthy, so `h[k] || 0` stays
      # nil-free. `x ||= v` and `x &&= v` hand on `v` and, for `&&=`, the binding. A call ON the lookup
      # (`h[k].to_s`) is a different value.
      #
      # Each child is read under the scope the engine recorded for it (`scope_index`), so a branch a guard narrows
      # (`v ? v : "d"`, `return "z" unless v`) reads the binding the narrowing left, not the enclosing one.
      def optimistic_value?(node, scope, context = nil)
        scope = context&.scope_index&.[](node) || scope
        case node
        when Prism::CallNode then optimistic_call?(node, scope, context)
        when Prism::LocalVariableReadNode then !scope.optimistic_local(node.name).nil?
        when Prism::InstanceVariableReadNode then !scope.optimistic_ivar(node.name).nil?
        when Prism::AndNode then [node.left, node.right].any? { optimistic_value?(it, scope, context) }
        when Prism::OrNode then optimistic_value?(node.right, scope, context)
        else optimistic_write?(node, scope, context) || optimistic_branch?(node, scope, context)
        end
      end

      def optimistic_call?(node, scope, context)
        if scope.optimistic_origins[node]
          return false if guarded_lookup?(node, context) || non_empty_end?(node, scope)

          return true
        end
        node.safe_navigation? && optimistic_value?(node.receiver, scope, context)
      end

      # `return h[k] if h[k]`, `h[k] ? h[k] : d`: the same lookup, read again under a predicate that just found it
      # truthy. Only a lookup whose receiver and arguments are plain reads or literals counts, so the second read
      # sees what the first did.
      GUARDABLE_LOOKUPS = %i[[] first last dig].freeze
      private_constant :GUARDABLE_LOOKUPS

      def guarded_lookup?(node, context)
        return false if context.nil? || !GUARDABLE_LOOKUPS.include?(node.name)
        return false unless [node.receiver, *node.arguments&.arguments].all? { stable_operand?(it) }

        context.guards.fetch(node, EMPTY_GUARDS).include?(node.slice)
      end

      EMPTY_GUARDS = [].freeze
      private_constant :EMPTY_GUARDS

      def stable_operand?(node)
        case node
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::SymbolNode, Prism::StringNode,
             Prism::IntegerNode, Prism::SelfNode, Prism::ConstantReadNode then true
        else false
        end
      end

      # `a.first` / `a.last` on a receiver the engine has narrowed to a non-empty array (`a.empty? ? d : a.first`)
      # cannot miss.
      def non_empty_end?(node, scope)
        return false unless %i[first last].include?(node.name) && node.arguments.nil? && node.receiver

        receiver = scope.type_of(node.receiver)
        receiver.is_a?(Type::Difference) && receiver.removed == Type::Combinator.tuple_of
      rescue StandardError
        false
      end

      def optimistic_write?(node, scope, context)
        case node
        when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
             Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode
          optimistic_value?(node.value, scope, context)
        when Prism::LocalVariableAndWriteNode
          !scope.optimistic_local(node.name).nil? || optimistic_value?(node.value, scope, context)
        when Prism::InstanceVariableAndWriteNode
          !scope.optimistic_ivar(node.name).nil? || optimistic_value?(node.value, scope, context)
        else false
        end
      end

      # The value-carrying children of a statement list or a conditional: any of them can be the value returned.
      def optimistic_branch?(node, scope, context)
        value_branches(node).any? { |branch| !branch.nil? && optimistic_value?(branch, scope, context) }
      end

      # The lookup a truthy arm (the body of an `if` or ternary, the `else` of an `unless`) reads FIRST, mapped to
      # the source of the predicate that just tested it, for {#guarded_lookup?}. Only the first expression, or the
      # value of a first `return`, counts: anything run between the test and the re-read (`h.delete(k)`, a
      # reassignment, a block, `yield`, another call that mutates the receiver) can make the re-read miss.
      def truthy_guards(body)
        guards = {}.compare_by_identity
        collect_truthy_guards(body, guards)
        guards
      end

      def collect_truthy_guards(node, guards)
        return unless node.is_a?(Prism::Node)

        predicate, arm = truthy_arm(node)
        first = first_value(arm)
        guards[first] = [predicate.slice] if first
        node.rigor_each_child { collect_truthy_guards(it, guards) }
      end

      def first_value(arm)
        return nil unless arm.is_a?(Prism::StatementsNode)

        first = arm.body.first
        args = first.is_a?(Prism::ReturnNode) ? first.arguments&.arguments : nil
        args&.size == 1 ? args.first : first
      end

      def truthy_arm(node)
        case node
        when Prism::IfNode then [node.predicate, node.statements]
        when Prism::UnlessNode then [node.predicate, node.else_clause&.statements]
        end
      end

      def value_branches(node)
        case node
        when Prism::ParenthesesNode then [node.body && body_last_expression(node.body)]
        when Prism::StatementsNode, Prism::BeginNode then [body_last_expression(node)]
        when Prism::IfNode then [node.statements, node.subsequent]
        when Prism::UnlessNode then [node.statements, node.else_clause]
        when Prism::ElseNode, Prism::WhenNode, Prism::InNode then [node.statements]
        when Prism::CaseNode, Prism::CaseMatchNode then [*node.conditions, node.else_clause]
        else []
        end
      end

      def body_last_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        when Prism::BeginNode then body_last_expression(body.statements)
        else body
        end
      end

      def union_with_explicit_returns(body, last_type, scope_index, lookup_context: nil)
        return_types = []
        collect_return_types(body, scope_index, return_types, lookup_context: lookup_context)
        return last_type if return_types.empty?

        Type::Combinator.union(last_type, *return_types)
      end

      def collect_return_types(node, scope_index, out, lookup_context: nil)
        return unless node.is_a?(Prism::Node)
        return if ReturnBarrier.node?(node)

        type_return_node(node, scope_index, out, lookup_context: lookup_context) if node.is_a?(Prism::ReturnNode)
        # A barrier call's receiver and arguments still run in the method; only its block is cut off.
        barrier_block = node.block if node.is_a?(Prism::CallNode) && ReturnBarrier.block_call?(node)
        node.rigor_each_child do |c|
          collect_return_types(c, scope_index, out, lookup_context: lookup_context) unless c.equal?(barrier_block)
        end
      end

      def type_return_node(return_node, scope_index, out, lookup_context: nil)
        args = return_node.arguments&.arguments || []
        if args.empty?
          out << Type::Combinator.constant_of(nil)
          return
        end

        scope = scope_index[return_node] || scope_index[args.first]
        return if scope.nil?
        # `return a, b` packs into a Tuple at runtime; only the single-value form is typed.
        return unless args.size == 1

        type = safe_type_of(scope, args.first)
        return if type.nil?

        out << (lookup_context ? with_lookup_nil(type, args.first, scope, lookup_context) : type)
      end

      def safe_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end
    end
  end
end
