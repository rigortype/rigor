# The live type_of memo opens in the rule walk at an empty guard stack, behind RIGOR_TYPE_OF_MEMO, on the exact id

- **PR:** PR_LINK
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [ADR-129](../docs/adr/129-type-of-result-memo.md) WD4 and WD6 (stage 4: live in the rule walk; stage 5: the main pass and callee bodies)
- **Decided:** 2026-11-06

## Background

ADR-129 stage 4 makes the `type_of` memo live in the rule walk. WD6 names the phase but not how a callee body typed
from the rule walk counts, the switch that turns the live form on, how a live entry is keyed per node, or whether ELIDE
(WD2) keys it. The PR lands the live form off by default and measures it; the PR that turns it on follows.

## Options and trade-offs

- **Callee bodies reached from the rule walk:** open (the guard stack is not empty there, and WD6 puts callee bodies
  in stage 5), or closed. Closed: the computation runs with no lookup, store or capture, and an enclosing rule-walk
  capture still journals its reads, writes and touches (its guard push already refuses it).
- **Switch:** `RIGOR_TYPE_OF_MEMO=rule`, read once at load like `RIGOR_TYPE_OF_SHADOW`; the shadow (the audit) wins
  when both are set. `RIGOR_TYPE_OF_SHADOW=serve` reaches G1's stage-4 form from the CLI for corpus runs and CI.
- **Per-node key:** the shadow's `scope => node => id => entry` allocates two Hashes per looked-up node, which cost
  more allocations than the rule walk's hits saved on `lib` (+0.28%). One slot per node (the last entry stored, keyed
  on node identity with its scope and id beside it) allocates none; stage 0 measured that key losing under 0.3% of
  hits. Measured `lib` −0.03%, Mastodon −5.37%.
- **ELIDE:** allowed by the user for stage 4, but in the rule walk alone it added no hit on Mastodon (12,361 either
  way); its stage-3 gain was rule-walk lookups hitting main-pass entries. The exact id is kept, and the `ElideId`
  extension stays off the live path.
- **Counters:** counted only when a report is asked for, so the live path takes no lock.

## Decision

Closed in callee bodies and the main pass; the two switches above; one slot per node; the exact id; counters only with
a report. Undo: delete the `live` branch in `ExpressionTyper#type_of` and `TypeOfMemo::Live`; nothing else depends on
them while the default is off.
