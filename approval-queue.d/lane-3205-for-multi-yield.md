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
also return one, and their `each` yields one array (Ruby binds `[A, B]`). Nothing in the ELEMENT
type separates the two cases, and the engine reads only the parameter count the dispatcher answers
with, so it cannot separate them either. The issue did not say what to bind there.

One case is in fact unambiguous and is floored regardless, which the decision below accepts rather
than solves: a subclass that overrides `each` to declare a single ARRAY parameter
(`def each: () { ([String, Integer]) -> void } -> void`) has stated that the pair is yielded whole,
and Ruby binds the array for it. `MethodDispatcher#expected_block_param_types` answers with the
parameter types and no declaring owner, so telling that declaration from the generic
`Enumerator#each` it inherits needs a new dispatcher API. Measured: such a receiver binds
`[String, Integer]?` before this change and `Dynamic[top]?` after.

## Options and trade-offs

- **Keep the tuple.** This is right for `Hash#each` and wrong for `each_with_index`. It keeps the
  false positive the issue reports.
- **Bind the first slot.** This is right for `each_with_index` and wrong for `Hash#each`. It moves the
  false positive to `for kv in h.each; kv.first; end`.
- **Bind the union `A | [A, B]`.** One member is always right, and calls on the target stay silent:
  `x.upcase` and `x.first` both pass on `String | [String, Integer]`. A value that reaches a
  declared type does not. Measured with the union option in place: `def ret_direct; out = "z"; for b
  in strs.each_with_index; out = b; break; end; out; end` declared `() -> String` reports
  `def.return-type-mismatch` ("declared String, inferred \"z\" | String | [String, Integer]"), a
  false positive on correct code, and reports nothing under the floor. A bare `return b` inside the
  loop body does not report, so the shape that fires is assignment-then-return, not an early
  return.
- **Bind `Dynamic[top]`.** This is correct in both cases and drops precision in both. It also loses
  one true positive: `for kv in h.hs.each; kv.upcase; end` (`Hash[String, String]`) no longer
  reports `upcase` on the pair.

## Decision

Bind `Dynamic[top]`. A finding that fires on correct programs costs more than a lost precise type
(ADR-5, and the false-positive rule in `AGENTS.md`), and the union produces one when the target is
returned from a method with a declared return type. The floor covers `Enumerator` and every
descendant, checked by ancestry: `Enumerator::Lazy`, `Enumerator::Chain` and user subclasses. It also
covers an element union that has a tuple member. A multi-target or splat index keeps the tuple,
because Ruby decomposes it the same way in both cases.

The precision this costs reaches generated signatures, which is the surface a project notices first:
for `def pick; out = nil; for b in %w[a b].each_with_index; out = b; break; end; out; end`,
`rigor sig-gen --print` emitted `def pick: () -> (["a" | "b", Integer] | nil)` before the change and
now emits no row for `pick`, because a `Dynamic[top]` return is not written. The class itself is still
emitted with its other methods, so what a project loses is the one row, not the file. The old signature
was wrong — Ruby returns `"a"` — so the direction is right, but a project that relied on the row
loses it rather than seeing it corrected.

## To undo

Remove `StatementEvaluator#enumerator_floor` and its two call sites in `#for_iteration_element_type`,
and update the `ForNode` rule in `docs/internal-spec/inference-engine.md`. Two follow-ups would each
recover part of the precision: the cheaper one gives `MethodDispatcher#expected_block_param_types` a
declaring owner, so an overridden `each` that declares one array parameter is believed and only the
inherited generic declaration is floored; the fuller one needs an Enumerator type that records
whether its `each` yields several values. Nothing else depends on the floor.
