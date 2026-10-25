# frozen_string_literal: true

require "prism"

require_relative "block_call_timing"
require_relative "closure_escape_analyzer"
require_relative "project_method_ownership"

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
    # - the body of `while` / `until` / `for`, of `Kernel#loop`, or the block of a catalogued core iterator
    #   ({ClosureEscapeAnalyzer.iterator_name?}) is {MANY} when a run lies on a path that reaches the next
    #   iteration (falling through the body, or a `next`); a run only on a path that leaves it (`return`, `break`,
    #   `raise`) adds what that path holds, so `xs.each { |x| return yield(x) if x > 1 }` is one run;
    # - a hand-off of the block (`g(&blk)`, `g(&)`, `...`) is {MANY};
    # - a block under any other call runs its body once (`then { yield }`, `synchronize { yield }`,
    #   `File.open(f) { yield f }`), a lambda body is not run at its definition, and a nested `def` is not this
    #   method's body.
    #
    # Reading `&blk` other than calling it (`return unless blk`) is no run.
    #
    # A result is `[fall, total, nxt, brk]`: the most runs on a path that falls through the node, on any path
    # through it, on a path that ends at a `next`, and on one that ends at a `break` (nil where no path does).
    module BlockRunCount
      module_function

      MANY = 2
      ZERO = [0, 0, nil, nil].freeze
      ALWAYS = [MANY, MANY, nil, nil].freeze
      BLOCK_RUN_CALLS = Set[:call, :yield, :===, :[]].freeze
      LOOP_NODES = [Prism::WhileNode, Prism::UntilNode, Prism::ForNode].freeze
      RAISING_CALLS = Set[:raise, :fail].freeze
      private_constant :ZERO, :ALWAYS, :BLOCK_RUN_CALLS, :LOOP_NODES, :RAISING_CALLS

      # Memoised per `def` node for the run ({ProjectMethodOwnership.memo}): every call site, and every pass over
      # one, asks the same callee.
      def may_repeat?(def_node, scope)
        memo = ProjectMethodOwnership.memo(scope)[:block_runs]
        return memo[def_node] if memo.key?(def_node)

        memo[def_node] = runs(def_node.body, def_node.parameters&.block&.name)[1] >= MANY
      end

      def runs(node, block_name)
        case node
        when nil, Prism::DefNode, Prism::LambdaNode then ZERO
        when Prism::YieldNode then run_after(sequence(node.compact_child_nodes, block_name))
        when Prism::ForwardingArgumentsNode then ALWAYS
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
        case node
        when *LOOP_NODES then iterated(result)
        when Prism::ReturnNode then [nil, result[1], result[2], result[3]]
        when Prism::NextNode then [nil, result[1], larger(result[2], result[0]), result[3]]
        when Prism::BreakNode then [nil, result[1], result[2], larger(result[3], result[0])]
        else result
        end
      end

      # A body run any number of times: {MANY} when a run reaches the next iteration, else the runs of the paths
      # that leave it. It may run zero times or be left by a `break`, and the walk continues after it either way.
      def iterated((fall, total, nxt, brk))
        again = [fall, nxt].compact.max || 0
        return ALWAYS if again.positive?

        [[0, brk].compact.max, total, nil, nil]
      end

      # A body run once: a `next` or `break` in it ends the run, and the walk continues after the call.
      def run_once((fall, total, nxt, brk))
        [[fall, nxt, brk].compact.max, total, nil, nil]
      end

      def block_argument_runs(node, block_name)
        expression = node.expression
        forwards = expression.nil? || (expression.is_a?(Prism::LocalVariableReadNode) && expression.name == block_name)
        forwards ? ALWAYS : runs(expression, block_name)
      end

      def sequence(nodes, block_name)
        nodes.reduce(ZERO) do |acc, child|
          break acc if acc[0].nil?

          chain(acc, runs(child, block_name))
        end
      end

      # `first` then `second`; nothing follows a path that does not fall through `first`.
      def chain(first, second)
        fall, total, nxt, brk = first
        return first if fall.nil?

        [second[0] && sum(fall, second[0]), [total, sum(fall, second[1])].max,
         larger(nxt, second[2] && sum(fall, second[2])), larger(brk, second[3] && sum(fall, second[3]))]
      end

      def run_after(result)
        chain(result, [1, 1, nil, nil])
      end

      # `head` runs first, then exactly one of `arms` (a nil arm is the path that takes none).
      def branch(head, arms, block_name)
        return head if head[0].nil?

        arms.map { |arm| chain(head, runs(arm, block_name)) }.reduce do |a, b|
          [larger(a[0], b[0]), [a[1], b[1]].max, larger(a[2], b[2]), larger(a[3], b[3])]
        end
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
        return [nil, head[1], head[2], head[3]] if raising_call?(node)
        return head unless literal

        body = runs(block.body, block_name)
        chain(head, repeating_call?(node) ? iterated(body) : run_once(body))
      end

      def sum(left, right)
        (left + right).clamp(0, MANY)
      end

      def larger(left, right)
        [left, right].compact.max
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
