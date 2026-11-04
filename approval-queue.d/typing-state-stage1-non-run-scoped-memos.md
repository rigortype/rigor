# Process-wide pure memos become per-thread, non-run-scoped Memo slots

- **PR:** [#2816](https://github.com/rigortype/rigor/pull/2816)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [ADR-129](../docs/adr/129-type-of-result-memo.md)
- **Decided:** 2026-11-05

## Background

#2809 and #2811 converted only run-scoped state. This PR meets four stores that are not run-scoped: `Scope::ResolutionChain`'s three interning tables (module ivars filled with `||=`, shared by every thread) and the declared-names set memoised in an ivar on a `Prism::Source` (`scope_index_declared_names`). Each value is a pure function of its key: a frozen Array of frozen Strings built from a name and frozen constants, or a frozen Set built from the source's text.

## Options and trade-offs

- Keep them as module or source storage with G3 allow-list rows. The next PR adds the WD5 line for process-wide memos pure in their key, but that option names `RbsLoader.default`, `Acceptance`'s `@class_name_parts` and `RbsTypeTranslator`'s #775 memos, where per-thread storage would cost or change something. These four need no such row.
- Per-thread Memos, run-scoped. Behaviour-identical, but the entries are rebuilt every run for no gain.
- Per-thread Memos that are not run-scoped (chosen). Each thread rebuilds a few hundred small frozen Arrays once; the declared-names entry keeps the source's lifetime through a `weak_key_map` keyed on the `Prism::Source`.

## Decision

Per-thread, non-run-scoped Memos. The only change in answers is Ractor mode: a non-main Ractor could not read the module ivars before, and now has its own State. The Ractor pool backend is off by default and cannot analyse under rbs 4.x (#414), so no Ractor-mode answer changes in practice.

## To undo

Convert them back to module storage (the ivar on the source) and add option-A G3 rows for them.
