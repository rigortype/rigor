# A cross-file top-level def binds in a core-iterator block and a declined bind answers Dynamic

- **PR:** [#2907](https://github.com/rigortype/rigor/pull/2907)
- **Issue:** [#2861](https://github.com/rigortype/rigor/issues/2861)
- **Class:** open-choice
- **Precedent:** [#316](https://github.com/rigortype/rigor/issues/316)
- **Decided:** 2026-11-06

## Background

Issue #316 enters every block with `self` unmodelled and declines to bind an implicit-self call to a top-level
`def` from another file there, so a project's `def output` does not capture RSpec's `output` matcher. #2861 is
the cost: `rows.map { |r| format(r).bit_length }` against a project `def format(x) = 42` fell through to
`Kernel#format` and reported `bit_length` on a `String`, where Ruby returns 6. The coordinator settled that a
declined bind must never answer the Kernel method of the same name, and that the def should bind where it
exists project-wide, keeping the old answer only where `self` is provably another object. Under the opaque mark
`self` is always unknown, so binding everywhere would undo #316's own repro.

## Options and trade-offs

- Bind the cross-file def under every opaque mark. Fixes the repro, but reopens #316: `output(/ok/)` in an
  RSpec block types as the helper's `nil` and reports on correct code.
- Keep the gate and answer `Dynamic[top]` on a decline. Removes the false positive, but `myhelper(r).upcase`
  in `rows.map` stays untyped (the issue's missed report).
- Lift the mark only where the callee is known to run the block under the caller's `self` (a catalogued
  non-escaping core iterator, `tap` / `then`, an inherited `Enumerable` method, on a typed explicit receiver,
  the project defining none of them), and answer `Dynamic[top]` on every remaining decline.

## Decision

The third: it fixes both halves of #2861 and leaves #316's DSL blocks (receiverless calls, unknown receivers)
declining. The catalogue is `ClosureEscapeAnalyzer`'s, whose entries are documented as invoking the block in
place, so no new knowledge table is introduced. `instance_exec` on an object whose class defines the name, and
`instance_eval` on a `BasicObject`, now answer `Dynamic[top]`; before, they answered `Kernel#format`'s
`String`, which was the same fall-through and not the class's method.

## To undo

Drop `Inference::SelfPreservingBlock` and the `Scope#entering_self_preserving_block` entry (both block-entry
paths go back to `entering_opaque_block`), and remove `ExpressionTyper#declined_top_level_def_answer`.
