# sig-gen's project seed lands with its provenance moves and a +39 % run cost on lib/

- **PR:** [#2408](https://github.com/rigortype/rigor/pull/2408)
- **Issue:** [#2300](https://github.com/rigortype/rigor/issues/2300)
- **Class:** gate-row
- **Precedent:** [ADR-107](../docs/adr/107-checked-types-and-typeless-comments.md)
- **Decided:** 2026-10-26

## Background

Seeding `rigor sig-gen`'s per-file indexing with the project's discovery tables lets it read helpers, ancestors
and constants from other files, as `rigor check` does. That changed what sig-gen proposes for some rows `sig/`
already declares, so the ADR-107 provenance gate stopped. Two residue pins went up, three `tighter_return` rows
appeared, two rows were proposed `Symbol` for a `Symbol | nil` declaration, and three rows lost their reading. The
seeded run also costs more than the maintainer's ~+30 % target on `lib/`. The maintainer ruled on each point
through the coordinator.

## Options and trade-offs

- Tighten each declaration to sig-gen's proposal, mark it, or keep it as it is. Tightening is correct only when
  every return site agrees and the returned class has RBS. Marking keeps the gate honest without narrowing.
- For the three `untyped` rows that return undeclared classes, declare those classes in this stack (wider scope)
  or keep `untyped` until they are declared.
- On cost, accept the measured overhead or hold the seed for more tuning. The profile on #2300 found no
  answer-preserving lever left beyond the ones in this stack.

## Decision

- Tightened, after checking every return site in `lib/`: `DiffCommand#run` to `0 | 1 | 64`,
  `ExplainCommand#run` to `0 | 64` (each returns 0, 1 or `CLI::EXIT_USAGE`), and
  `IoBoundary#list_directory_kinds` to `Hash[String, Symbol]` (`GlobEntry.lstat_kind` returns Symbols only).
- `Scope#optimistic_local` and `#optimistic_ivar` keep `Symbol | nil` under `# sig-gen gap: #2403`. The
  `Hash#[]` miss in `OptimisticOrigin.bound_cause` does not survive the call, so sig-gen's `Symbol` is wrong at
  run time. #2403 is added to `spec/rigor/sig_gen/gap_issues.yml`.
- `CheckRules#node_collector_driver`, `Plugin::Base#plugin_entry` and `Plugin::IoBoundary#cache_descriptor` keep
  `untyped` under `# authored:` markers. Each returns a class with no RBS declaration yet (#2404). This follows
  `io_boundary.rbs`'s existing "no RBS yet -> untyped" note.
- Accepted losses, each now skipped (`untyped-return`) and none emitting a wrong contract:
  `Type::HashShape#erase_to_rbs`, `Type::Intersection#describe` and `Type::Refined#describe`.
- Eight residue pins move down (566 to 554), and none moves up.
- Cost accepted. On `lib/` the run is +39 % wall (31.4 to 43.7 s) and +36 % RSS (540 to 733 MB). mail is +27 % and
  kramdown about 0. These are ABBA ×4 medians, and CI's "Engine wall A/B" gives the final wall verdict.

## To undo

- Each tightened declaration reverts to its old line in `sig/`. The residue pins of `cli/diff_command.rbs` and
  `cli/explain_command.rbs` (1 each) then rise unless the seed is reverted too.
- Removing a `# sig-gen gap: #2403` or `# authored:` marker turns its row back into residue or an unmarked
  `tighter_return`. Closing #2403 means removing its `gap_issues.yml` row and the two markers. Declaring the
  #2404 classes means replacing the three `untyped` returns and dropping their markers.
- Reverting the seed (`SigGen::Generator#file_base_scope`) restores the per-file reading and its cost. The
  pins that moved down would then rise back.
