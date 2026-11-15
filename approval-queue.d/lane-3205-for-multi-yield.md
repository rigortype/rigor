# A single `for` target over an Enumerator whose element is a tuple binds `Dynamic[top]`

- **PR:** [#3256](https://github.com/rigortype/rigor/pull/3256)
- **Issue:** [#3205](https://github.com/rigortype/rigor/issues/3205)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-15

## Background

A `for` index binds the way a block's parameters do. A single target (`for b in`) takes the first
yielded value, and a multi-target or splat index takes all of them. Before this change, Rigor bound a
single target to the whole yield as a tuple, so `for b in strs.each_with_index; b.upcase; end`
reported `upcase` as undefined on `[String, Integer]`. In Ruby, `b` is the String.

When `each` is declared to yield several values (`{ (A, B) -> void }`), the fix is exact: the target
binds `A`. An `Enumerator[[A, B]]` is ambiguous, though. `each_with_index` and `each_with_object`
return one, and their `each` yields two values (Ruby binds `A`). `Hash#each`, `Hash#each_pair`,
`Struct#each_pair`, and `pairs.each`, `pairs.map`, `reverse_each` and `cycle` over an Array of pairs
also return one, and their `each` yields one array (Ruby binds `[A, B]`). Nothing in the type
separates the two cases. The issue did not say what to bind there.

## Options and trade-offs

- **Keep the tuple.** This is right for `Hash#each` and wrong for `each_with_index`. It keeps the
  false positive the issue reports.
- **Bind the first slot.** This is right for `each_with_index` and wrong for `Hash#each`. It moves the
  false positive to `for kv in h.each; kv.first; end`.
- **Bind the union `A | [A, B]`.** One member is always right, and calls on the target stay silent:
  `x.upcase` and `x.first` both pass on `String | [String, Integer]`. A value that reaches a
  declared type does not. With `ret: (bool) -> String`, returning the loop variable reports
  `def.return-type-mismatch` ("declared String, inferred String | [String, Integer]"), a false
  positive on correct code.
- **Bind `Dynamic[top]`.** This is correct in both cases and drops precision in both. It also loses
  one true positive: `for kv in h.hs.each; kv.upcase; end` (`Hash[String, String]`) no longer
  reports `upcase` on the pair.

## Decision

Bind `Dynamic[top]`. A finding that fires on correct programs costs more than a lost precise type
(ADR-5, and the false-positive rule in `AGENTS.md`), and the union produces one when the target is
returned from a method with a declared return type. The floor covers `Enumerator` and every
descendant, checked by ancestry: `Enumerator::Lazy`, `Enumerator::Chain` and user subclasses. It also
covers an element union that has a tuple member. A multi-target or splat index keeps the tuple,
because Ruby decomposes it the same way in both cases. The coordinator ruled on this in the PR's
review round.

## To undo

Remove `StatementEvaluator#enumerator_floor` and its two call sites in `#for_iteration_element_type`,
and update the `ForNode` rule in `docs/internal-spec/inference-engine.md`. A more precise follow-up
needs an Enumerator type that records whether its `each` yields several values. Nothing else depends
on the floor.
