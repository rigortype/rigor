<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Next session: land the `v0.4.1` milestone (scoped 2026-10-08)

The maintainer scoped `v0.4.1` as a patch: master since `v0.4.0` (21 `changelog.d/` fragments) plus
the 7 issues on the [`v0.4.1` milestone](https://github.com/rigortype/rigor/milestone/10), each
`ready-for-agent` with an agent brief. Scoping is not release prep: only `/rigor-release-prep` cuts.

- **Crashes:** #1518 (both shapes, the second is in its comment) and #1510.
- **Stale `--incremental` answers, one lane:** #1585 and #1554 (both reproduced at `5625e7a14`),
  #1532 and #1525. Each is an input the snapshot fingerprint misses.
- **Unreleased regression:** #1590 (#1578's +5% on recording runs).
- **Deliberately out:** ADR-119 C1d0 onward, so Q12 does not gate this release; the C2-dependent false
  positives #1594, #1607, #1592 and #1572 (reproduced, and present before `v0.4.0`); C1c's `tp-lost`
  recoveries #1608, #1609, #1611 and #1612, a cost accepted for this release; the remaining
  incremental gaps. #1569 and #1550 (`module_function` false positives) and #1533 were offered and
  declined; they are the first candidates if the milestone grows.

## Performance campaign, #1507, and the resolution chain (2026-10-01)

The goal is the warm journeys on a Mastodon-sized Rails app (null build, leaf edit, hub edit), for
both plain `check` and `--incremental`. Decisions and measurements are on #1507.

Landed this session: #1552 (an unchanged `--incremental` run served from an ADR-45 slot; the write
guard now takes its mark on a filesystem tick boundary), #1582 (overlapping path arguments, fixing
#1556), #1584 (`unpositioned_mixins`), #1578 (`Scope::ResolutionChain`: Ruby-order ancestors with the
single-route fork rule, `unsettled`, and `settle` as the one decision owner; fixes #1587) and #1593
(singleton-side mixins in blocks that provably run, part of #1592).

Next:

1. **ADR-119, accepted 2026-10-01; PR C nearly done.** Landed: C1a #1602, #1610, C1b #1605, C1c #1606,
   C1d0 #1617 (Q12 adopted), C1d-a #1623, C1d-b #1631, C1d-c #1630, C2-a #1621 (singleton side,
   positional hook decline), C2-c #1632 (SourceArity singleton; fixes #1607), C2-e #1620 (fixes #1615);
   also #1616 (fixes #1603) and #1618 (fixes #1585, #1554). Open:
   - **C2-b1 (#1629, Draft, held):** the instance typing site. As is it adds a false positive
     (`media.rb:281`: an RBS-less gem module ahead turns a raising helper's `bot` into `Dynamic`) and
     cuts typed calls (Mastodon -32%, GitLab -76%). A Fable diagnosis: 47-69% are own-class hits
     declined by marks (#1622), Mastodon's bulk is `RoutingHelper`'s `"*"` (#1608).
   - **A1 (#1635, Draft, held):** sound for cold runs after round 2 (rule 2, the declared-module
     rule, was removed — tracked in #1612), but warm `--incremental` goes stale: `own_hit_exposed?`
     files no edges for the foreign-hook scan or receiver-form singleton facts (see the PR comment).
     With the strict hook test the typing gain is 0, so decide whether a positional refinement (only
     the root's direct mixins' `included` and superclasses' `inherited` can prepend onto the root)
     makes it worth finishing. Extract its independent `record_beyond` fix first (#1637).
   - **Next for C2-b1:** A2 = #1608's include-kind sentinel (the Mastodon lever); the raising-helper
     FP needs plugin RBS for ActionView/Pundit (#1611) or a widen-on-undecided-`bot` join. Then rebase
     #1629 and re-run its typing census.
   - Other open findings from this round: #1625, #1626, #1627, #1628, #1633, #1634 (stale, multi-file
     reopen), #1636 (hook prepends with no mark), #1624, #1622.
   - C2-b2 (the singleton typing memo) and C2-d (#1604, optional) follow C2-b1.
2. **Open false positives the chain cannot fix by falling back to master's order** (unsettled means
   master's order, not a decline): #1592's hook shapes and #1594 (a concern's `included do`). Both
   need PR C's `Unknown` or the concern/hook model of a follow-up ADR.
3. **Filed follow-ups:** #1583, #1585 (stale `--incremental` after a `pre_eval:` edit, severe),
   #1586, #1588, #1589, #1590 (record each chain once per consumer; recording runs are +5%), #1591
   (unsettled chains send 21% of Mastodon's reads to master's order), #1573.
4. After those: #1537, #1532/#1533, #1575.

Needs the maintainer: #120 (`--incremental` as the default) goes to them as an ADR, as would a new
cache format or native code.

## Special-variable semantics (ADR-117), carried over

These items were not re-verified this session beyond the states of the PRs.

- **#1499** (#1446, ivar class guards) merged 2026-10-01. #1500 (a disjoint guard reads the guarded
  class for ivar, global or constant receivers, and `bot` for locals) builds on it; #1596 is the
  most common report left on that shape.
- **ADR-117 order:** #1426, then #1427, then #1366's stream part. #1484 must land before that
  stream part. #1366 stays `ready-for-human`.
- **#1454:** phase 3, the handbook chapter, waits for #1366, #1426 and #1427. Keep
  `docs/type-specification/global-variables.md`'s list of violations current.
- **`ready-for-agent` in `v0.4.x`:** #1447, #1437, #1423, #1375, #1372, #1371, #1416, #1373,
  #1443. Triage the `needs-triage` queue with `gh issue list -l needs-triage`.
- **Sibling Draft #1397** restructures `eval_ensure`. It must keep #1449's ensure rule for `$_`.

## What bit

- A handoff's own claim can be wrong: the worktree said lost for #1578 still held its WIP. Check
  `git worktree list` and each tree's status before believing it.
- `unsettled` sends a read to master's order. A taint only helps where master is right; #1593's
  first draft re-broke #1567 that way. Use a decline (PR C's `Unknown`) where master is wrong too.
- A differential fuzzer (random mixin programs against real Ruby and master) found every severe
  chain defect the reviews found. Its untracked scripts sit in
  `../rigor-wt/review/review-1578/tmp/rv/`; move them into `tool/` before ADR-119 PR C needs them.
