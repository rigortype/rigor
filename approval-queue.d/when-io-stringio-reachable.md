# A trailing else after clauses covering an IO or File subject is not reported dead

- **PR:** [#2274](https://github.com/rigortype/rigor/pull/2274)
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

A stand-in counts as covered only when a clause names one of its Ruby 4.0.5 ancestors, written out in `STAND_IN_ANCESTORS` rather than read from RBS:

- `StringIO`: itself, `Enumerable`, `Object`, `Kernel`, `BasicObject`.
- `Tempfile`: itself, `Delegator`, `BasicObject`. A `Delegator` is no `Object`, so `when IO, Object` still leaves a `Tempfile` uncovered. RBS's `class Tempfile < File` is not read.

Only the `else` is affected; the `when` / `in` clause verdicts keep #1429's and #1485's rules.

The accepted cost is lost true positives on subjects that really hold an `IO` or `File`: `f = File.open("x"); case f when File then … else … end` no longer reports its dead `else`, since the type alone cannot tell such a subject from an `(IO)` parameter or `$stdout` that a test fills with a `StringIO`, the shape #2071 reports.

Other duck pairs were considered and left out, because no idiom gives a value holding the stand-in the core class's type:

- `String` / `Pathname`: stdlib RBS types paths as `string | _ToPath`, and inferred parameters are already declined.
- `Hash` / `ENV`: RBS types `ENV` as its own object.
- `Array` / `Enumerator`.
- `Proc` / `Method`.

## To undo

Remove the `stand_in_reaches_else?` call in `UnreachableClauseCollector#collect_case`, or drop a row from `DUCK_STAND_INS`.
