# A top-level def the call may not run floors every argument, and a hand-off inside one unions the same-named instance defs

- **PR:** [#2623](https://github.com/rigortype/rigor/pull/2623)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** [#2607](https://github.com/rigortype/rigor/pull/2607)
- **Decided:** 2026-11-02

## Background

The `<toplevel>` def table keeps one def per name (the last writer's), and a `def` in an anonymous `Class.new` body or in
a block files itself there too. A receiverless call inside a class reaches a top-level def only when nothing earlier on
its chain answers the name. Reading the winner as written is wrong whenever another def, alias or ancestor may be the one
that runs, and reading it was the behaviour for a call at the top level already.

## Options and trade-offs

- Read the winning def as written (the status quo at the top level): exact when the table is right, a false positive
  when it is not (a second def that writes, an alias, an `Object` reopening, an anonymous class's def).
- Floor the winning def's own parameters (`FLOOR_ALL`): stays inside the def's arity, so a second def of the name that
  takes more arguments is missed.
- Floor every argument the call passes (`FLOOR_EVERY`), whenever the def may not be the one the call runs
  (`Scope#toplevel_def_ambiguity`, `ToplevelDefCensus`, `StatementEvaluator#chain_may_answer?`). It loses a true positive
  on a call to a non-writing top-level helper whenever the name is defined twice, aliased, defined in a block (an RSpec
  `describe`'s helper) or defined on `Object`, or a class has an ancestor the project and RBS do not declare. It never
  adds a finding. The cases that used to read as written at the top level (a def in a block, a second def) now floor too.

For a hand-off inside a top-level def, whose `self` is any object that calls the def, read the top-level callee and also
union the project's same-named instance defs (`named_instance_callees`, as for an untyped local receiver in #2607).

## Decision

The third option and the union. A def in a block is a possible definer in the discovery tables (ADR-119), so it floors:
a spec helper passed a literal local no longer keeps the literal even when it only reads it. A call directly in a
top-level def's body, or in a block whose `self` is unmodelled, still resolves at the top level without the union.

## To undo

Make `StatementEvaluator#top_level_callees` return `[[def_node, offset, nil]]` for a call outside a class and
`TOPLEVEL_OWNER` inside one, ignoring `ToplevelDefCensus` and `chain_may_answer?`. The hazard examples in
`spec/integration/callee_toplevel_floor_spec.rb` then fail.
