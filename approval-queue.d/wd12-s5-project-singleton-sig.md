# Nineteen of the project-singleton rung's functions are declared, twelve of them by their parameters only

- **PR:** [#3372](https://github.com/rigortype/rigor/pull/3372)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S5 moves project-singleton inference into `CallLadder::ProjectSingleton`, 23 module functions. In the typer they were methods of a declared class: `scope` read as the declared `-> Scope`, and their calls back into the typer were typed. As module functions their `scope` and `typer` are parameters, which read `Dynamic` unless `sig/` declares them. The amendment has `sig/` declare `typer` as `ExpressionTyper` and declare each `try_call`.

With every parameter declared, `rigor sig-gen --print --include-private` renders a return for seven functions (`try_call`, its two tiers, `compute_singleton_def_with_owner`, `foreign_definer_behind_copy?`, `hidden_hook_definer?`, `dynamic_singleton_definer_ahead?`) and skips sixteen as `sig.skipped.untyped-return`: each answers what an undeclared `Scope::ResolutionChain`, `DiscoveryIndex` predicate or `MemoAudit.check` gives, or what another such function answers.

## Options and trade-offs

Measured with the self-typing ratchet (`rigor coverage --config .rigor.gates.yml --format json lib`), each arm a copy of the tree:

- **Declare the seven sig-gen renders, and nothing else.** No `parameter_only` row. The sixteen others read their `scope` as `Dynamic`: precision moves +0.008 pt against the base and the `Dynamic` call share +0.009 pt, worse.
- **Declare all 23, sixteen by their parameters only.** 98 more precise expressions and 19 fewer `Dynamic` call sites in `project_singleton.rb` than the first arm. Sixteen `parameter_only` rows.
- **Declare 19: the seven, and the twelve of the sixteen that take a `Scope` or an `ExpressionTyper`.** The same figures as all 23, to the expression: the four others (`unordered_prepend_definer?`, `answered_ahead?`, `level_start_of`, `own_singleton_index`) take only `untyped` parameters, so a declaration types nothing inside them. Twelve `parameter_only` rows.

## Decision

Nineteen declarations: seven with the return sig-gen generates (earned), and twelve that declare their parameters with an `untyped` return. Every parameter type was checked against its call sites: `class_name` is the `String` of a `Type::Singleton` receiver, `method_name` the site's `Symbol`, `receiver` and `block_type` the site's declared fields, and `found`, `owner`, `chain`, `entry` and `node` stay `untyped`. `SIG_PROVENANCE_PARAMETER_ONLY` for `sig/rigor/inference.rbs` goes from 16 to 28 unmarked, and `SIG_PARAMETER_SHAPE_COMPARED_FLOOR` from 1088 to 1109 with S7's two; `SIG_PROVENANCE_RESIDUE` does not move.

The precedent is the amendment's requirement that `sig/` type what a rung calls on its typer, with the provenance gate's rule that a `parameter_only` row "makes no claim the gate cannot check" (`docs/agents/type-authoring.md`). S6 made the same choice for two functions of `CallLadder::UserMethod`, but its entry is still in this queue, so it is a sibling here.

The class is `open-choice`, not `gate-row`: no residue pin moves, and a `parameter_only` row is a watched class, not an allow-list row.

## To undo

Delete the twelve `-> untyped` rows of `module ProjectSingleton` in `sig/rigor/inference.rbs` and set the pin back to 16: their `scope` reads `Dynamic` again (the first arm above). Lower the floor by twelve. A later change that makes `Scope::ResolutionChain` or the `DiscoveryIndex` predicates declared would let sig-gen render these returns, and each row would leave `parameter_only` for `generated`.
