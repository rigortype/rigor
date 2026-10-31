# A callee def reached through an inherited lookup is floored without being walked

- **PR:** [#2516](https://github.com/rigortype/rigor/pull/2516)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-31

## Background

#2516 teaches the callee floor to follow `Const.name(local)`, instance receivers and hand-offs on other classes. A
singleton def a class inherits (`Sub.leaf` defined on `Base`) is written in another class: its self-calls resolve with
`self` of the receiver (`Sub`), but its constants resolve in `Base`'s lexical nesting. Review found three rounds of
order-dependent or wrong answers from threading that second context (the census memo, the chain nodes and the
constant lookup each had to carry it), each a false positive on correct code.

## Options and trade-offs

- Thread an owner that carries both the `self` class and the defining class through the memo, the chain nodes and the
  constant lookup. Precise, but each round found another place the pair leaked (a self-call back into the subclass, two
  subclasses reaching one base def).
- Do not walk such a def: floor the passed argument and record a `BudgetTrace::CALLEE_CHAIN_CAP` hit. Flooring drops
  facts, so it removes the literal-shape reports threading caused; like any floor it can surface a mismatch against a
  declared type. It costs precision: a literal passed to an inherited singleton method
  that only reads it now loses its shape.

## Decision

The user chose the conservative reading ("推奨で進めて", accepting the coordinator's recommendation): a def whose defining
class differs from the receiver's or `self`'s class is not walked; every content parameter reads as mutated. The same
holds for a chain node reached under a different owner: a node is one parameter of one def under one owner, so no
owner's answer fills another's. The direct inherited shapes (`Sub.leaf`, `leaf` inside `Sub`) stay silent through the
floor rather than the walk. A hand-off receiver is resolved by name over the defining class's prefixes plus the top level
AND typed under each truncation of the def's nesting (so an alias, an inherited or included constant and a constant
holding an instance are seen), and the callees of the two are unioned. The user chose the typed resolution first as a
fallback on a miss ("Add fallback") and then to always take the union ("Always union"): a by-name hit can be shadowed by
an alias or an inherited constant in the real lookup. The union only adds callees.

## To undo

Return the owner from `inherited_singleton_callee` and `receiver_callees_in` instead of `FLOOR_ALL` and give
`CalleeOwner` the defining class again, threading it into `hand_off_scopes` and the `resolved_census` key. The specs in
`spec/integration/callee_floor_hand_off_spec.rb` ("an inherited singleton def") hold the shapes that must stay silent.
