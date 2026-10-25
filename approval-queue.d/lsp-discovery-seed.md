# Move the seed-into-scope fold from cli/ to Protection::DiscoverySeed, swapping one admission-census row

- **PR:** [#2377](https://github.com/rigortype/rigor/pull/2377)
- **Issue:** [#2282](https://github.com/rigortype/rigor/issues/2282)
- **Class:** gate-row
- **Precedent:** [#2281](https://github.com/rigortype/rigor/pull/2281)
- **Decided:** 2026-10-26

## Background

#2282 makes the language server's hover, completion and signature help fold the project's discovery seed into their base scope. That fold copies the whole discovery index (`base.discovery.with(**seed)`), which `admission_census.yml` records per file under `whole_index`. The fold lived in `CLI::TypeOfProjectScope`, so the language server would have had to require a `cli/` file, or add a second recorded copier.

## Options and trade-offs

- Keep the helper in `cli/type_of_project_scope.rb` and require it from `ProjectContext`. The census is unchanged, but the language server depends on `cli/`.
- Copy the fold into `project_context.rb`. This adds a census row and a second copy of the same fold.
- Move the helper to `Protection::DiscoverySeed.seeded_scope`, which both callers already load. The census row moves with it.

## Decision

The third option. In `whole_index` the path `lib/rigor/cli/type_of_project_scope.rb` becomes `lib/rigor/protection/discovery_seed.rb`: same row count, same kind of copy, and the copy merely moves. `CLI::TypeOfProjectScope.build` delegates to the helper. The precedent is #2281, which recorded the `cli/type_of_project_scope.rb` row for this same fold.

## To undo

Revert the move: put `seeded` back in `CLI::TypeOfProjectScope`, have `ProjectContext` require it again, and the `whole_index` row returns to `lib/rigor/cli/type_of_project_scope.rb`.
