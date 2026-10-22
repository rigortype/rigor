# The statement form of a memoizing index `||=` yields the rvalue's class, with literal precision erased

- **PR:** [#2288](https://github.com/rigortype/rigor/pull/2288)
- **Issue:** [#1155](https://github.com/rigortype/rigor/issues/1155)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-22

## Background

`x = (tbl[k] ||= {})` bound `x` to `Dynamic[top] | {}` in the statement handler, while the value-position typer read the memoizing `||=` as the rvalue. The internal spec had explicitly kept `Dynamic[top] | v` for the statement handler. Aligning the two fixes #1155 but reverses that earlier design, and the first attempt (yield the literal rvalue) made later reads treat the slot as freshly created: `entry[:name].upcase` reported a call on nil (review of PR #2288).

## Options and trade-offs

- Keep the statement handler's union: no false positives, but a nested memo table's reader stays `untyped` and sig-gen skips it (#1155 stays open).
- Yield the literal rvalue: fixes sig-gen but spreads error-level false positives into ordinary memo code, since the slot may hold what another call stored.
- Yield the rvalue's class with literal precision erased (taken): a `new(...)` / nominal rvalue binds as itself, `{}` / `[]` become `Hash[untyped, untyped]` / `Array[untyped]`, and any other rvalue (Constant, union) keeps `Dynamic | v`. This introduces new certainty only about the class of a fresh construction or container, and none about its contents.

## Decision

The third option, per the coordinator's ruling in the PR review. The widening and the narrowing record keep the stored union. The spec paragraph in `inference-engine.md` now records the reversal and the erase rule.

## To undo

Revert `StatementEvaluator#memo_bound_value` to yield the stored type, and restore the three `sig/rigor/type.rbs` markers and the `1155` allow-list row.
