# `infer_user_method_return` is declared `-> Type::t?`, the unrenderable row moves to it from `return_type_for`, and two rung functions declare only their parameters

- **PR:** [#3371](https://github.com/rigortype/rigor/pull/3371)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S6 of ADR-116's WD12 amendment moves the user-method rung into `CallLadder::UserMethod`. The amendment has `sig/` declare `typer` as `ExpressionTyper` and declare each `try_call`, so that what a rung calls on the typer is typed in Rigor's own check. The rung calls back four typer methods that had no declaration. A call on a declared `ExpressionTyper` to an undeclared method reads `Dynamic`, and so does a parameter of an undeclared function.

`rigor sig-gen` renders a return for `positional_correspondence` and `degrade_if_overridable`. It skips `infer_user_method_return` and `class_graph_buckets` as `sig.skipped.untyped-return`: the first is the memo, recursion guard and fixpoint that type a body, and the second a run-scoped table. Of the module's twelve functions it renders nine and skips three: `resolve_typing_def_with_owner` (it answers what `MemoAudit.check` yields), `definer_without_single_body?` (it answers `DiscoveryIndex` predicates, which are undeclared) and `note_missing_class`. Each declaration moves a pin in `spec/rigor/sig_gen/provenance_spec.rb`.

## Options and trade-offs

- **`infer_user_method_return`.** Declared `-> Type::t?`, it is an `unrenderable` residue row. `ExpressionTyper#return_type_for`, its public face, already declares `-> Type::t?`, and its body is one call of `infer_user_method_return`. With the declaration, sig-gen renders that body, so `return_type_for` leaves `unrenderable` for `parameter_intent`: the residue pin for `sig/rigor/inference.rbs` stays at 68. The declared type is the one `return_type_for` already states for the same value. Undeclared, what `infer` and `every_definer_raises_type` get back reads `Dynamic`.
- **`class_graph_buckets`.** A hand-written declaration would be one more residue row for one read of `[:typing_def]` in `resolve_typing_def_with_owner`. Undeclared, that read is `Dynamic`, as it was in the typer.
- **The two functions sig-gen skips.** Declaring their parameters with an `untyped` return makes each a `parameter_only` row: watched and pinned, but not residue. Their `typer` and `scope` then read as `ExpressionTyper` and `Scope` inside them. In the self-typing ratchet (`rigor coverage`) that is 36 more precise expressions and 8 fewer `Dynamic` call sites in `user_method.rb`, measured on the slice's head with and without the two declarations. Left undeclared, the parameters read `Dynamic`. `note_missing_class` reads none of them and stays undeclared.

## Decision

`infer_user_method_return` is declared `-> Type::t?`, and the unrenderable row moves from `return_type_for` to it. `class_graph_buckets` stays undeclared. The two functions declare their parameters with an `untyped` return. The pins move with a reason at each: `SIG_PROVENANCE_RESIDUE` for `sig/rigor/inference.rbs` stays at 68 (0 net), `SIG_PROVENANCE_PARAMETER_ONLY` for it goes from 14 to 16 unmarked, and `SIG_PARAMETER_SHAPE_COMPARED_FLOOR` from 1074 to 1088 (fourteen new declarations of a `def`, every one fitting).

The precedent is the amendment's own requirement that `sig/` type what a rung calls on its typer, together with the provenance gate's rule that a `parameter_only` row "makes no claim the gate cannot check" (`docs/agents/type-authoring.md`). S1 (#3366) made the same move for `dispatch_site` and `resolve_site`, but its entry is still in this queue, so it is only a sibling here, not a precedent.

## To undo

Delete the `infer_user_method_return` row: `return_type_for` goes back to `unrenderable`, and what the rung gets back reads `Dynamic`. Delete the two `parameter_only` rows: their parameters read `Dynamic`, and the pin goes back to 14. Lower the floor by the declarations removed. Later rung slices that call `infer_user_method_return` through `PORT` (S5's project-singleton inference among them) would lose the typed answer too.
