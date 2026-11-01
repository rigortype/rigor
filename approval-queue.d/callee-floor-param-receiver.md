# An untyped receiver's hand-off inside a callee unions the same-named user instance defs

- **PR:** [#2607](https://github.com/rigortype/rigor/pull/2607)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** [#2570](https://github.com/rigortype/rigor/pull/2570)
- **Decided:** 2026-11-02

## Background

The callee mutation floor follows `Help.c(p, o)` and `Helper.new.c(p, o)` inside a callee, because the receiver
types from the def alone. A hand-off on a parameter (`h.c(p, o)`) types from the caller, and the graph node key
(def, owner, name) must stay caller-independent. The issue left open what such a receiver resolves to.

## Options and trade-offs

- Contribute nothing (the status quo): the literal keeps its facts and a callee that writes it still reports a
  false `flow.always-truthy-condition` on correct code.
- Carry the caller's receiver type in the node key: exact, but the memoised graph facts would depend on the
  caller and the key grows with every receiver type.
- Union every user instance def of the called name, each under its own class: an over-approximation that costs
  a lost true positive when an unrelated same-named def writes, and favours flooring (ADR-5).

## Decision

The union, as #2570 unions candidate spellings where the exact owner is unknown. A name with no user def
contributes nothing. A local whose every write in the def (lambdas, `instance_exec` and `define_method` blocks
included) is a constant or `Const.new`, and that is not extended, given a singleton def or exposed to `binding`
or `eval`, is typed inside the callee instead.

A def reached through the name is walked under its own class only when no project class names that class as its
superclass; a def on a module, or on a class with a subclass, is floor-all, because the real receiver may be an
includer or a subclass whose overrides the walk would not see (ADR-127 WD4, as for an inherited def).
Every owner is floor-all while the project holds a subclass relation the superclass table does not spell
(`Class.new(Parent)`, an unreadable superclass expression, a superclass that is a constant alias): the check is
project-wide, so one such class floors all named hand-offs.

A name with more than eight defs floors the handed parameter outright instead of fanning out. ADR-127 rejects
out-degree and depth caps on the walk. This cap is acceptable because it floors rather than cuts, so it is
conservative, and it is a function of the name key, not of the walk: the answer for a node never depends on what
else was walked.

## To undo

Make `StatementEvaluator#local_receiver_callees` return no callees when `typed_local_forms` is nil. The
parameter and untyped-local examples in `spec/integration/callee_param_receiver_floor_spec.rb` then fail.
