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

## What the 2026-09-21 `/queue-release` session landed

Grok-max review Approved, then merged (merge commits, still Draft-ready until the land instruction):

- [#1159](https://github.com/rigortype/rigor/pull/1159) → `79fa99cf` — #1130 block-param `SelfSubstitute` verdict (Candidate B: keep-vs-degrade only; no return-path widening).
- [#1160](https://github.com/rigortype/rigor/pull/1160) → `9fd4b6d4` — #1071 per-arm `respond_to` edges.
- [#1161](https://github.com/rigortype/rigor/pull/1161) → `19c2af59` — #1089 enum column reads as key union.

Still open from that batch:

- [#1158](https://github.com/rigortype/rigor/pull/1158) (#1011) — Approved. First CI died on shard-1 artifact upload 403; failed jobs were re-run. Merge when that run is green. Do not treat the 403 as a test failure.
- [#1162](https://github.com/rigortype/rigor/pull/1162) — process note `docs/notes/20260921-queue-release-lane-experience.md`. Draft; not in the adversarial-review set. Land or close at discretion.

Lane experience (bundle path, `--body-file`, 30-minute corpus timeout, Flash model id) is in that note, not here.

`v0.4.0` remains context. No changelog seal, no VERSION bump, no `release/x.y.z`.

## Waiting on the maintainer

Nothing new. Long-standing `ready-for-human` backlog is unchanged (`gh issue list --label ready-for-human`).

## What is worth picking up next

Resume `/queue-release` at **#1123** (`Module#prepend` ignored in discovered-ancestor ordering), then #1122, #1125, #1121.

Still delegable from the prior handoff: #1073 → #1074 → #1075 / #1076 (ADR-112, order-locked); #1080 → #1083 → #1084 (lens); #963 residue; #1077 / #1078 (non-gating). #1046 stays release-prep recalibration.

## Where the worktrees are

`rigor-wt/perfbench-harness-775` is kept deliberately. This session also left managed pi-subagents worktrees under `/Users/megurine/repo/ruby/worktrees/rigor/`; prune after #1158 lands if they are idle.
