# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Issue #2127 — whether a call to a PROJECT method may run the block it passes more than once, read off the
    # callee's body. {BlockRepetition.may_repeat?} answers only for the core iterators {ClosureEscapeAnalyzer}
    # catalogues, so `def yielder = (yield; yield)` or the idiomatic wrapper `def each = @items.each { |i| yield i }`
    # counted as running the block once, and a `return` in the block that only a later run reaches (`each { return
    # false if (seen += 1) > 3 }`) never joined the method's return type.
    #
    # Only the later-run `return` pass asks this (`StatementEvaluator#collect_repeated_block_returns`); the block's
    # entry scopes and the ADR-56 write-back keep {BlockRepetition}'s rule. That pass only widens the method's
    # return type, so the rule here errs toward "repeats". The callee repeats when its body, outside a nested `def`
    # (a `yield` in a class body is a syntax error inside a method):
    #
    # - holds two or more sites that run the block (`yield`, or `call` / `yield` / `===` / `[]` on the `&blk`
    #   parameter), or one inside a loop, a block or a lambda, which may run it many times; or
    # - hands the block on (`each(&blk)`, `each(&)`, `...` forwarding) or reads the `&blk` parameter any other way
    #   (stores it, passes it as an argument), so code the walk does not see may run it any number of times.
    #
    # A callee the analysis cannot resolve to a project `def` (an unknown receiver, a method defined by
    # metaprogramming) answers false, as before.
    module ProjectYielder
      module_function

      BLOCK_RUN_CALLS = Set[:call, :yield, :===, :[]].freeze
      REPEATING_NODES = Set[Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode,
                            Prism::LambdaNode].freeze
      private_constant :BLOCK_RUN_CALLS, :REPEATING_NODES

      def may_run_block_repeatedly?(call_node, receiver_type, scope)
        def_node = callee_def(call_node, receiver_type, scope)
        return false unless def_node.is_a?(Prism::DefNode) && def_node.body

        repeats?(def_node)
      rescue StandardError
        false
      end

      # Issue #2301 — whether the callee hands the block it is called with on to another call (`g(x, &)`,
      # `g(x, &blk)`), outside a nested `def`. The block-return pass types such a forward's target `yield` as the
      # caller's block ({ExpressionTyper#forwarded_block_return_type}), and the target may run it any number of
      # times, so the caller's block is typed as one that may repeat. Answers false where the callee does not resolve.
      def hands_block_on?(call_node, receiver_type, scope)
        def_node = callee_def(call_node, receiver_type, scope)
        return false unless def_node.is_a?(Prism::DefNode) && def_node.body

        hand_off_in?(def_node.body, def_node.parameters&.block&.name)
      rescue StandardError
        false
      end

      def hand_off_in?(node, block_name)
        return false if node.is_a?(Prism::DefNode)
        return true if node.is_a?(Prism::BlockArgumentNode) && forwards_block?(node, block_name)

        node.compact_child_nodes.any? { |child| hand_off_in?(child, block_name) }
      end

      # The `def` an instance call on a project class, a singleton call on one, or an implicit-self call to a
      # top-level method resolves to.
      def callee_def(call_node, receiver_type, scope)
        name = call_node.name
        found =
          case receiver_type
          when Type::Nominal then scope.user_def_through_ancestors(receiver_type.class_name, name).first
          when Type::Singleton then scope.singleton_def_for(receiver_type.class_name, name)
          end
        found || (call_node.receiver.nil? ? scope.top_level_def_for(name) : nil)
      end

      def repeats?(def_node)
        block_param = def_node.parameters&.block
        counter = { sites: 0, repeats: false }
        walk(def_node.body, block_param&.name, false, counter)
        counter[:repeats] || counter[:sites] >= 2
      end

      def walk(node, block_name, repeating, counter)
        return if counter[:repeats] || node.is_a?(Prism::DefNode)

        skipped = visit(node, block_name, repeating, counter)
        inner = repeating || REPEATING_NODES.include?(node.class)
        node.compact_child_nodes.each do |child|
          walk(child, block_name, inner, counter) unless child.equal?(skipped)
        end
      end

      # Counts `node` and answers the child the walk must not visit: the `blk` receiver of a `blk.call`, which is a
      # run, not a hand-off.
      def visit(node, block_name, repeating, counter)
        case node
        when Prism::YieldNode then run_site(repeating, counter)
        when Prism::ForwardingArgumentsNode then counter[:repeats] = true
        when Prism::BlockArgumentNode then counter[:repeats] = true if forwards_block?(node, block_name)
        when Prism::CallNode
          return unless block_run_call?(node, block_name)

          run_site(repeating, counter)
          node.receiver
        when Prism::LocalVariableReadNode then counter[:repeats] = true if block_name && node.name == block_name
        end
      end

      def run_site(repeating, counter)
        counter[:sites] += 1
        counter[:repeats] = true if repeating
      end

      # `blk.call` and its spellings.
      def block_run_call?(node, block_name)
        receiver = node.receiver
        !block_name.nil? && receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == block_name &&
          BLOCK_RUN_CALLS.include?(node.name)
      end

      # `&blk` or an anonymous `&` handed to another call.
      def forwards_block?(node, block_name)
        expression = node.expression
        expression.nil? || (expression.is_a?(Prism::LocalVariableReadNode) && expression.name == block_name)
      end
    end
  end
end
