# Erase a loop element's shape at every depth only when the body mutates an element by a named mutator, and match the loop value record by identity

- **PR:** [#2285](https://github.com/rigortype/rigor/pull/2285)
- **Issue:** [#2262](https://github.com/rigortype/rigor/issues/2262)
- **Class:** open-choice
- **Precedent:** [#2242](https://github.com/rigortype/rigor/pull/2242)
- **Decided:** 2026-10-22

## Background

#2262 asked that the widening `a.each { … }` applies to its own return value (`Array[Array[Integer]]`) also reach a `for` loop's value and the receiver's binding, since a body that mutates a loop element in place (`x << 2`) changes a shape one level below the one the binding still carried. It left open when the deep drop applies, because dropping every nested shape after any loop costs the precision a reading loop should keep. It also asked for the `LoopValueRecord` `==` fallback to be dropped if a measurement showed it unneeded, and for a cost spec for the ternary loop-argument blowup "if it can be fixed within reason".

## Options and trade-offs

- **Deep drop after every `for` / block call whose body holds any call.** The `for` value already treated any call as a possible mutation of the collection's contents (one level), so this extends the existing rule. It also drops `[[1]]` after `for x in a; x.size; end`, so the issue's own control (a loop that does not mutate keeps its precise shape and its true positive) would fail.
- **Deep drop when the body calls a `SHAPE_MUTATORS` method, or runs an operator write, on the loop index or a block parameter, or on an index chain rooted at one (taken).** Precise for the reading loop, and it covers the issue's two spellings. It does not follow `y = x; y << 1` or `add(x)` with a callee that mutates its argument, the same limit the straight-line widening has.
- **Follow aliases and call arguments too.** Sound for those shapes, but it needs the callee-mutation and alias analyses the loop seam does not run, and would erase on most loops that call anything with the element.
- For the record: keep the `==` fallback against drop it. The measurement (PR body) found no `==`-only hit in the specs or in `lib/`, and `Scope#==` ignores fields a typing can read, so identity is both sufficient and safer (taken).
- For the blowup: record a conditional's value when its evaluation evaluated a loop (taken), against recording every conditional (a retained scope per `if` node for no gain without a loop), or leaving it for a follow-up.

## Decision

The named-mutator rule, identity matching, and the loop-gated conditional record. The `for` value's existing one-level rule is unchanged for a body that mutates nothing at the element level (a call on the collection or an alias still drops one level). The precedent is #2242, which chose the same conservative side for the `for` value (say less where the engine cannot back a claim) and bounded the cost with the record.

**Accepted losses.** The detector treats every name a nested block or `for` binds, `it` / `_1` read anywhere, and an accumulator parameter as an element name. Narrowing to blocks rooted at an element, and to the element position of `each_with_object` / `inject`, was not clean (it needs the call's block-parameter positions per method), so these keep the wider rule, which only loses precision: `each_with_object({}) { |x, h| h[x] = 1 }`, `inject([]) { |acc, x| acc << x }` and `out.each { |o| o << x }` over a collection of nested shapes drop those shapes. Zero rows changed on the herb corpus.

## To undo

Widen the detector to follow aliases or call arguments by extending `DeepErasure.element_mutation?` (and its documentation in `docs/internal-spec/inference-engine.md`); restore the `==` fallback by adding `|| recorded == scope` to `LoopValueRecord.fetch`; drop the conditional record by returning `eval_if` / `eval_unless` to the dispatch table and removing the fetch in `ExpressionTyper#type_of_conditional`, which brings the nested ternary spelling back to 6^depth loop evaluations.
