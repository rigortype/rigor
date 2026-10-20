# frozen_string_literal: true

module Rigor
  module Inference
    # The value the statement evaluator last gave a loop node, and the scope it evaluated the loop from, so
    # `ExpressionTyper#type_of_loop` reads it instead of evaluating the loop again (issue #2031 review). A loop's value
    # costs an evaluation of its body, its fixpoint and its `break` passes included, and the typer types a loop again
    # wherever it types a node that holds one: the value of a write that wraps it (`id(z = (while …))`), a call it is
    # the receiver of (`(while …).itself`), each narrowing and rule that types that operand. Each such typing of a
    # loop nested in another loop re-ran the inner loop's passes, once more per level of nesting.
    #
    # The record is reused only for a scope equal to the one the loop was evaluated from, so it answers exactly what
    # an evaluation would. It lives in a per-thread map whose keys are held weakly, so a record goes when its parse
    # tree does.
    module LoopValueRecord
      KEY = :rigor_loop_value_record
      private_constant :KEY

      module_function

      def record(node, scope, type)
        (Thread.current[KEY] ||= ObjectSpace::WeakKeyMap.new)[node] = [scope, type]
        type
      end

      # The recorded value of `node` evaluated from a scope equal to `scope`, or nil.
      def fetch(node, scope)
        slot = Thread.current[KEY]&.[](node)
        return nil if slot.nil?

        recorded, type = slot
        recorded.equal?(scope) || recorded == scope ? type : nil
      end
    end
  end
end
