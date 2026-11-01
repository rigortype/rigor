# An engine-built local re-grows precisely, with no floor and no admissibility gate, and only locals carry the fact

- **PR:** [#0000](https://github.com/rigortype/rigor/pull/0000)
- **Issue:** [#2555](https://github.com/rigortype/rigor/issues/2555)
- **Class:** open-choice
- **Precedent:** [#2423](https://github.com/rigortype/rigor/pull/2423)
- **Decided:** 2026-11-02

## Background

Lever L3 of #2555 adds a per-scope `:synthesised` construction fact so the mutation seams can tell a collection the
engine built from one a declaration made. The brief settled the mechanism (a Scope table modelled on
`optimistic_locals`, no Type field) and said a synthesised binding "widens precisely with no `Dynamic[top]` floor".
Two readings were left open: whether the #561 seed-admissibility gate (`MutationRejoin.precise_admitted`, which floors
any added member the element does not accept) still applies to such a carrier, and whether instance variables carry
the fact.

## Options and trade-offs

- Keep the admissibility gate and drop only the floor. A foreign store would then join nothing at all, which is the
  one-store false positive again (`a = Array.new(n, 0); a << "s"` would keep `Array[Integer]`).
- Drop both (taken). An added member joins as itself (value pin and literal shape dropped). The cost is the shape the
  floor existed for: nothing narrows the carrier back when a remover takes the store out (`a << 1; a.pop`), so a
  later declared boundary can see the stale arm. A literal handed to a hand-written `-> Array[:multi]` after a
  value-preserving closer and a foreign store (`t = [:multi]; t.sort!; t << [:static, s]; t`) would report the
  mismatch the store really causes.
- Stamp instance variables too. Their bindings are seeded across methods from the class-ivar index, whose
  construction no single body witnesses, so a fact on `@a = []` would hold only within the writing body and needs its
  own invalidation story. Locals only (taken).

## Decision

Drop both the floor and the gate for a local whose binding carries the fact, and keep every other carrier on the
#2423 path. The corpus A/B (`lib/`, haml, mail, kramdown, yard) moved no diagnostic in either direction, and the
`lib/` precision and protection census is unchanged, so the remover-after-store cost did not appear in practice. The
precedent is #2423's re-grow of a precise nominal; this narrows its floor to carriers the engine cannot vouch for.

## To undo

Restore `MutationRejoin.precise_admitted` / `gradual_floor` inside `MutationRejoin.widen_synthesised` and drop the
`synthesised` branches in `SetMutation.join` / `.admitted`; the Scope table and the stamp can stay for slice 2
(`:defaulted`).
