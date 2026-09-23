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
    # A local or instance-variable write evaluates to the variable it writes, so `(buf ||= []) << x`
    # mutates `buf` and yields a read of it ({.read_of}). Issue #1223 made that binding visible: the
    # statement evaluator threads a write in a receiver, and without the alias `buf` kept the `[]`
    # the `||=` stored.
    module ReceiverAlias
      # Deep enough for any hand-written selection; a nest beyond it degrades to "names no binding".
      WALK_DEPTH_CAP = 6

      LOCAL_WRITE_NODES = Set[
        Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode, Prism::LocalVariableOperatorWriteNode
      ].freeze
      INSTANCE_WRITE_NODES = Set[
        Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode
      ].freeze
      private_constant :LOCAL_WRITE_NODES, :INSTANCE_WRITE_NODES

      module_function

      # @param node — the receiver expression.
      # @param depth — recursion depth, internal.
      # @return every variable
      #   read the expression can evaluate to; empty when it can evaluate to none.
      def candidates(node, depth = 0)
        return [] if node.nil? || depth > WALK_DEPTH_CAP

        case node
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then [node]
        when *LOCAL_WRITE_NODES, *INSTANCE_WRITE_NODES then [read_of(node)]
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

      # True when `node` is a local or instance-variable write, whose value is the variable it leaves.
      def variable_write?(node)
        LOCAL_WRITE_NODES.include?(node.class) || INSTANCE_WRITE_NODES.include?(node.class)
      end

      # A read of the variable `write` writes, at the write's name, for the analysers that key a receiver on a
      # read node. `Prism` 1.x constructs every node from `source, node_id, location, flags` and its fields.
      def read_of(write)
        source = write.send(:source)
        if LOCAL_WRITE_NODES.include?(write.class)
          Prism::LocalVariableReadNode.new(source, write.node_id, write.name_loc, 0, write.name, write.depth)
        else
          Prism::InstanceVariableReadNode.new(source, write.node_id, write.name_loc, 0, write.name)
        end
      end
    end
  end
end
