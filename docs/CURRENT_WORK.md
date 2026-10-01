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

## Performance campaign, #1507, and the resolution chain (2026-10-01)

The goal is the warm journeys on a Mastodon-sized Rails app (null build, leaf edit, hub edit), for
both plain `check` and `--incremental`. Decisions and measurements are on #1507.

Landed this session: #1552 (an unchanged `--incremental` run served from an ADR-45 slot; the write
guard now takes its mark on a filesystem tick boundary), #1582 (overlapping path arguments, fixing
#1556), #1584 (`unpositioned_mixins`), #1578 (`Scope::ResolutionChain`: Ruby-order ancestors with the
single-route fork rule, `unsettled`, and `settle` as the one decision owner; fixes #1587) and #1593
(singleton-side mixins in blocks that provably run, part of #1592).

Next:

1. **ADR-119, accepted 2026-10-01; PR C in progress.** Landed: #1601 (errata: the C1a–C1e split, Q12),
   #1602 (C1a: `DefinerResolution`, marks, relevance; instance side only), #1610 (ambiguous spellings
   discharge), #1605 (C1b: `SourceArity`, fixes #1570). Waiting on the maintainer:
   - **#1606 (C1c, Draft, CI green, reviewed):** override and visibility lints. It loses real
     diagnostics (Mastodon 10, GitLab controllers 61, all `tp-lost`; 0 corpus FPs silenced). Merge or
     hold is the maintainer's call (ADR Q3); the recoveries are #1608, #1609, #1611, #1612.
   - **Q12** (the admission census reading of WD1(ii)) gates C1d0; C1d follows it.
   - The singleton side is designed (a positional decline) for C2, after #1603; #1607 tracks
     singleton #1570. Fold the C1 planning's WD3/C1c-row errata into the ADR when C1c lands.
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

- **#1499** (#1446, ivar class guards, Draft `9b8bc0c86`): round-1 fixes are pushed. Next is a
  round-2 delta review, then a merge on green CI. #1500 (a disjoint guard reads the guarded class
  for ivar, global or constant receivers, and `bot` for locals) builds on it.
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
