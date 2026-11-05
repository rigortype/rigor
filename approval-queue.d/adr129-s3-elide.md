# ELIDE is measured through a second id that only the stage-3 shadow keys on

- **PR:** [#2876](https://github.com/rigortype/rigor/pull/2876)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2868](https://github.com/rigortype/rigor/pull/2868)
- **Decided:** 2026-11-06

## Background

ADR-129 WD2 defers ELIDE (keeping the state id across an install of an identical value) to stage 3, and its
re-evaluation trigger enables it only once G1 shows zero table mismatches with it on, under the `any` rule. ELIDE
changes the id itself; today only the stage-3 shadow keys on the state id, but every install in production would pay
for measuring it in `State#with`.

## Options and trade-offs

- **A second id** kept beside the state id (`TypingState::ElideId`), maintained only on a thread whose state the
  shadow extends with it (as the key audit extends a state), and used only as the shadow's key. Output and every other
  memo are untouched, and a run without the measurement pays nothing.
- **ELIDE in `State#with` behind a flag:** a branch on every install in production, and the state id would mean two
  different things depending on a switch.

## Decision

The second id, under `RIGOR_TYPE_OF_SHADOW_ELIDE=1` beside `RIGOR_TYPE_OF_SHADOW=1`. A thread's state is extended
at the first file's start; every frame open then closes after that file's end, since the per-file analysis is nested
in them, so no frame exits through the plain `State#with`, which would not restore the second id. It also restarts at
each file's start, which hands out a fresh id for the values installed then.
"Identical" is `equal?` on every slot the install touches; a push, a pop or a rewrite moves it as they move the state
id. Enabling ELIDE for real remains a stage-4 decision on these numbers.

## To undo

Remove `TypingState::ElideId`, the `elide` flag on `TypeOfMemo::Table` and its environment switch.
