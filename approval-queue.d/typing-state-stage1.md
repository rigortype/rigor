# ADR-129 stage 1 names the module `Rigor::TypingState`, represents WD1's split as a Frame whose contents are a Resource, restores no id across a rewrite, and exempts the break sink's size marks

- **PR:** [#2796](https://github.com/rigortype/rigor/pull/2796)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [ADR-129](../docs/adr/129-type-of-result-memo.md)
- **Decided:** 2026-11-04

## Background

ADR-129 stage 1 introduces `Rigor::TypingState` and declares every piece of typing state with one of four kinds. Converting the typer, the statement evaluator and the key-presence guard met three questions the ADR states the rule for but not the representation of:

- WD1 says a Frame value is frozen while installed, and splits the key-presence walk into a Frame (its installation) and a Resource touch (its `record`). The jump sinks and the retry frames have the same shape: an installed container that later code records into.
- WD2 says `TypingState.with` restores the saved id in `ensure`. WD3's id-determined exemption needs the slot's value to be fixed while the id is. The walk's `record` rewrites `guard_ends` in place, so a frame that restored its saved id after a `record` inside it would name two different `guard_ends` with one id.
- WD1 gives `Rigor::Inference::TypingState` as a working name. The recorders and the effects collector outside `inference/` hold typing state too, and the value layer that ADR-104's warm effects probe loads (its budget is 15 `inference/` files) reaches them through `Reflection` and `Effects`.
- WD3 names two read exemptions, with `loops_evaluated` as the delta-internal example. The break sink's size is read before and after a `begin` to find the jumps that construct recorded itself (`restoring_error_info`, `ensure_jump_marks`).

## Options and trade-offs

- **The name.** `Rigor::Inference::TypingState` under `inference/` puts one more file on the engine-free path once a recorder is converted, so the probe's budget would have to move. `Rigor::TypingState` beside `Rigor::RunScopedSlots`, its sibling registry, is where cross-cutting per-thread state already lives, and it holds no engine code.
- **The split.** Two slots per container (a Frame for the install, a storage-less Resource for its contents) would double the declarations and leave the two halves free to drift apart. One Frame slot declaring `contents: :resource` keeps the pair in one place: the install goes through `State#with`, and each mutation of the container calls `State#touch` (or `State#rewrite`) on the same slot. The frozen-value rule then applies to every Frame without that declaration, and the audited-run spec enforces it.
- **The id across a rewrite.** Leaving `with` as WD2 states it would break the id-determined exemption the walk relies on. A per-state epoch, moved by `State#rewrite` and compared on exit, makes a frame that saw a rewrite exit to a fresh id. Stage 0's harness did the same ("a frame whose body wrote a resource it does not own exits to a fresh id"). The guard stack's push and pop do not move it: the stack is back to its contents at the push when it pops.
- **The size marks.** Treating them as touches is sound but refuses every capture around a `begin` with an `ensure` or a rescue inside a loop. Declaring the break sink's contents reads delta-internal matches WD3's definition: the marks only bound the entries the construct appends itself, and those appends touch.

## Decision

`Rigor::TypingState` at `lib/rigor/typing_state.rb`, and the three readings as above: `TypingState.frame(…, contents: :resource)` for the five jump sinks and retry frames and the key-presence walk; `State#rewrite` moves an epoch that `with`, `with_pair` and `without` compare on exit; `break_sink` declares `read_exemption: :delta_internal` for its contents and the key-presence walk `:id_determined`. Both exemptions are claims G1 checks in stage 3. The precedent is ADR-129 itself and its stage-0 harness.

## To undo

Renaming the module back is mechanical (the slot owners under `Rigor::Inference` name it unqualified). Each reading is local to `typing_state.rb` and the slot declarations. Splitting a contents frame into two slots changes only the declarations and the touch calls; dropping the epoch means dropping the walk's id-determined exemption, so its reads become touches; dropping the break-sink exemption makes `restoring_error_info` and `ensure_jump_marks` touch before they read. Nothing depends on them until stage 3 opens a capture.
