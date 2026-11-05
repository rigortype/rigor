# The Scope advisory readers' hand-written signatures cite a new sig-gen gap, #2840

- **PR:** [#2841](https://github.com/rigortype/rigor/pull/2841)
- **Issue:** [#2840](https://github.com/rigortype/rigor/issues/2840)
- **Class:** gate-row
- **Precedent:** [#2324](https://github.com/rigortype/rigor/pull/2324)
- **Decided:** 2026-11-05

## Background

The PR adds three public readers to `Scope` (`#dynamic_origin`, `#void_origin`, `#optimistic_origin`) so every advisory-table read is journaled. The public API drift spec requires each to have an RBS signature, and `rigor sig-gen --diff lib/rigor/scope.rb` emits none for them, so the ADR-107 provenance gate counted three hand-written rows.

## Options and trade-offs

- Mark each row `# sig-gen gap: #2840` and list #2840 in `spec/rigor/sig_gen/gap_issues.yml`: the residue count stays put and the gap is tracked.
- Raise the provenance residue pin by three: hides the cause behind a number.
- Fix sig-gen first: out of scope for an ADR-129 stage-2 PR.

## Decision

The marker and the gap row, as #2324 did when it re-pointed markers to the issues naming their causes.

## To undo

Remove the three markers and the `2840` row once sig-gen emits the readers (#2840's acceptance), or drop the readers if the advisory tables stop being journaled.
