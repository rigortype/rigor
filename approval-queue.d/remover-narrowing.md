# A remover narrows only its receiver's own binding, instance variables included, and a literal-key delete keeps a closed hash shape

- **PR:** [#2621](https://github.com/rigortype/rigor/pull/2621)
- **Issue:** [#2608](https://github.com/rigortype/rigor/issues/2608)
- **Class:** open-choice
- **Precedent:** [#2606](https://github.com/rigortype/rigor/pull/2606)
- **Decided:** 2026-11-02

## Background

#2608 asked removers (`compact!`, a literal-nil `delete`, nil-test `reject!` / `select!` blocks, a literal-key
`HashShape#delete`) to narrow the element type where Ruby guarantees it. Three readings were left open: what an alias
copy of the receiver reads after the call, which kinds of binding narrow, and what a closed hash shape becomes under a
literal-key `delete` (until now every `delete` erased a shape to a nominal).

## Options and trade-offs

- Alias copies: narrow every alias (needs alias tracking, #2335, which does not exist), narrow no receiver that has an
  alias (needs the same tracking to know), or narrow the receiver only. The copy keeps its pre-call reading, which is
  wider than the object but still true of it, so it costs precision and never a false positive (taken).
- Binding kinds: locals only, locals and instance variables, or every kind `MutationWidening` widens (class variables,
  globals). A guard already narrows a local or an ivar, and the intervening-call reset (B2.2) restores an ivar
  narrowed below its class seed, so locals and ivars match the guard rule (taken). Class variables and globals are
  shared more widely and keep today's reading.
- A closed shape under `delete(:k)`: erase it as before, or keep the shape without the key. Keeping it is exact for a
  closed shape and lets the shape's own rewrite rules keep working after the call (taken). An open shape, a read-only
  key and a non-literal key keep the erasure.

## Decision

Narrow the receiver's binding only, for locals and instance variables, and keep a closed shape minus the deleted key.
The corpus A/B (`lib/`, haml, mail, kramdown, yard) moved no diagnostic and the `lib/` census is unchanged. Two #2606
controls moved with it: the #1289 alias control now closes its literal with a `delete` of an untyped key, and a
closed `plain.delete(:a)` reads `{}`.

## To undo

Restrict `RemoverNarrowing::NARROWING_RECEIVERS` to `LocalVariableReadNode` for locals only, or make
`RemoverNarrowing.narrow_shape` answer `nil` to restore the erasure. Nothing else depends on either.
