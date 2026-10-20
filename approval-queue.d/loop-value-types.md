# Type a for loop over a collection not known to answer itself from each as Dynamic[top], and a literal while true as its break values alone

- **PR:** [#2242](https://github.com/rigortype/rigor/pull/2242)
- **Issue:** [#1216](https://github.com/rigortype/rigor/issues/1216)
- **Class:** open-choice
- **Precedent:** [#2202](https://github.com/rigortype/rigor/pull/2202)
- **Decided:** 2026-10-21

## Background

#1216 asks that `r = for i in [1, 2]; end` type `r` as the collection's type, since Ruby's `for` returns the collection, and that a `Dynamic` collection stay gradual. Ruby's `for` is really `coll.each { … }` and answers whatever that `each` answers: the receiver for an Array, Hash or Range, but the block's value for a project class whose `each` is `def each = yield(1)`, and the underlying collection for an `Enumerator`. The issue did not say what a collection outside the core ones answers. #2031 separately asks that a `while` / `until` loop ended by `break value` answer `nil` joined with the break values, which for `while true; break 1; end` would add a `nil` the loop never answers.

## Options and trade-offs

- **The collection's type for every collection.** Matches the issue's wording, but claims a type for a project or `Enumerator` collection the analysis cannot back; a project `each` that returns something else would make the caller read the wrong type and could report on correct code.
- **Dispatch the collection's `each` and use its return type.** The most precise answer, but it needs the block-carrying dispatch and project-method return inference the statement evaluator's `for` path does not run today, a larger change than the issue asks for.
- **The collection's type for the core collections whose `each` answers its receiver, `Dynamic[top]` otherwise (taken).** Sound everywhere, precise for the common case (an Array, Hash or Range literal, a nominal Array), gradual where the answer is not known.
- For `while true`: joining `nil` regardless (simple, but `x = while true; break 1; end; x + 1` reports a possible nil on correct code) against treating the literal `true` / `false` / `nil` predicate as never ending the loop (taken; any other predicate is assumed to end it).

## Decision

The core-collection rule and the literal-predicate rule. Both say less where the analysis cannot prove more, the conservative reading AGENTS.md's false-positive rule asks for; #2202 set the same shape for value-position constructs: answer as the statement form does and decline to `Dynamic[top]` rather than guess.

The review of #2242 added two refinements by the same reasoning: a `Set` is left to `Dynamic[top]` (its literal is a `Constant` carrier the rule did not read, and no example pinned it), and since `each` answers the collection after the body ran, a body that may change its contents (any call, `yield`, `super` or index store, which may reach it through an alias) drops the value's shapes and refinements to their nominal, joined with the variable's binding after the loop when the collection is a local or instance variable the loop does not rebind. That costs the literal shape for a body that only reads (`break :b if i == 2` gives `:b | Array[Integer]`), the price of not tracking aliases.

## To undo

Widen `StatementEvaluator#each_answers_self?` or narrow `FOR_MUTATING_NODES` (or replace `for_value` with a dispatch of `each`), or drop the `endless_loop_predicate?` early return in `loop_value`; update `spec/integration/fixtures/loop_value.rb`, its snapshot `spec/integration/snapshots/loop_value.yml`, and the "loops" examples in `spec/rigor/inference/statement_evaluator_spec.rb`.
