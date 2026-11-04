# frozen_string_literal: true

require_relative "../typing_state"

module Rigor
  module Inference
    # The value the statement evaluator last gave a loop node, and the scope it evaluated the loop from, so
    # `ExpressionTyper#type_of_loop` reads it instead of evaluating the loop again (issue #2031 review). A loop's value
    # costs an evaluation of its body, its fixpoint and its `break` passes included, and the typer types a loop again
    # wherever it types a node that holds one: the value of a write that wraps it (`id(z = (while …))`), a call it is
    # the receiver of (`(while …).itself`), each narrowing and rule that types that operand. Each such typing of a
    # loop nested in another loop re-ran the inner loop's passes, once more per level of nesting.
    #
    # The record is reused only for the very scope object the loop was evaluated from, so it answers exactly what an
    # evaluation would. It is not compared with `Scope#==`, which ignores several fields (`match_frame`,
    # `declared_refinements`, `struct_fold_safe_locals`, the opaque-block flags, `lexical_nesting`, the origins tables,
    # `discovery`): across the cost spec's 10933 reads every match was an identity match, and `lib/` read no record at
    # all (issue #2262). It lives in a per-thread map keyed by the loop node. The map's keys are weak but its values
    # are strong, and a recorded scope reaches its discovery, its environment and the parse tree that holds the key,
    # so a record never goes on its own (issue #2412): the map is a run-scoped slot ({TypingState.release_run_scoped}),
    # emptied when the run that filled it ends.
    module LoopValueRecord
      # ADR-129 WD1 — a Table, and a read-through cache of the computation's own value: a record read back answers
      # what evaluating the loop again from the same scope would.
      RECORD = TypingState.table(
        :loop_value_record,
        run_scoped: true, read_through: true,
        reason: "keyed by loop node; a read-through cache of the loop's own evaluation"
      )
      private_constant :RECORD

      # ADR-129 WD3 — a Resource read only as a delta: {#loops_evaluated} feeds a before/after comparison taken within
      # one conditional's evaluation, so with no loop evaluated in between the delta is zero.
      LOOPS_EVALUATED = TypingState.resource(
        :loops_evaluated,
        read_exemption: :delta_internal, run_scoped: true,
        reason: "a count of the loops this thread evaluated, incremented in place and read as a delta"
      )
      private_constant :LOOPS_EVALUATED

      module_function

      def record(node, scope, type)
        TypingState.current.write(LOOPS_EVALUATED, loops_evaluated + 1)
        conditional(node, scope, type)
      end

      # How many loops this thread has evaluated, so a conditional can tell whether its evaluation held one.
      def loops_evaluated = TypingState.current[LOOPS_EVALUATED] || 0

      # The same record for a conditional that evaluated a loop in a branch: `id(c ? (while …) : 0)` types the
      # conditional again from the scope it was evaluated from, and each typing evaluated the loop again from a
      # branch scope of its own, which multiplied the passes of every loop nested in it (issue #2262).
      def conditional(node, scope, type)
        record = [scope, type]
        state = TypingState.current
        state.weak_key_map(RECORD)[node] = record
        state.log_write(RECORD, node, record)
        type
      end

      # The recorded value of `node` evaluated from `scope` itself, or nil.
      def fetch(node, scope)
        state = TypingState.current
        slot = state[RECORD]&.[](node)
        state.log_read(RECORD, node, slot || TypingState::ABSENT)
        return nil if slot.nil?

        recorded, type = slot
        recorded.equal?(scope) ? type : nil
      end
    end
  end
end
