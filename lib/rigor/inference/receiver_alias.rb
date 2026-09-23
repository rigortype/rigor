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
    #
    # The `it` parameter (Ruby 3.4) is a local like any other, but Prism reads it through
    # `Prism::ItLocalVariableReadNode`, which carries no `name`; {.read_name} answers `:it` for it, the
    # binding `BlockParameterBinder` installs. A consumer names a read through {.read_name}, never `#name`.
    module ReceiverAlias
      # Deep enough for any hand-written selection; a nest beyond it degrades to "names no binding".
      WALK_DEPTH_CAP = 6

      NON_ALIASED_READS = [Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode].freeze
      private_constant :NON_ALIASED_READS

      module_function

      # @param node — the receiver expression.
      # @param depth — recursion depth, internal.
      # @return every variable
      #   read the expression can evaluate to; empty when it can evaluate to none.
      def candidates(node, depth = 0)
        return [] if node.nil? || depth > WALK_DEPTH_CAP

        case node
        when Prism::LocalVariableReadNode, Prism::ItLocalVariableReadNode, Prism::InstanceVariableReadNode then [node]
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

      # The variable reads an in-place mutation of `receiver` changes: {.candidates}' locals and instance
      # variables, or the class variable or global the receiver reads directly, parenthesised or not. A class
      # variable or global counts only as the receiver itself, not through a branch that selects it. This is the
      # one answer the straight-line widening ({MutationWidening.widen_receiver_aliases}), the block-return
      # threading gate that predicts it (`ExpressionTyper#prefix_statement_jump_free?`) and the per-element fold's
      # content-mutation scan ({CapturedLocals.content_mutations}) all read, so "the scan says the body changed
      # it" and "evaluating the body changes it" cannot disagree about which kinds of variable count.
      def mutated_reads(receiver)
        direct = receiver
        direct = direct.body.body.last while direct.is_a?(Prism::ParenthesesNode) && direct.body.is_a?(Prism::StatementsNode)
        NON_ALIASED_READS.include?(direct.class) ? [direct] : candidates(receiver)
      end

      # The binding a read from {.candidates} or {.mutated_reads} names.
      def read_name(read) = read.is_a?(Prism::ItLocalVariableReadNode) ? :it : read.name

      # True when `read` is a local the innermost block around it owns: one Prism resolves at `depth == 0`, or an
      # `it` read, which is always that block's own parameter and never a capture of an enclosing scope.
      def block_local?(read)
        read.is_a?(Prism::ItLocalVariableReadNode) || (read.is_a?(Prism::LocalVariableReadNode) && read.depth.zero?)
      end
    end
  end
end
