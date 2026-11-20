# The project-singleton rung moves whole, takes its site's fields as positionals, and needs no second entry

- **PR:** [#3372](https://github.com/rigortype/rigor/pull/3372)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S5 of ADR-116's WD12 amendment moves project-singleton inference, the `project_singleton` rung of the call ladder, out of `ExpressionTyper` into `CallLadder::ProjectSingleton`. A static census of the typer gives the rung's closure (the methods only the rung reaches) as 23 methods and 206 lines, with one typer constant, `SINGLETON_WILDCARD_SLOT`, and four callbacks, the four `CallLadder::PORT` already lists, once `degrade_if_overridable` is kept in the typer as the re-entry point the user-method rung also uses. Only the three ladder entries ask the rung. The amendment fixes the entry (`try_call(site, typer)`) and the move rule, and leaves the shape of the module's inside to the slice.

## Options and trade-offs

- **The entry.** The typer's `try_project_singleton_inference(receiver, call_node, arg_types, method_name: call_node.name, block_type: nil)` built a `kwargs` hash on every ask and handed it to its two tiers by keyword. A `try_call` that only wraps it as a private `infer`, the way `UserMethod.try_call` wraps its second entry, keeps that body verbatim and the hash with it, and adds a function no caller outside the rung needs. A `try_call` that reads the site's five fields and hands them to the two tiers as positionals, as `UserMethod.infer` takes them, is the base body with its parameters replaced, and drops the hash.
- **Second entries.** None is needed: no caller outside the rung asks part of it. The gate-like predicates (`hidden_hook_definer?` and the other withholding reads) are asked only inside it.
- **`dispatch_miss_result`.** After the move it no longer reads its `arg_types` and `block_type` parameters, which only the two moved asks read; RuboCop's `Lint/UnusedMethodArgument` flags both. Keeping them prefixed with `_` keeps a signature for nothing; dropping them changes one call.

## Decision

`try_call` reads the site and hands its fields to the two tiers as positionals; every other function keeps its base body, given `scope` (or `typer`, where it calls back) as a parameter. The module has no second entry. `dispatch_miss_result(site, node, receiver)` drops the two unused parameters. Each substitution is listed in the PR's body-identity table, and Prism identity holds for all 23 units.

The precedent is the amendment's rung module ("its entry is `try_call(site, typer)`", "a function that only reads the scope takes it as a parameter") and S6's `UserMethod.infer`, which turned the same keyword parameters into positionals. S6's own entry is still in this queue, so it is a sibling here, not a precedent.

## To undo

Give the module a private `infer` with the base's keyword parameters and its `kwargs` hash, and have `try_call` call it; give `dispatch_miss_result` its two parameters back. Moving the rung back into the typer is the revert of the slice's first commit, which S7's literal-`send` rung, asking `CallLadder::ProjectSingleton.try_call`, would follow.
