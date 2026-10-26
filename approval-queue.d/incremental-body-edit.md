# Add three reasoned producers.yml rows for the EditReplay statement-drop helpers, and widen the file's computes: line

- **PR:** [#2387](https://github.com/rigortype/rigor/pull/2387)
- **Issue:** [#2277](https://github.com/rigortype/rigor/issues/2277)
- **Class:** gate-row
- **Precedent:** [#2272](https://github.com/rigortype/rigor/pull/2272)
- **Decided:** 2026-10-26

## Background

#2277 adds a body-statement-drop edit to `Analysis::EditReplay`. The new helpers name `Prism::ClassNode` / `Prism::ModuleNode` and the visibility-call spellings, so `spec/rigor/declaration_facts/producers_spec.rb` stopped on them and asked for a reasoned row each.

## Options and trade-offs

- Restructure the code to hide the node classes and spellings from the gate. That bends the code to the gate and gains nothing, since the helpers are text-only.
- Add a reasoned row per helper, as the file already does for `EditReplay#declarations` and `#header_of`.

## Decision

The second option. The rows are `Rigor::Analysis::EditReplay` (the visibility-call constant), `#drop_candidates` and `#visibility_call?`, plus the `computes:` line of the file widened to mention #2277. Each says the helper picks source text for a verify-gate edit and derives no declaration context. #2272 recorded the two rows of the same kind for the skeleton builder.

## To undo

Delete the three new rows and restore the `computes:` line in `spec/rigor/declaration_facts/producers.yml`, then remove the helpers (or rewrite them so the gate no longer sees them).
