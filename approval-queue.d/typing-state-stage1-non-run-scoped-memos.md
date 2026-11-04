# Process-wide pure memos become per-thread, non-run-scoped Memo slots

- **PR:** [#2816](https://github.com/rigortype/rigor/pull/2816)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-05

## Background

Every Memo slot declared before this PR was run-scoped, and no earlier stage-1 conversion moved a module ivar or an object ivar. This PR meets four stores of that kind. Three are `Scope::ResolutionChain`'s interning tables, module ivars filled with `||=` and shared by every thread. The fourth is the declared-names set that `ScopeIndexer#eval_file_declared_names` memoised in an ivar on a `Prism::Source` (`scope_index_declared_names`). Each value is a pure function of its key: a frozen Array of frozen Strings built from a name and frozen constants, or a frozen Set built from the source's text. ADR-129 WD1's per-thread `State` covers moving them into TypingState. It says nothing about whether a pure memo should be run-scoped.

## Options and trade-offs

- Keep them as module or source storage, with G3 allow-list rows. On 2026-11-05 the user approved a WD5 shape for process-wide memos pure in their key (option A; its sink half is #2814). That approval names `RbsLoader.default`, `Acceptance`'s `@class_name_parts` and `RbsTypeTranslator`'s #775 memos, where per-thread storage would cost or change something. These four are not named.
- Per-thread Memos, run-scoped. Behaviour-identical, but every run rebuilds the entries for no gain.
- Per-thread Memos that are not run-scoped (chosen). Each thread rebuilds a few hundred small frozen Arrays once. The declared-names entry re-runs `Prism.parse(source.source)` once per thread for each source that thread reaches, and the language server runs each save round on its own thread. Its `weak_key_map` keyed on the `Prism::Source` keeps the source's lifetime.

## Decision

Per-thread, non-run-scoped Memos. ADR-129 fits the per-thread half; the not-run-scoped half is a new choice, which is why this entry sets a precedent. Answers change only in Ractor mode: a non-main Ractor could not read the module ivars before, and now has its own State. The Ractor pool backend is off by default and cannot analyse under rbs 4.x (#414), so in practice no Ractor-mode answer changes.

## To undo

Convert them back to module storage (the ivar on the source) and give them option-A G3 rows. Drop them from the three `kept` literals in `spec/rigor/typing_state_spec.rb` and remove the example "keeps the declared-names and interned-key memos out of the run release". Making them run-scoped instead means flipping `run_scoped:` and dropping the same `kept` entries and example.
