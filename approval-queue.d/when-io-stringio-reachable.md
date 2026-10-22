# A trailing else after clauses covering an IO, File or String subject is not reported dead

- **PR:** none
- **Issue:** [#2071](https://github.com/rigortype/rigor/issues/2071)
- **Class:** open-choice
- **Precedent:** [ADR-117](../docs/adr/117-standard-streams-typed-by-idiom.md)
- **Decided:** 2026-10-22

## Background

`io = STDOUT; case io when IO then 1 else 2 end` reported the `else` as unreachable (`:exhausted_else`), although Ruby runs it for a `StringIO`, which the idiomatic `IO` type admits (ADR-117 Decision point 3). The issue left open how narrow the decline should be: declining on every non-literal subject would mute the dead-`else` check broadly.

## Options and trade-offs

- Decline the dead `else` on every non-literal (`Nominal`) subject. This is safest, but it silences the check almost everywhere.
- Decline only when the subject holds a `Nominal` of a class whose idiomatic stand-in is not its subclass, and no clause names that stand-in. This is narrow, but it needs a list of such classes.
- Follow the RBS ancestry, as #1485 does for clauses. That misses the case outright: stdlib RBS declares `class Tempfile < File`, while Ruby's `Tempfile` is a `Delegator`.

## Decision

Take the second option, with the table `UnreachableClauseCollector::DUCK_STAND_INS`:

- `IO` → `StringIO`, `Tempfile`
- `File` → `Tempfile`
- `String` → `Pathname`

A stand-in counts as covered when a clause names it, names `Object`, `BasicObject` or `Kernel`, or names a class RBS places above the stand-in but not above the subject's class. This keeps RBS's `Tempfile < File` from covering it. Only the `else` is affected; the `when` / `in` clause verdicts keep #1429's and #1485's rules.

Including `String` costs a true positive the type alone cannot tell apart: a subject typed `String` by a conversion that never yields a `Pathname`, such as `x = raw ? String(raw) : nil`, no longer reports its dead `else`. The #1925 fixture that pinned that shape now pins the same `when nil` narrowing on an array literal. Other duck pairs were considered and left out, since no common program passes them through the class's type:

- `Hash` / `ENV`: RBS types `ENV` as its own object.
- `Array` / `Enumerator`.
- `Proc` / `Method`.

## To undo

Remove the `stand_in_reaches_else?` call in `UnreachableClauseCollector#collect_case`, or drop a row from `DUCK_STAND_INS` (the `String` row restores the `String(raw)` report).
