# Two own-method readers join the ancestry-walker allow list because the detector reads MemoAudit's recompute block as a loop

- **PR:** [#2860](https://github.com/rigortype/rigor/pull/2860)
- **Issue:** [#2813](https://github.com/rigortype/rigor/issues/2813)
- **Class:** gate-row
- **Precedent:** [#2051](https://github.com/rigortype/rigor/pull/2051)
- **Decided:** 2026-11-05

## Background

ADR-129 stage 2 wires every Memo slot to `MemoAudit.check`, whose block recomputes the stored value on an audited hit. In `RefinedDispatch::OwnMethod#all_unknown_superclass_classes` and `#children_by_parent` that block calls a helper in the same file (`compute_unknown_superclass_classes`, `compute_children_by_parent`) that reads `discovered_superclasses`, and `spec/rigor/scope/ancestry_walker_detection_spec.rb`'s looped-helper-call rule counts such a call inside a block as an ancestry walker. Neither method walks an ancestor chain: each rebuilds a table-wide value (a filter over the unknown-superclass table, the inverted parent table) once per audited hit.

## Options and trade-offs

- List both methods in `ALLOWED_ANCESTRY_WALKERS`, each with its reason: the gate keeps working, and each row says why it may stay.
- Route the recompute through `send` or a helper the scan cannot see: dodges the gate rather than answering it.
- Leave the two memos unwired: keeps them on ADR-129's stage-2 ratchet, unaudited.

## Decision

List them, each with a reason naming the method, in the shape the list already holds for a table reader that walks no chain (`constructed_class.rb#project_name?`, #2051). This is not ADR-129's G3 allow list, so G3's ADR-line rule does not apply.

## To undo

Remove the two rows and restructure the recomputes so the scan does not read them as loops, or unwire the two memos.
