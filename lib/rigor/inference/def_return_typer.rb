# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Returns the inferred return type of a `Prism::DefNode`, or nil when no type can be derived (empty body,
    # scope-lookup miss, or any failure during inference — caller surfaces "no annotation" on a nil).
    #
    # The inferred type is the union of:
    #
    # - the body's last-statement type, and
    # - the type of every explicit `return value` reachable in the body. Nested `def` / lambda / block bodies
    #   are return barriers — their `return`s do not bubble up to the enclosing method.
    #
    # Extracted from `Rigor::SigGen::Generator#infer_return_type` so `LineTypeCollector` (`rigor annotate`'s
    # def-line annotator) and the sig-generator share one source of truth.
    module DefReturnTyper
      RETURN_BARRIER_NODES = [Prism::DefNode, Prism::LambdaNode, Prism::BlockNode].freeze
      private_constant :RETURN_BARRIER_NODES

      module_function

      def call(def_node, scope_index)
        body = def_node.body
        return nil if body.nil?

        last = body_last_expression(body)
        return nil if last.nil?

        inner_scope = scope_index[last] || scope_index[body] || scope_index[def_node]
        return nil if inner_scope.nil?

        last_type = safe_type_of(inner_scope, last)
        return nil if last_type.nil?

        union_with_explicit_returns(body, last_type, scope_index)
      rescue StandardError
        nil
      end

      def body_last_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        when Prism::BeginNode then body_last_expression(body.statements)
        else body
        end
      end

      def union_with_explicit_returns(body, last_type, scope_index)
        return_types = []
        collect_return_types(body, scope_index, return_types)
        return last_type if return_types.empty?

        Type::Combinator.union(last_type, *return_types)
      end

      def collect_return_types(node, scope_index, out)
        return unless node.is_a?(Prism::Node)
        return if RETURN_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        type_return_node(node, scope_index, out) if node.is_a?(Prism::ReturnNode)
        node.compact_child_nodes.each { |c| collect_return_types(c, scope_index, out) }
      end

      def type_return_node(return_node, scope_index, out)
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
        out << type unless type.nil?
      end

      def safe_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end
    end
  end
end
