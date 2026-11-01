# An engine-built local re-grows precisely, with no floor and no admissibility gate, and only locals carry the fact

- **PR:** [#2606](https://github.com/rigortype/rigor/pull/2606)
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
- Drop both (taken). An added member joins as itself (value pin and literal shape dropped). The floor covered two
  things the seam cannot see, and review round 1 found both as new false positives on correct code:
  - a remover taking a store out again (`parts << nil; parts.compact!; parts.each { |s| s.upcase }`, the Hash
    `h[k] = nil; h.delete(k)` / `reject!` / `compact!` forms, `Set#delete`), since nothing narrows a carrier back;
  - a store through another holder of the object: an alias (`b = a`, `a = b = Array.new(n)`), a container
    (`[a]`, `{ k: a }`), an ivar, a closure, a call that yields or returns the receiver (`a.tap { }`,
    `a << :x << "s"`, `a.push(x).push(y)`), reflection (`send`, `method(:<<)`, `instance_exec`) or frame access
    (`binding`, `eval`).
  The fixes: a content adder marks the binding `:grown`, and a remover or filter on a grown carrier restores the
  reading it has without the fact (the floor, with `nil` dropped only by a remover that can take it out:
  `compact!`, the block filters, `clear`, `delete(nil)`, `Hash#delete`); and `ConstructionEscape` withholds
  the fact from any local that may escape anywhere in its body, by one allowlist of non-escaping positions (round 2
  inverted it: every argument escapes, and a receiver is safe only for a per-class core reader, or for an iterator
  or a modelled mutator whose value is discarded, unless the project defines that method on the class). What is
  left: a remover after a store answers the floored reading rather than a precise one; `pop`, `shift`, `slice!`,
  `subtract` and a non-nil `delete` keep a stored `nil` (as ruled in review round 2), so `a << nil; a.pop` still
  reads `nil`; and a local that escapes anywhere, including as any argument, answers as before for its whole body. A literal handed to a hand-written `-> Array[:multi]` after a
  value-preserving closer and a foreign store (`t = [:multi]; t.sort!; t << [:static, s]; t`) would report the
  mismatch the store really causes.
- Stamp instance variables too. Their bindings are seeded across methods from the class-ivar index, whose
  construction no single body witnesses, so a fact on `@a = []` would hold only within the writing body and needs its
  own invalidation story. Locals only (taken).

## Decision

Drop both the floor and the gate for a local whose binding carries the fact, and keep every other carrier on the
#2423 path, with the remover floor and the escape test above bounding it to stores the seam sees. The corpus A/B
(`lib/`, haml, mail, kramdown, yard) moved no diagnostic in either direction, and the `lib/` precision and protection
census is unchanged. The
precedent is #2423's re-grow of a precise nominal; this narrows its floor to carriers the engine cannot vouch for.

## To undo

Restore `MutationRejoin.precise_admitted` / `gradual_floor` inside `MutationRejoin.widen_synthesised` (the remover floor
and `ConstructionEscape` then become unnecessary but harmless) and drop the
`synthesised` branches in `SetMutation.join` / `.admitted`; the Scope table and the stamp can stay for slice 2
(`:defaulted`).
