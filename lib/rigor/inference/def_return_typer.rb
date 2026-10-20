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

        last_type = with_lookup_nil(last_type, last, inner_scope) if keep_lookup_nil
        union_with_explicit_returns(body, last_type, scope_index, keep_lookup_nil: keep_lookup_nil)
      rescue StandardError
        nil
      end

      def with_lookup_nil(type, node, scope)
        optimistic_value?(node, scope) ? Type::Combinator.union(type, Type::Combinator.constant_of(nil)) : type
      end

      # Whether `node`'s value can be the `nil` an optimistic lookup's miss returns: the lookup itself (a call
      # the dispatcher marked, or `recv&.m` over one), a local or ivar bound to one, or a branch or operand that
      # hands its value on. `a || b` hands on `b` only, since `a` is returned only when truthy, so `h[k] || 0`
      # stays nil-free; `a && b` likewise hands on `b`. A call ON the lookup (`h[k].to_s`) is a different value.
      def optimistic_value?(node, scope)
        case node
        when Prism::CallNode then optimistic_call?(node, scope)
        when Prism::LocalVariableReadNode then !scope.optimistic_local(node.name).nil?
        when Prism::InstanceVariableReadNode then !scope.optimistic_ivar(node.name).nil?
        when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode then optimistic_value?(node.value, scope)
        when Prism::AndNode, Prism::OrNode then optimistic_value?(node.right, scope)
        else optimistic_branch?(node, scope)
        end
      end

      def optimistic_call?(node, scope)
        !scope.optimistic_origins[node].nil? || (node.safe_navigation? && optimistic_value?(node.receiver, scope))
      end

      # The value-carrying children of a statement list or a conditional: any of them can be the value returned.
      def optimistic_branch?(node, scope)
        value_branches(node).any? { |branch| !branch.nil? && optimistic_value?(branch, scope) }
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

      def union_with_explicit_returns(body, last_type, scope_index, keep_lookup_nil: false)
        return_types = []
        collect_return_types(body, scope_index, return_types, keep_lookup_nil: keep_lookup_nil)
        return last_type if return_types.empty?

        Type::Combinator.union(last_type, *return_types)
      end

      def collect_return_types(node, scope_index, out, keep_lookup_nil: false)
        return unless node.is_a?(Prism::Node)
        return if ReturnBarrier.node?(node)

        type_return_node(node, scope_index, out, keep_lookup_nil: keep_lookup_nil) if node.is_a?(Prism::ReturnNode)
        # A barrier call's receiver and arguments still run in the method; only its block is cut off.
        barrier_block = node.block if node.is_a?(Prism::CallNode) && ReturnBarrier.block_call?(node)
        node.rigor_each_child do |c|
          collect_return_types(c, scope_index, out, keep_lookup_nil: keep_lookup_nil) unless c.equal?(barrier_block)
        end
      end

      def type_return_node(return_node, scope_index, out, keep_lookup_nil: false)
        args = return_node.arguments&.arguments || []
        if args.empty?
          out << Type::Combinator.constant_of(nil)
          return
        end

        scope = scope_index[return_node] || scope_index[args.first]
        return if scope.nil?
        # `return a, b` packs into a Tuple at runtime; the MVP only handles the single-value form. Multi-arg
        # returns contribute no type to keep the implementation focused.
        return unless args.size == 1

        type = safe_type_of(scope, args.first)
        return if type.nil?

        out << (keep_lookup_nil ? with_lookup_nil(type, args.first, scope) : type)
      end

      def safe_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end
    end
  end
end
