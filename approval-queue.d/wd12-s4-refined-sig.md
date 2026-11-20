# Eleven of the refined rung's twelve functions are declared, one by its parameters only

- **PR:** [#3377](https://github.com/rigortype/rigor/pull/3377)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S4 moves the refined rung into `CallLadder::Refined`, twelve module functions. As typer methods their `scope`
read as the declared `-> Scope` and their calls back into the typer were typed; as module functions their `scope` and
`typer` are parameters, which read `Dynamic` unless `sig/` declares them. The amendment lists S4 "only with a plan for
the self-typing ratchet", and the lane's brief asked for every scope and typer parameter to be declared, with a
`parameter_only` row where sig-gen cannot render a return, measured with and without.

With every parameter declared, `rigor sig-gen --print --include-private` renders a return for ten of the twelve. It
skips two as `sig.skipped.untyped-return`: `opaque_refinement_span?`, which answers the undeclared
`InEffectRefinements.opaque_in?`, and `refined_receiver_class_name`, which takes no scope or typer. The typer method the
slice makes a re-entry point, `call_result_type_for`, has no declaration, and sig-gen renders no return for it either.

## Options and trade-offs

Measured with the self-typing ratchet (`rigor coverage --config .rigor.gates.yml --format json lib`), each arm a copy of
the slice's tree, against the arm with all twelve declared (`refined.rb`: 497 expressions, 400 precise, 122 call
sites, 34 `Dynamic`):

- **Declare the ten sig-gen renders, and no `parameter_only` row.** 11 fewer precise expressions and 3 more `Dynamic`
  call sites in `refined.rb`.
- **Also declare `opaque_refinement_span?` by its parameters** (`-> untyped`). The `scope` it is given reads as
  `Scope`: 1 fewer precise expression than all twelve, no call site.
- **Also declare `refined_receiver_class_name` by its parameters.** It takes neither a scope nor a typer; its row buys
  1 precise expression and no call site.
- **Leave out the three functions that take neither and whose return sig-gen renders** (`literal_method_name_argument`,
  `symbol_block_argument`, `refined_receiver?`). 2 fewer precise expressions; each of them is earned, so declaring
  them costs no residue.
- **Declare `call_result_type_for` on the typer** by its parameters. 8 more precise expressions, all in
  `expression_typer.rb`, and no call site: the module reads its answer as `Dynamic` either way.

## Decision

Eleven declarations: the ten sig-gen renders (earned), and `opaque_refinement_span?` by its parameters with an
`untyped` return. `refined_receiver_class_name` and `call_result_type_for` stay undeclared: a row for one precise
expression, or for eight that no call site reads, is the case S8 declined for `resolve_user_def_through_ancestors`.
Every parameter type was checked against the function's call sites: `site` is a `MethodDispatcher::CallContext`,
`receiver` the site's `Type::t?` (a union member is a `Type::t`), `list` the `Array[String | Symbol]`
`Scope#in_effect_refinements` answers, `method_name` and `name` a `Symbol`, `arg_types` the site's `Array[Type::t]`,
`block_type` its `Type::t?`, the class-object receiver a `Type::Singleton` (asked only under that test), `self_type`
the `Type::Nominal` `Combinator.nominal_of` answers, and `node`, `call_node` and `winner` stay `untyped`.
`SIG_PROVENANCE_PARAMETER_ONLY` for `sig/rigor/inference.rbs` goes from 30 to 31 unmarked and
`SIG_PARAMETER_SHAPE_COMPARED_FLOOR` from 1121 to 1132; `SIG_PROVENANCE_RESIDUE` does not move.

The precedent is the amendment's requirement that `sig/` type what a rung calls on its typer, with the provenance
gate's rule that a `parameter_only` row "makes no claim the gate cannot check" (`docs/agents/type-authoring.md`). S5,
S6 and S8 made the same choice for their rung modules (`wd12-s5-project-singleton-sig.md`, `wd12-s6-user-method-sig.md`,
`wd12-s8-overriding-toplevel-sig.md`), but their entries are still in this queue, so they are siblings here.

The class is `open-choice`, not `gate-row`: no residue pin moves, and a `parameter_only` row is a watched class, not an
allow-list row.

## To undo

Delete the `-> untyped` row of `module Refined` in `sig/rigor/inference.rbs` and set the pin back to 30: its `scope`
reads `Dynamic` again. Lower the floor by the declarations removed. A later change that declares
`InEffectRefinements.opaque_in?` would let sig-gen render its return, and the row would leave `parameter_only` for
`generated`.
