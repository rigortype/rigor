# Read a project method_missing as a definition of every callee name, super included, and ignore computed definer names

- **PR:** [#2263](https://github.com/rigortype/rigor/pull/2263)
- **Issue:** [#2184](https://github.com/rigortype/rigor/issues/2184)
- **Class:** open-choice
- **Precedent:** [#2183](https://github.com/rigortype/rigor/pull/2183)
- **Decided:** 2026-10-21

## Background

#2184 asks `call.unresolved-toplevel` to decline in a block whose callee is provided by `define_singleton_method`, `method_missing`, or a `def` inside a block. The issue does not say how far a `method_missing` reaches, whether a `super` inside one counts as handing the block on, or what a `define_method` with a computed name means.

## Options and trade-offs

- **method_missing scope.** Ruby reaches `method_missing` only for a name the receiver lacks, but the rule reads callees by name and never resolves the receiver. Reading it for every name (taken) silences the rule in every top-level block of a project whose `method_missing` may hand its block on. Reading it only for names no project file defines would still report a block whose receiver lacks a method another class defines.
- **super in method_missing.** A bare `super` passes the block on implicitly. #2183 counts it as a hand-off for every callee. Treating it as plain inside `method_missing` would keep the rule useful in projects whose `method_missing` ends in `super`, which is common, but a gem's `method_missing` above it is not read. Counting it (taken) is the #2183 reading.
- **Computed definer names.** `define_method(name) { … }` names no method Rigor can read. Counting it would silence every block in most real projects; ignoring it (taken) matches how `discovered_methods` already treats a computed `define_method`.

## Decision

The conservative reading in each case: decline where Rigor cannot prove the block runs under `main`, which only loses a report. The exception is computed names, where the conservative reading would silence the rule wholesale; that gap predates this change. The herb corpus moved by no row.

## To undo

`RebindingBlockCallees#callee_may_rebind?` ORs in the `:method_missing` answer; drop it, or ask it only for names `project_may_rebind?` finds no definition for. `ScopeIndexer#record_definer_name_row` skips computed names; record a wildcard row there to count them.
