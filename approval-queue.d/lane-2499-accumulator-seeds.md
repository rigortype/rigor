# Empty literal seeds of heap slots lose their emptiness; non-empty literal seeds keep their exact type

- **PR:** [#2500](https://github.com/rigortype/rigor/pull/2500)
- **Issue:** [#2499](https://github.com/rigortype/rigor/issues/2499)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-29

## Background

An instance, class or global variable or a constant seeded with an empty literal pinned the slot to the empty
value. A read in another method then folded `length > 0` always-falsey, even when a subclass, a mixin, another
file, a memoised accessor or an `attr_reader` caller filled it (#2491, #2492, #2496, #2497). The coordinator's
revised decision on #2499 settled the scope: target the accumulator idiom only, and leave non-empty literals
exact. Two choices inside that scope were left to the lane: what counts as an empty seed, and which true
positives may be lost. This change also amends ADR-58's seed semantics.

## Options and trade-offs

- Erase every unfrozen literal stored in a heap slot. This was rejected by the coordinator: it loses the exact
  types of modes and config tables, and it would add `argument-type-mismatch` against literal-typed RBS
  parameters.
- Track mutations across subclasses, mixins, files and accessors. This is precise, but it is an escape analysis,
  which the maintainer ruled out for this lane.
- Drop only the emptiness of an empty seed, keyed on the rvalue node (`""`, `+""`, `[]`, `{}`). This is cheap
  and needs no new census. It loses only folds that read the seed's emptiness.

## Decision

The third option. The test is on the rvalue node, so `[].freeze` / `{}.freeze` and an empty value reached
through another expression keep today's type. The survey diff (mastodon, redmine, mail, Rigor `lib`) moved no
row, so no true positive was observed lost. The loss accepted under ADR-5: a slot that really stays empty no
longer folds `empty?`, `size > 0` or `length > 0` from its seed in another method, and a dead branch guarded that
way is no longer reported.

## To undo

Remove the `EmptySeed.erase` calls in `ScopeIndexer` (`record_ivar_write`, `record_ivar_or_write`,
`record_cvar_write`, `record_global_write`, `record_constant_write`) and the ADR-58 amendment. The pins in
`spec/integration/accumulator_seed_spec.rb` will then fail. Two fixtures (`constant_path_write_nesting`,
`constant_path_write_residues`) were moved to non-empty seeds and need no revert.
