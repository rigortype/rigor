# Twelve functions of the overriding-def and top-level-def rungs are declared, two of them by their parameters only

- **PR:** [#3374](https://github.com/rigortype/rigor/pull/3374)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S8 moves the overriding-def and top-level-def rungs into `CallLadder::OverridingDef` (3 functions) and
`CallLadder::TopLevelDef` (9). As typer methods their `scope` read as the declared `-> Scope` and their calls back
into the typer were typed; as module functions their `scope` and `typer` are parameters, which read `Dynamic` unless
`sig/` declares them. The amendment has `sig/` declare `typer` as `ExpressionTyper` and declare each `try_call`.

With every parameter declared, `rigor sig-gen --print --include-private` renders a return for ten of the twelve
and skips two as `sig.skipped.untyped-return`: `singleton_self_answers?`, which answers an undeclared
`Scope::ResolutionChain#unnamed_mixin?`, and `self_type_answers?`, which answers what that one answers. The typer
method the slice makes a re-entry point, `resolve_user_def_through_ancestors`, has no declaration.

## Options and trade-offs

Measured with the self-typing ratchet (`rigor coverage --config .rigor.gates.yml --format json lib`), each arm a copy
of the slice's tree:

- **Declare the ten sig-gen renders, and leave the two undeclared.** No `parameter_only` row. `top_level_def.rb` reads
  27 fewer precise expressions and 8 more `Dynamic` call sites than with them.
- **Declare all twelve, the two by their parameters only** (`-> untyped`). Two `parameter_only` rows, each taking an
  `ExpressionTyper` or a `Scope`.
- **Also declare `resolve_user_def_through_ancestors`** on the typer, by its parameters. 2 more precise expressions,
  in `expression_typer.rb`, and no call site changes: a row for that little.

## Decision

All twelve are declared: ten with the return sig-gen generates (earned) and two by their parameters with an
`untyped` return. Every parameter type was checked against the function's call sites: `site` is a
`MethodDispatcher::CallContext`, `method_name` the site's `Symbol`, `receiver` and `block_type` the site's declared
`Type::t?`, `arg_types` its `Array[Type::t]`, `class_name` the `String` of the call's `self` type (nil-checked where
it may be nil), and `def_node`, `call_node`, `node` and `definition` stay `untyped`. `resolve_user_def_through_ancestors`
stays undeclared. `SIG_PROVENANCE_PARAMETER_ONLY` for `sig/rigor/inference.rbs` goes from 28 to 30 unmarked and
`SIG_PARAMETER_SHAPE_COMPARED_FLOOR` from 1109 to 1121; `SIG_PROVENANCE_RESIDUE` does not move.

The precedent is the amendment's requirement that `sig/` type what a rung calls on its typer, with the provenance
gate's rule that a `parameter_only` row "makes no claim the gate cannot check" (`docs/agents/type-authoring.md`). S5
and S6 made the same choice for their rung modules (`wd12-s5-project-singleton-sig.md`, `wd12-s6-user-method-sig.md`),
but their entries are still in this queue, so they are siblings here.

The class is `open-choice`, not `gate-row`: no residue pin moves, and a `parameter_only` row is a watched class, not
an allow-list row.

## To undo

Delete the two `-> untyped` rows of `module TopLevelDef` in `sig/rigor/inference.rbs` and set the pin back to 28:
their `typer` and `scope` read `Dynamic` again (the first arm above). Lower the floor by the declarations removed. A
later change that declares `Scope::ResolutionChain#unnamed_mixin?` would let sig-gen render both returns, and each
row would leave `parameter_only` for `generated`.
