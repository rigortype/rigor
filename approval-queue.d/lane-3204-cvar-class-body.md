# Add producers.yml rows for the class-body cvar census and the class_variable_set census entry

- **PR:** [#3218](https://github.com/rigortype/rigor/pull/3218)
- **Issue:** [#3204](https://github.com/rigortype/rigor/issues/3204)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-14

## Background

#3204 asks for class-body and module-body cvar writes to enter the class-cvar census through the seam a `def` body's write uses. The fix adds `ScopeIndexer#collect_body_cvar_writes`, the class-body twin of the grandfathered `collect_def_cvar_writes`, and `ScopeIndexer#record_reflective_cvar_write`, which records a `class_variable_set(:@@x, v)` on an implicit or `self` receiver. After review round 1, both record writes that only join an entry a `def` body's write creates (the coordinator's join-only rule). `spec/rigor/declaration_facts/producers_spec.rb` counts both as declaration producers, so each needs a row.

## Options and trade-offs

- Add a row for each, with a reason. That is accurate and keeps each method to one job.
- Fold both into the grandfathered `collect_def_cvar_writes` / `gather_cvar_writes`. That avoids rows but gives one method two `self` types to pick from and hides a new reading behind a `grandfathered` label.
- Route the class-body gather through `DeclarationWalk::Context` alone. The collector already takes the body context's prefix and scope; the method still builds the census scope from them, as its `def` twin does.

## Decision

The first option. Each row says what the method records, that its writes only join, and which owner and `self` it uses: the prefix and scope come from the walk's body context (or the legacy walker's equivalent), as for `collect_def_cvar_writes`, and `collect_body_cvar_writes` types the rvalue with the class as `self`, the `self` of a class body. #2086 recorded rows in the same file for the same kind of reason. The join helper reuses the grandfathered `record_cvar_write` name, so no third row was added.

## To undo

Delete the two rows and the two methods. That removes class-body writes and `class_variable_set` from the census, and the `flow.always-truthy-condition` false positive of #3204 returns. The `join_only:` keyword on `record_cvar_write` and `finished_cvar_census` can then go too; the union of the rescue floor stays.
