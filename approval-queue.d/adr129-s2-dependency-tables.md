# The ADR-46 dependency reads log only the captures a filing probes, and the capture stack is an id-determined Resource

- **PR:** [#2852](https://github.com/rigortype/rigor/pull/2852)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2841](https://github.com/rigortype/rigor/pull/2841)
- **Decided:** 2026-11-05

## Background

ADR-129 WD1 lists the ADR-46 dependency reads as a Table, and its G3 bullet says stage 2 makes them journaled Tables replayed on a hit. In stage 1 the recorder's accumulator was a `contents: :resource` Frame and the ADR-84 capture stack a plain Resource, so every dependency event refused the enclosing capture. Converting them left three choices the ADR does not settle.

## Options and trade-offs

- **Which captures log a filing.** A filing tees into the open captures innermost first and stops at the first capture that already holds the key, because every outer capture then holds it too (the stack's subset property). Logging only the captures the walk probes adds one read per probed store; logging every open capture would add a read per capture per event with no information the subset property does not already give.
- **How `withhold` swaps the stack.** Each swap must take a fresh id, or the recorder's frame id would name two stack contents. Two ways give one: `state.write` plus `state.rewrite` (fresh id and a new epoch), or a fresh id that keeps the epoch, as `push` and `pop` do. The epoch move is stronger than the restore needs, since the restore puts the identical stack back, and it costs id stability in every frame open around a `withhold` once a memo is live under `--incremental`. `State` has no fresh-id-same-epoch write today, and the memo stays shut while recording runs (WD4), so the cost is nil until then; adding that write is a stage-3 refinement.
- **`record_for`'s `suspend!`.** It mutates a counter on the installed accumulator outside any table entry, so it stays a touch, and the recorder's Frame stays `contents: :resource`.

## Decision

Log only the probed captures (stage 3's validation must rely on the same subset property), swap with `write` + `rewrite`, and keep `record_for`'s touch. The capture stack becomes `read_exemption: :id_determined`: every push, pop and swap takes a fresh id, so the event paths read it without refusing. This follows the bound-Table shape #2841 set for the advisory tables.

## To undo

Log every open capture on each filing, or turn the capture stack back into a plain Resource (every event refuses again, as in stage 1).
