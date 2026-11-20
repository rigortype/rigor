# The user-method rung's gate moves with the rung as a third second entry, and the amendment's second entries become a list

- **PR:** [#3371](https://github.com/rigortype/rigor/pull/3371)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S6 of ADR-116's WD12 amendment moves user-method inference, the `user_method` rung of the call ladder, out of `ExpressionTyper` into `CallLadder::UserMethod`. The amendment lets a rung move only when it calls back at most four typer methods (the #3318 cut-off), and says that a rung needing a fifth stays in the typer, named with that count. It also lets a rung module expose a second named entry beside `try_call`, and says: "Each is named here, and there are two": `UserMethod.infer` and, from S8, `OverridingDef.overriding_own_def?`.

The rung calls back four typer methods (`class_graph_buckets`, `positional_correspondence`, `infer_user_method_return`, `degrade_if_overridable`) and reads `scope`. Its first step, though, is a fifth: `user_inference_receiver?`, a private typer predicate that admits a receiver to the rung (a `Nominal`, or a named `Struct` or `Data` instance). Three other typer methods ask it too: `overriding_own_def?` (the own-`def` rung's gate), `own_send_type` (a receiver's own `send`) and `recursion_def_for` (the recursion scan), and `tool/typing_census.rb` reads it. The lane stopped and asked; the coordinator ruled.

## Options and trade-offs

- **Leave the gate in the typer and give the rung a fifth callback.** `PORT` grows to five re-entry points. The lane's brief forbids widening `PORT` to make a move fit, and the amendment's rule says such a rung does not move.
- **Leave the rung in the typer, named with its fifth callback.** S6 delivers no module. S7 comes after it because the literal `send`'s sub-ladder asks this rung, so WD12's order would stall on a predicate of a few lines.
- **Copy the predicate into the module.** Two copies of a test that the rung and its three outside callers must agree on: the kind of hand-made copy WD12 exists to end.
- **Move the gate with the rung as a named second entry (option A).** `PORT` stays at four re-entry points. The typer's three callers and the census ask `CallLadder::UserMethod.user_inference_receiver?`. It is the shape the amendment already gives `OverridingDef.overriding_own_def?` in S8, one slice earlier. It needs the amendment's count of second entries to change.

## Decision

Option A, ruled by the coordinator, on four conditions, each now held:

1. The gate stays a pure predicate on its arguments, with no typer call and no `scope`. `CallLadder::SECOND_ENTRIES` records it with `given_typer: false`. `spec/rigor/inference/call_ladder/port_spec.rb` then requires it to be a function of its arguments alone, and `user_method_spec.rb` pins its arity of one. Inlining a typer call into it fails both (the PR's mutation table).
2. Every other caller is re-pointed at the module constant, and no delegating wrapper is left on the typer.
3. A dated note in ADR-116's amendment changes the rule from a count to a list: second entries are named there, not capped at two. The amendment's two (`UserMethod.infer`, and S8's `OverridingDef.overriding_own_def?`) become three. `SECOND_ENTRIES` holds, as data, the ones whose modules exist: two today, and S8 adds its row.
4. The order pin's check that no method asks two or more different rungs now counts a call of a second entry as asking its rung, so a method that tests this gate and then asks another rung fails. The port spec holds the entry.

The precedent is the amendment itself: a rung's gate that other code asks "moves with the rung, so it is neither copied nor a `PORT` member".

## To undo

Move `user_inference_receiver?` back into the typer as a private method, point its four callers at it, delete its `SECOND_ENTRIES` row, and take the third name out of ADR-116's note. The rung then calls back five typer methods. Under the cut-off it would have to move back into the typer as well (reverting S6), unless an amendment raised the limit. S7 follows S6 and will ask the rung through `CallLadder::UserMethod.try_call`.
