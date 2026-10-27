# An inline instance variable whose type differs from sig/ stands down at :info, and is never ranked

- **PR:** [#2467](https://github.com/rigortype/rigor/pull/2467)
- **Issue:** [#2440](https://github.com/rigortype/rigor/issues/2440)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-28

## Background

Some projects commit `rbs-inline --output`'s RBS under `sig/`. The auto-wired `rigor-rbs-inline` reader then declares every `# @rbs @x: T` a second time. rbs 4.2 rejects two declarations of one instance variable even when their types match, so the class failed to build. #2440 adds instance variables to the inline-vs-`sig/` consistency rule (#1075). That left two questions open. What happens when the two types differ? Should auto-wiring be skipped when `sig/generated/` exists?

## Options and trade-offs

- **Rank variables like methods.** The more precise side would bind, and a proven contradiction would be an `rbs.contradicting-signature` error. A variable has no call that would make one side "more precise" in a useful way. An error on a stale generated file would also turn a green build red.
- **`sig/` binds on any difference and the inline side is reported at `:info`.** This never raises an error on correct code (ADR-5). The committed `.rbs` is what the project's other tools read.
- **Skip auto-wiring when `sig/generated/` exists.** This would drop the inline refinements that #1075 merges. It is a larger policy change.

## Decision

The coordinator ruled for the second option. Equal types merge silently. Any other pair keeps `sig/` and reports one `source-rbs-annotation-not-honoured` row at `:info`, never `rbs.contradicting-signature`. Auto-wiring is not skipped. Unlike a method pair, a consistent but narrower inline variable type does not bind. The ruling says `sig/` wins whenever the types differ.

## To undo

Change `Comparator#compare_variables` to rank the two types the way `compare_slot` does. A ranking that lets the inline side bind would also need `inline_binds?` to accept variable keys. The row wording is in `Environment#record_variable_undecided`.
