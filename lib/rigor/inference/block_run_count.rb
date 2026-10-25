# frozen_string_literal: true

require "prism"

require_relative "block_call_timing"
require_relative "closure_escape_analyzer"

module Rigor
  module Inference
    # Issue #2303 — whether a project method's body may run the block it is called with more than once ON ONE PATH,
    # for the expression-position block-value pass (`ExpressionTyper#block_may_repeat?` through
    # {ProjectYielder.block_value_may_repeat?}). That pass lays the #587 (b) captured binding under a repeating block,
    # which adds values a single run never reads, so a callee read as repeating when it is not reports diagnostics on
    # correct code (`s = "a"; r = either(f) { t = s; s = nil; t }; r.upcase`). The rule here therefore errs toward
    # "runs once", unlike {ProjectYielder.may_run_block_repeatedly?}, whose only asker widens a return type.
    #
    # The walk counts block runs per path, saturating at {MANY}:
    #
    # - a `yield`, or `call` / `yield` / `===` / `[]` on the `&blk` parameter, is one run;
    # - a sequence sums, and a branch (`if` / `unless` / ternary / `case` / `case ... in`) takes the largest arm,
    #   so `f ? yield(1) : yield(2)` is one run;
    # - a `return`, `break`, `next` or receiver-less `raise` / `fail` ends its path, so the `yield` after
    #   `return yield(1) if k` is a different path from the one before it;
    # - a run inside `while` / `until` / `for`, inside the block of a catalogued core iterator
    #   ({ClosureEscapeAnalyzer.iterator_name?}) or `Kernel#loop`, or a hand-off of the block (`g(&blk)`, `g(&)`,
    #   `...`) is {MANY};
    # - a block under any other call runs its body once (`then { yield }`, `synchronize { yield }`,
    #   `File.open(f) { yield f }`), a lambda body is not run at its definition, and a nested `def` is not this
    #   method's body.
    #
    # Reading `&blk` other than calling it (`return unless blk`) is no run.
    module BlockRunCount
      module_function

      MANY = 2
      ZERO = [0, 0].freeze
      BLOCK_RUN_CALLS = Set[:call, :yield, :===, :[]].freeze
      LOOP_NODES = Set[Prism::WhileNode, Prism::UntilNode, Prism::ForNode].freeze
      JUMP_NODES = Set[Prism::ReturnNode, Prism::BreakNode, Prism::NextNode].freeze
      RAISING_CALLS = Set[:raise, :fail].freeze
      private_constant :ZERO, :BLOCK_RUN_CALLS, :LOOP_NODES, :JUMP_NODES, :RAISING_CALLS

      def may_repeat?(def_node)
        runs(def_node.body, def_node.parameters&.block&.name).last >= MANY
      end

      # `[fall, total]`: the most runs on a path that falls through `node` (nil when none does), and the most on
      # any path through it, an exiting one included.
      def runs(node, block_name)
        case node
        when nil, Prism::DefNode, Prism::LambdaNode then ZERO
        when Prism::YieldNode then run_after(sequence(node.compact_child_nodes, block_name))
        when Prism::ForwardingArgumentsNode then [MANY, MANY]
        when Prism::BlockArgumentNode then block_argument_runs(node, block_name)
        when Prism::IfNode then branch(runs(node.predicate, block_name), [node.statements, node.subsequent], block_name)
        when Prism::UnlessNode
          branch(runs(node.predicate, block_name), [node.statements, node.else_clause], block_name)
        when Prism::CaseNode, Prism::CaseMatchNode then case_runs(node, block_name)
        when Prism::CallNode then call_runs(node, block_name)
        else other_runs(node, block_name)
        end
      end

      def other_runs(node, block_name)
        result = sequence(node.compact_child_nodes, block_name)
        if LOOP_NODES.include?(node.class)
          result.last.positive? ? [MANY, MANY] : ZERO
        elsif JUMP_NODES.include?(node.class)
          [nil, result.last]
        else
          result
        end
      end

      def block_argument_runs(node, block_name)
        expression = node.expression
        forwards = expression.nil? || (expression.is_a?(Prism::LocalVariableReadNode) && expression.name == block_name)
        forwards ? [MANY, MANY] : runs(expression, block_name)
      end

      def sequence(nodes, block_name)
        fall = 0
        total = 0
        nodes.each do |child|
          child_fall, child_total = runs(child, block_name)
          total = [total, fall + child_total].max.clamp(0, MANY)
          return [nil, total] if child_fall.nil?

          fall = (fall + child_fall).clamp(0, MANY)
        end
        [fall, total]
      end

      def run_after((fall, total))
        return [nil, total] if fall.nil?

        run = (fall + 1).clamp(0, MANY)
        [run, [total, run].max]
      end

      # `head` runs first, then exactly one of `arms` (a nil arm is the path that takes none).
      def branch((head_fall, head_total), arms, block_name)
        return [nil, head_total] if head_fall.nil?

        results = arms.map { |arm| runs(arm, block_name) }
        falls = results.filter_map(&:first)
        fall = falls.empty? ? nil : (head_fall + falls.max).clamp(0, MANY)
        [fall, [head_total, (head_fall + results.map(&:last).max).clamp(0, MANY)].max]
      end

      def case_runs(node, block_name)
        clauses = node.conditions
        tests = clauses.flat_map { |clause| clause.is_a?(Prism::WhenNode) ? clause.conditions : [clause.pattern] }
        arms = clauses.map(&:statements) + [node.else_clause]
        branch(sequence([node.predicate, *tests], block_name), arms, block_name)
      end

      def call_runs(node, block_name)
        return run_after(runs(node.arguments, block_name)) if block_run_call?(node, block_name)

        block = node.block
        literal = block.is_a?(Prism::BlockNode)
        head = sequence([node.receiver, node.arguments, (block unless literal)], block_name)
        return [nil, head.last] if raising_call?(node) && !head.first.nil?
        return head unless literal

        body_total = runs(block.body, block_name).last
        body_total = MANY if body_total.positive? && repeating_call?(node)
        sequence_of(head, [body_total, body_total])
      end

      def sequence_of((fall, total), (next_fall, next_total))
        return [nil, total] if fall.nil?

        [(fall + next_fall).clamp(0, MANY), [total, (fall + next_total).clamp(0, MANY)].max]
      end

      def repeating_call?(node)
        ClosureEscapeAnalyzer.iterator_name?(node.name) || BlockCallTiming.kernel_loop?(node)
      end

      def raising_call?(node)
        node.receiver.nil? && RAISING_CALLS.include?(node.name)
      end

      # `blk.call` and its spellings.
      def block_run_call?(node, block_name)
        receiver = node.receiver
        !block_name.nil? && receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == block_name &&
          BLOCK_RUN_CALLS.include?(node.name)
      end
    end
  end
end
