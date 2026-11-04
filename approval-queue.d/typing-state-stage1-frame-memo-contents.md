# A Frame's installed value may hold extensional caches its owner fills in place, and those are Memos that take no touch

- **PR:** [#2809](https://github.com/rigortype/rigor/pull/2809)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [ADR-129](../docs/adr/129-type-of-result-memo.md)
- **Decided:** 2026-11-04

## Background

ADR-129 WD1 says a Frame value is frozen while installed. `DefNodeResolver.with_run` installs a run memo: a frozen hash of four tables (`nodes`, `indexes`, `nestings`, `refinement_queries`) that the resolver fills in place as it resolves handles. Each entry is fixed once written, so a read answers the same whether or not an earlier call filled it, but the tables are mutated containers inside a frozen Frame value. The key-presence walk already does the same with its per-file scans.

## Options and trade-offs

- Declare the frame `contents: :resource` and touch before every fill. That is sound but refuses every capture around any handle resolution, though the tables are extensional.
- Split the four tables into Memo slots beside a storage-less Frame. That needs a per-run key and doubles the declarations, and the tables are only meaningful together with the install that scopes them.
- Read the rule as freezing the frame's own value (the install) while letting extensional caches inside it be Memos by kind. One declaration, no touch, and a stage-2 reader (G4) treats the tables as Memos.

## Decision

The third reading. A Frame's installed value may hold extensional caches its owner fills in place; they are Memos by kind and take no touch. The def-node resolver's run memo and the key-presence walk's scans are the two cases. The text is in ADR-129 WD1's Frame bullet, `docs/internal-spec/inference-engine.md` and the Frame bullet of `lib/rigor/typing_state.rb`. The precedent is ADR-129's own split of the walk into a Frame and a Resource, taken one step further for caches that need no touch.

## To undo

Declaring the resolver's frame `contents: :resource` and touching in `resolve`, `record_nesting` and `refinement_query` restores the strict reading, with the WD1 clause removed; nothing else depends on it until stage 2 opens a capture.
