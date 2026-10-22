# Keep a tail-only block return provisional, and type a block a project callee hands on as one that may repeat

- **PR:** [#2301](https://github.com/rigortype/rigor/pull/2301)
- **Issue:** [#2299](https://github.com/rigortype/rigor/issues/2299)
- **Class:** open-choice
- **Precedent:** [#2250](https://github.com/rigortype/rigor/pull/2250)
- **Decided:** 2026-10-22

## Background

The PR types a forwarded block's `yield` (`g(x, &)`, `g(x, &blk)`) and stops the block-return pass's tail-only answer from widening the enclosing method's return (#2299). Review found two places where the first draft said more than the program allows. Clearing the return sink around the tail-only pass dropped real `return`s from a block in expression position (a call argument, an array element, a chain receiver, an endless-def body), because the statement walk never enters such a block, and a caller testing the dropped value got an always-falsey warning on correct code. And the forward exposed a block value typed for one run (`count += 1` read as `1`) to a target that runs the block many times, which folded `a == 3` to always-falsey.

## Options and trade-offs

- **Sink, option A: clear it only when the tail-only answer is stale** (the tail reads a name the skipped prefix binds). Smaller, but a stale tail in expression position still loses its exit, the same false positive in a rarer shape.
- **Sink, option B (taken): file the side pass's `return`s as provisional, and let the statement walk's record of the same `ReturnNode` replace them.** Where the walk records the node, #2299's widening goes away; where it never enters the block, the provisional record stands as before the PR. Costs a node-identity set per method inference.
- **Repetition, option A (taken): count a project callee that hands its block on (`ProjectYielder.hands_block_on?`) as possibly repeating** in `ExpressionTyper#block_may_repeat?`, so captured locals the block rebinds read widened. Only the forward case: the literal-block case (`ProjectYielder.may_run_block_repeatedly?` not consulted by the expression pass) predates this PR and is tracked separately.
- **Repetition, option B: decline the forwarded block type when the target's `yield` sits in a loop or block.** Loses the forward's precision for the common `each` wrapper, the shape #1157 is about.

## Decision

Both taken options say less on correct programs and keep every exit the pre-PR engine reported. The provisional sink follows the node-identity filtering the `next` and `break` sinks already use. The repetition rule follows #2250 (issue #2127), which treats a callee that hands its block on as repeating for the later-run `return` pass; here the same answer feeds the block-value pass, limited to the hand-off clause.

## To undo

Option A for the sink: replace `StatementEvaluator.provisional_returns` with a sink clear gated on `tail_depends_on_body_binding?`. The repetition rule: drop the `ProjectYielder.hands_block_on?` clause from `block_may_repeat?`; the "reports nothing" pin in `spec/rigor/inference/forwarded_block_yield_type_spec.rb` then fails, as intended.
