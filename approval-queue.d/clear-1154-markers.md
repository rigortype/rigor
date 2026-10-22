# Re-point the 52 remaining #1154 markers to the issues that name their causes, and retire #1154 from the allow-list

- **PR:** [#2324](https://github.com/rigortype/rigor/pull/2324)
- **Issue:** [#1154](https://github.com/rigortype/rigor/issues/1154)
- **Class:** gate-row
- **Precedent:** [#2316](https://github.com/rigortype/rigor/pull/2316)
- **Decided:** 2026-10-23

## Background

#2199 made `rigor sig-gen` type `@x = x` from the declared type of the parameter `x`, and #2311 and #2316 completed the hand-written `initialize` declarations whose omitted keywords kept that credit from applying. 52 `# sig-gen gap: #1154` markers were left in `sig/`. The brief was to add whatever parameters the audit showed missing, and to clear or re-point the rest, so that #1154 could close. Moving a marker, extending `spec/rigor/sig_gen/gap_issues.yml` and removing a row from it are gate-row decisions.

## Options and trade-offs

- **Audit every row with `SigProvenanceAuditor`, add missing parameters where that is the cause** (taken, but it found no such row). Every one of the 52 rows is `unrenderable` (`sig.skipped.untyped-return`) except two `declared_divergent` rows, and none of them is a bare `@x = x` over a parameter that `sig/` omits or declares `untyped`. The cause is never the #2316 one. Nothing could be added without inventing a type, so no residue pin changed.
- **Force a type, or keep the markers on #1154.** Rejected. A parameter type copied from a reader would not make the generator produce the row, because the credit covers only a bare read; and a marker that names an issue whose mechanism does not apply points a future reader at the wrong engine work (ADR-107 gate G3).
- **Re-point each marker to the issue whose fix would generate its row** (taken), filing one issue per cause that had none (the one-issue-per-cause ruling in the header of `gap_issues.yml`).

## Decision

51 markers are re-pointed and one is removed; no row moved the wrong way. Two non-comment signature lines changed, both verified against the code: `RbsLoader#global_type: (String | Symbol name) -> Type::t?` is new (its body is `global_declarations[name.to_sym]&.first`, a translated type or nil, and `Bot` entries are never stored), which turns `Environment#global_for_name` into parameter intent and removes its marker; and `Manifest#initialize` types `?template_globs: Array[String]`, which `validate_array_of!` already enforces. `RbsLoader#global_type` is itself unrenderable (it reads the loader's `@state` memo hash), so it carries a `# sig-gen gap: #160` marker; the `sig/rigor/environment.rbs` residue pin is unchanged. A `rigor check --no-cache` of the eleven `lib/` files that use these names gives identical output at base and head.

| Cause | Issue | Rows |
|---|---|---|
| A reader whose constructor (or helper) parameter is declared `untyped` or undeclared; the `untyped` looks deliberate (coercion-facing), so neither of the fixes below generates the row | [#2325](https://github.com/rigortype/rigor/issues/2325) (new) | 22: `EffectEntryPoints` (3), `EffectEdge` (4), `EffectAttribution` (9), `EffectAncestry` (3), `Effects::Registry` (`labels`, `descriptions`), `IoBoundary#refusal_summary` |
| The ivar is assigned from an expression derived from a declared parameter, not a bare read; `Manifest` also has the `assign_*` helper co-cause | [#2321](https://github.com/rigortype/rigor/issues/2321) (new) | 17: `AdditionalInitializer` (3), `ProtocolContract` (4), `Baseline#buckets`, `Manifest` (9) |
| The ivar is stored from a private helper's result, with declared constructor parameters | [#2312](https://github.com/rigortype/rigor/issues/2312) (existing, commented twice) | 8: `ProtocolContract#param_types`, `Summary` (3), `FileCollection` (4) |
| `filter_map` answers `Array[untyped]` with typed inputs | [#2322](https://github.com/rigortype/rigor/issues/2322) (new) | 1: `Scope#declaration_sourced_global_copies` |
| `Frame` cannot be typed by sig-gen (a skeleton could help `match_frame`; the two predicates need engine work) | [#2323](https://github.com/rigortype/rigor/issues/2323) (new) | 3: `Scope#match_frame`, `#match_rebinding_closure?`, `#last_line_closure?` |
| `RbsLoader#global_type` reads a memo hash (new row from the sig above) | [#160](https://github.com/rigortype/rigor/issues/160) | 1 added, replacing the removed `global_for_name` marker |

The 22 rows on #2325 were checked for an unintended `untyped`: each constructor `to_s`-, `to_sym`- or `Array()`-normalizes its input, so the author-only intent (`_ToS`, `Symbol | String`) is not invented here. #1154's row is removed from `gap_issues.yml` and 2321, 2322, 2323 and 2325 are added, since no marker cites #1154 any more. No reader type was copied or corrected, so the `Set[untyped]` and echo caveats from #2316 do not arise.

## To undo

Restore `#1154` in the marker lines, put the 1154 row back in `spec/rigor/sig_gen/gap_issues.yml` and drop the four new rows; delete `RbsLoader#global_type` and restore `?template_globs: untyped` in `sig/`. The comments' reworded reasons can stay.
