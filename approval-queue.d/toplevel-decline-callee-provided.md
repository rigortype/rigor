# Read a project method_missing as a definition of any callee its receiver may lack, super included, and ignore computed definer names

- **PR:** [#2263](https://github.com/rigortype/rigor/pull/2263)
- **Issue:** [#2184](https://github.com/rigortype/rigor/issues/2184)
- **Class:** open-choice
- **Precedent:** [#2183](https://github.com/rigortype/rigor/pull/2183)
- **Decided:** 2026-10-21

## Background

#2184 asks `call.unresolved-toplevel` to decline in a block whose callee is provided by `define_singleton_method`, `method_missing`, or a `def` inside a block. The issue does not say how far a `method_missing` reaches, whether a `super` inside one counts as handing the block on, or what a `define_method` with a computed name means.

## Options and trade-offs

- **method_missing scope.** Ruby reaches `method_missing` only for a name the receiver lacks. Reading it for every name silenced the rule in every top-level block of a project whose `method_missing` may hand its block on, `[1].each { }` included (the round-1 review of #2263). The rule now asks it only when the receiver's type does not name a class (on every member of a union) whose RBS or project method table has the callee, a receiverless top-level call asking `Object` (taken). An untyped receiver still consults it.
- **super in method_missing.** A bare `super` passes the block on implicitly. #2183 counts it as a hand-off for every callee. Treating it as plain inside `method_missing` would keep the rule useful in projects whose `method_missing` ends in `super`, which is common, but a gem's `method_missing` above it is not read. Counting it (taken) is the #2183 reading.
- **Computed definer names.** `define_method(name) { … }` names no method Rigor can read. Counting it would silence every block in most real projects; ignoring it (taken) matches how `discovered_methods` already treats a computed `define_method`.

## Decision

The conservative reading in each case: decline where Rigor cannot prove the block runs under `main`, which only loses a report. The exception is computed names, where the conservative reading would silence the rule wholesale; that gap predates this change.

Evidence: herb moved by no row. tdiary-core (`tool/engine_diag_diff.rb --rule call.unresolved-toplevel`) goes from 177 rows to 161: 16 removed, 0 added, down from 19 removed before the receiver check. Every removed row (`h`, `disp_referer`, `load_plugin` in `lib/tdiary/plugin/00default.rb`, `05referer.rb`, `50sp.rb`, `60sf.rb`) sits in a block whose receiver Rigor cannot type (`@years[...].sort.each`, `diary.each_referer`, `paths.collect { }.sort.each`, `@sp_path.each`), and `TDiary::Plugin#method_missing` ends in `super if @debug`. Ruby runs those files through `TDiary::Plugin#load_plugin`'s `instance_eval`, where all three names are defined, so each removed row was a false positive.

## To undo

`RebindingBlockCallees#callee_may_rebind?` asks the `:method_missing` answer after `resolves_on_receiver?`; drop that line to stop reading `method_missing`, or narrow `resolves_on_receiver?` to change when it is reached. `ScopeIndexer#record_definer_name_row` skips computed names; record a wildcard row there to count them.
