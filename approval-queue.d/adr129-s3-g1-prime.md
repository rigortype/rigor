# G1's stage-4 form recomputes first and serves after an undo, and six of G1′'s faults are caught on synthetic fixtures

- **PR:** [#2882](https://github.com/rigortype/rigor/pull/2882)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-06

## Background

ADR-129 WD5's G1′ asks, for each fault switch, a spec in which G1's stage-4 form reports a mismatch on a fixture, and
WD6's stage-3 exit requires every injected fault detected. The ADR describes the stage-4 form (recompute with the memo
suspended into an isolated journal, undo its writes and restore every Resource, then serve and compare) but not how a
Resource is restored, where the faults live, or what a fixture may be. Over the 145 integration fixtures the stage-4
form served 2,666 hits with no mismatch, and detected none of the ten faults: those fixtures never make a read slice go
stale, never nest a served hit under a stored one, and never raise.

## Options and trade-offs

- **Resources:** snapshot and restore every Resource around the recomputation (a deep copy per slot, in-place
  mutations included), or treat a recomputation that touched a Resource as a mismatch and let its answer stand, which
  needs no snapshot: a stored entry's computation touched none, so a touching recomputation already disagrees with it.
- **The isolated journal:** a separate journal, or the real one with the recomputation's records dropped
  (`State#truncate_journal`) before the served entry's reads are merged and its writes replayed.
- **Faults:** switches in production code, or modules prepended from `spec/support`, each a no-op unless selected.
- **Fixtures:** Ruby source analysed by the runner where one triggers the fault; otherwise a synthetic fixture that
  drives `TypeOfMemo.shadow` with stand-in computations over the real slots.

## Decision

The touch-is-a-mismatch reading, the truncated real journal, faults in `spec/support`, and source fixtures for four
faults (ignore a Frame, skip a restore, refuse only the innermost capture, skip read validation) with synthetic ones for
the other six (skip ABSENT logging, skip the upward merge, skip journaling the replay, both Memo-miss forms, store a
raised computation). For those six no source shape was found over the integration fixtures: a non-set-only Table read
never goes stale between two typings of one key, the return memo's and the loop record's misses already touch a
Resource, and the engine is fail-soft, so nothing raises out of `type_of`. A source fixture that triggers one replaces
its synthetic one. Each fixture also asserts no mismatch with no fault.

Two consequences of the touch reading and the real journal depart from WD5's wording. A touching recomputation's
refusal reaches the real enclosing captures (WD5: "refusals do not reach the real captures"): output is production's
then, but the enclosing entries are not stored, so later hit counts differ from real serving. And an error while
serving (an undo or a replay into a store the entry outlived) is a counted mismatch, and the recomputation's answer
stands. skip_validation also has a synthetic fixture, where serving the stale entry answers the wrong type; its source
fixture shows only the stage-4 form's own revalidation.

## To undo

Snapshot the Resources instead of the touch reading, or move a fault to a production switch; each is local to
`lib/rigor/type_of_memo/serving.rb`, `spec/support/type_of_memo_faults.rb` and the faults spec.
