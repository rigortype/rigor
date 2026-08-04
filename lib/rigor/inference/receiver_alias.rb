# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # Which variables can a receiver EXPRESSION evaluate to?
    #
    # A receiver-fact invalidation (see {MutationWidening}) has to name the binding it invalidates,
    # and the overwhelmingly common receiver — a bare `arr` / `@arr` read — names exactly one. But a
    # receiver may also *select* among variables without naming any of them:
    #
    #     (kind == :required ? required : optional)[key] = info
    #
    # The mutation lands on whichever of `required` / `optional` the ternary picked, so BOTH are
    # possible targets and both must forget their literal shape. Reading only the syntactic head
    # left both hashes carrying the empty `HashShape` the literal `{}` wrote, and a downstream
    # `.empty?` then constant-folded into a false `flow.always-truthy-condition`
    # ([#277](https://github.com/rigortype/rigor/issues/277)).
    #
    # The recursion covers only the forms whose value IS one of the sub-expressions: `if` / `unless`
    # (including the ternary spelling), the short-circuit operators, and the transparent wrappers.
    # Anything else — an index read (`declared[kind] << key`), a call result, a literal — names an
    # object no binding can be attributed to and yields `[]`, which is what every receiver form
    # outside the single-read case already contributed. The walk is depth-capped so a pathological
    # nest cannot make receiver classification unbounded.
    module ReceiverAlias
      # Deep enough for any hand-written selection; a nest beyond it degrades to "names no binding".
      WALK_DEPTH_CAP = 6

      module_function

      # @param node  [Prism::Node, nil] the receiver expression.
      # @param depth [Integer] recursion depth, internal.
      # @return [Array<Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode>] every variable
      #   read the expression can evaluate to; empty when it can evaluate to none.
      def candidates(node, depth = 0)
        return [] if node.nil? || depth > WALK_DEPTH_CAP

        case node
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then [node]
        when Prism::ParenthesesNode then candidates(node.body, depth + 1)
        when Prism::StatementsNode then candidates(node.body.last, depth + 1)
        when Prism::ElseNode then candidates(node.statements, depth + 1)
        when Prism::IfNode then branches(node.statements, node.subsequent, depth)
        when Prism::UnlessNode then branches(node.statements, node.else_clause, depth)
        when Prism::OrNode, Prism::AndNode then branches(node.left, node.right, depth)
        else []
        end
      end

      def branches(first, second, depth)
        candidates(first, depth + 1) + candidates(second, depth + 1)
      end
    end
  end
end
