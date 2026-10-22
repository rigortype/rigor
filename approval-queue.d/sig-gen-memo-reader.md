# The statement form of a memoizing index `||=` yields the rvalue but records the stored union

- **PR:** [#2288](https://github.com/rigortype/rigor/pull/2288)
- **Issue:** [#1155](https://github.com/rigortype/rigor/issues/1155)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-22

## Background

`x = (tbl[k] ||= {})` bound `x` to `Dynamic[top] | {}` while the value-position typer already read the memoizing `||=` as the rvalue. Aligning the statement handler's yielded value fixes #1155, but the handler also records the result as an indexed narrowing and feeds the `[]=` widening, and the issue did not say whether those should take the rvalue too.

## Options and trade-offs

- Yield the memo reading and keep the stored union for the widening and narrowing record: a later plain read of the slot is unchanged, so no new certainty is introduced beyond the binding the value-position typer already gave.
- Yield and record the rvalue everywhere: simpler, but a later `tbl[k]` would read the rvalue alone for a slot the analyzer has no evidence about, a wider change than the issue needs.

## Decision

The first option: the conservative one, as it changes only the yielded value.

## To undo

Revert the one-line change in `StatementEvaluator#eval_index_or_write` and restore the three `sig/rigor/type.rbs` markers and the `1155` allow-list row.
