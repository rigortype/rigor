# ELIDE is measured through a second id that only the stage-3 shadow keys on

- **PR:** [#2876](https://github.com/rigortype/rigor/pull/2876)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2868](https://github.com/rigortype/rigor/pull/2868)
- **Decided:** 2026-11-06

## Background

ADR-129 WD2 defers ELIDE (keeping the state id across an install of an identical value) to stage 3, and its
re-evaluation trigger enables it only once G1 shows zero table mismatches with it on, under the `any` rule. ELIDE
changes the id itself, which the ADR-84 return memo also keys on, so measuring it by changing `State#with` would
change the return memo's hits and therefore possibly the output.

## Options and trade-offs

- **A second id** kept beside the state id (`TypingState::ElideId`), maintained only on a thread whose state the
  shadow extends with it (as the key audit extends a state), and used only as the shadow's key. Output and every other
  memo are untouched, and a run without the measurement pays nothing.
- **ELIDE in `State#with` behind a flag:** a branch on every install in production, and it moves the return memo's key.

## Decision

The second id, under `RIGOR_TYPE_OF_SHADOW_ELIDE=1` beside `RIGOR_TYPE_OF_SHADOW=1`. It restarts at each file's
start, when every frame then open stays open until the file ends, so it names the frames installed within the file.
"Identical" is `equal?` on every slot the install touches; a push, a pop or a rewrite moves it as they move the state
id. Enabling ELIDE for real remains a stage-4 decision on these numbers.

## To undo

Remove `TypingState::ElideId`, the `elide` flag on `TypeOfMemo::Table` and its environment switch.
