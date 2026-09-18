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

## What the 2026-09-19 session settled

A grilling session ruled on every open maintainer question from the previous handoff. The rulings
then went through an adversarial review, which overturned two first drafts: one contradicted the
#1046 ruling, and one misread Rails `default_render`. The rulings are recorded where they bind:

- **#996 → [ADR-112](adr/112-extrbs-comment-channel.md)** (Accepted; ADR-111 superseded). Rigor reads a
  `# @extrbs` channel for what RBS cannot spell, and plain RBS stays in `@rbs` / `#:`. sig-gen writes
  the refinement into `sig/` as `%a{rigor:v1:…}`. A consistency rule replaces ADR-32 WD13's
  "`sig/` wins". Implementation: #1073 (reader), #1074 (payload grammar and escape), #1075
  (consistency rule), #1076 (sig-gen; blocked by #1073 and #1074).
- **#1059**: ADR-103 WD17 kept. The manual's `views: strict` / `lenient` pair is merged into one
  example. #1048 and #393 are closed, and #394 is unblocked.
- **#1011, #1071**: rulings posted; both are `ready-for-agent`. #1072 is closed as a duplicate of #512.
- **`rigor lens` → [ADR-113](adr/113-rigor-lens.md)** (Accepted; also reviewed adversarially). It is a
  declaration map with type provenance and lisplens-compatible anchors, computed as a one-file
  `check`. `type-of` adopts the same computation, which supersedes #512's "unseeded" ruling; #512
  closes with #1083. Issues: #1080 (`def_sites`), #1081 (xxh3), #1082 (`declared_members`), #1083
  (phase 1), #1084 (MCP / skills), #1085 (phase 2 `--annotate`, `ready-for-human`).
- **#1046**: the 2026-09-17 ruling stands (accept, recalibrate at release prep). #1043 is closed.
  Non-gating follow-ups: #1077 (trim #1010's arity waste) and #1078 (run `release-gate.yml` on a
  schedule).
- Feedback for the ZARD first draft:
  [`docs/notes/20260919-zard-first-draft-feedback.md`](notes/20260919-zard-first-draft-feedback.md).

## Waiting on the maintainer

Nothing from this list. The only open ruling-type issues left are the long-standing
`ready-for-human` backlog (`gh issue list --label ready-for-human`).

## What is worth picking up next

Delegable, independent: #1071, #1011, #1077, #1078, #1081, #1082, and #394's V3 slices (Jbuilder,
ViewComponent, Haml/Slim). Core: #1073 → #1074 → #1075 / #1076 (in that order, one lane); #1080 →
#1083 → #1084 (the lens lane); #394 V2,
#963's non-meta constant-write residue, and #1064 item 6 (low value while ADR-15 is open). Measure
#1077 with no other measuring lane active; read `docs/agents/measurement.md` first.

## Where the worktrees are

`rigor-wt/perfbench-harness-775` is kept deliberately: it is the instrument behind the #775 allocation
work.
