# A widened Set keeps its `Dynamic[top]` floor, so a missing method on one of its classes no longer reports

- **PR:** [#2360](https://github.com/rigortype/rigor/pull/2360)
- **Issue:** [#2294](https://github.com/rigortype/rigor/issues/2294)
- **Class:** open-choice
- **Precedent:** [#2290](https://github.com/rigortype/rigor/pull/2290)
- **Decided:** 2026-10-26

## Background

#2294 makes a Set mutator widen the receiver's element. The widened carrier is the typed Set #2290 builds for a
non-constant literal, `Set[E | Dynamic[top]]`, with the `Dynamic[top]` floor. That floor is what lets a later store
re-grow the set; it is also what Array's straight-line join adds (`a = [1]; a << "a"` reads
`Array[1 | Dynamic[top]]` on master). The issue's acceptance criteria asked that `s = Set[1]; s << "a"; s.each { |v|
v.upcase }` still report for `Integer`. On master it does, but only because the `<<` was ignored and the set still
read `Set[1]`. A union carrying `Dynamic[top]` reports no missing method, so after the change it reports nothing.

## Options and trade-offs

- Keep the floor: correct programs that read what they added never report, and the next store re-grows the set.
  Costs this true positive and every other missing-method report on a mutated set's built-with classes.
- Widen without the floor (`Set[Integer | String]`): keeps the report for `Integer`. But the carrier would then be
  precise, so the next store could not re-grow it, and a later read of a third class would report on correct code.
  That is the one-store false positive the Array join's floor exists to prevent.

## Decision

Keep the floor. False positives outrank the true positive, and the choice matches the Array behaviour and #2290's
typed-Set floor. The `Set[1]; add("a")` true positive is lost.

## To undo

In `SetMutation.floored`, drop the `Type::Combinator.untyped` member, and stop `SetMutation.join` adding to a
gradual-only carrier. Then decide how a second store re-grows a precise Set, which `SetMutation.regrowable?`
currently grants only through the floor. The constant-set examples in
`spec/integration/set_mutation_widening_spec.rb` pin `Dynamic[top]` in their expected types and would change.
