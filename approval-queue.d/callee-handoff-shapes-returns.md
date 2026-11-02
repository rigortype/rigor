# A callee that returns its parameter reads that parameter as written

- **PR:** [#2649](https://github.com/rigortype/rigor/pull/2649)
- **Issue:** [#2336](https://github.com/rigortype/rigor/issues/2336)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-03

## Background

`def ident(h) = h` writes nothing, but its caller may write the result: `r = ident(options); r[:format] = "json"`
changes `options`. The caller-side flow does not track aliases at all (`r = options; r[:k] = 1` leaves `options`
narrow too), so the floor never learnt that `options` changed. The issue asked for a conservative floor if exact
tracking was heavy.

## Options and trade-offs

- Track the alias at the caller: exact, but the caller has no alias tracking to extend; it would be a new
  mechanism for every local write, not just call results.
- Floor the parameter at every call of a def that may return it, whether or not the caller uses the result:
  cheap and conservative, at the cost of a lost true positive after a call whose result is dropped.
- Floor only when the call's value is used: closer, but the floor runs per call and does not see the statement's
  context, and a callee chain (`r = ident(h); r[:k] = 1` inside another def) needs the census answer anyway.

## Decision

The floor at every call, kept narrow: only the parameter itself or an alias that is it counts, as the def's last
expression (through branches, `begin` clauses, parentheses, a write's value and `||` / `&&`) or a `return` outside
a lambda. A call's result never counts, not even `h.tap { }` or `h.to_s`, so the readers #2595 pinned keep their
true positives; a part of the parameter (`h.fetch(:k)`) does not count; `initialize` and setters are left out,
since the caller's syntax drops their value; a parameter rebound to a copy first does not count.

## To undo

Drop `note_tail`, `note_return` and `returned_parameters` from `CalleeWriteCensus` and the `returns:` argument from
`StatementEvaluator#callee_write_census`. The "a callee that returns its parameter" rows of
`callee_hand_off_shapes_spec.rb` then fail.
