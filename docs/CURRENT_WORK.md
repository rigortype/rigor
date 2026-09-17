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

## Waiting on the maintainer

**[PR #1027](https://github.com/rigortype/rigor/pull/1027) is open as a Draft and cannot land without
a ruling.** It reorganizes the agent instruction set: AGENTS.md drops from 231 to 127 lines by moving
conditional rules behind pointers (`docs/agents/contribution-flow.md`, `docs/agents/type-authoring.md`,
and a new `docs/agents/measurement.md`), and skill descriptions route on task boundaries rather than
implementation detail. Base is `master`; `make docs-check` is green.

Two things about its shape are worth knowing before touching it. The branch `codex/optimize-agent-instructions`
exists on the remote and has **no PR of its own** — its commit is the first of #1027's five, so landing
#1027 lands it; do not open a second PR for that branch. And the branch name carries a tool prefix,
which the PR itself now forbids: renaming a branch under an open PR closes the PR (the GitHub rename
API deletes the old ref), so the name stays until #1027 lands.

**[ADR-111](adr/111-inline-refinement-carrier.md) is Proposed and waits on a ruling** ([#996](https://github.com/rigortype/rigor/issues/996)).
It recommends reaffirming that Rigor has no comment dialect of its own, on a boundedness rather than
an invisibility criterion, and recommends the same-line `%a{}` spelling only — Steep reports the
own-line form the manual documents as a user-visible error, while the same-line form is clean in all
three readers. Grounded in [`docs/notes/20260912-inline-refinement-carrier-probe.md`](notes/20260912-inline-refinement-carrier-probe.md).
Nothing is implemented; the maintainer decides.

## What landed on 2026-09-17

Two batches, each PR implemented by an Opus lane in its own worktree and taken through one to four
rounds of adversarial review before landing. master is green through 0bd70a45; the #1050 merge run
(cd550f31) was in progress when this was written.

Batch 1: [#1029](https://github.com/rigortype/rigor/pull/1029) (#986),
[#1030](https://github.com/rigortype/rigor/pull/1030) (#963 item 1),
[#1031](https://github.com/rigortype/rigor/pull/1031) (#1014),
[#1032](https://github.com/rigortype/rigor/pull/1032) (#1002).

Batch 2: [#1034](https://github.com/rigortype/rigor/pull/1034) (#534 item 5),
[#1035](https://github.com/rigortype/rigor/pull/1035) (#963 item 3),
[#1036](https://github.com/rigortype/rigor/pull/1036) (#391, sig-gen `%a{pure}` with five withholding
gates), [#1037](https://github.com/rigortype/rigor/pull/1037) (#392, template-unit seam),
[#1041](https://github.com/rigortype/rigor/pull/1041) (#987), [#1042](https://github.com/rigortype/rigor/pull/1042)
(#1039, `Const.new` → `#initialize` with an opaque-ancestry sentinel),
[#1044](https://github.com/rigortype/rigor/pull/1044) (#534 item 6, closes #534),
[#1050](https://github.com/rigortype/rigor/pull/1050) (#393, ERB units in rigor-actionpack).

Two `Scope` rows in `sig/rigor/scope.rbs` carry `# sig-gen gap: #1011` markers because no engine
issue tracks the untyped-return gap; if #1011 rules otherwise, each is a one-line repoint.

## What is worth picking up next

- [#1043](https://github.com/rigortype/rigor/issues/1043) — `rigor check lib` allocations are +15.6%
  over the v0.3.9 baseline; the release gate would fail today. Confirm on Linux, bisect the
  2026-09-16/17 merges, then decide design cost vs accidental hot path. Recalibration is release prep.
- [#1048](https://github.com/rigortype/rigor/issues/1048) and [#1047](https://github.com/rigortype/rigor/issues/1047)
  — the two #393 acceptance lines that #1050 could not meet (controller → template edge and the
  `render` taint; render-site `locals:` and layouts). #393 stays open as their umbrella.
- [#1049](https://github.com/rigortype/rigor/issues/1049) — `:model_index` gaps (`delegate`,
  concern-declared associations, attachment macros) that keep 15 correct mastodon serializers
  declining in rigor-active-model-serializers.
- [#1038](https://github.com/rigortype/rigor/issues/1038), [#1040](https://github.com/rigortype/rigor/issues/1040),
  [#1051](https://github.com/rigortype/rigor/issues/1051) — template-unit follow-ups (LSP recompile
  memo, `type-of` through units, per-worker duplicate load-error rows).
- [#963](https://github.com/rigortype/rigor/issues/963) item 2 and [#394](https://github.com/rigortype/rigor/issues/394)
  (views V2/V3, now unblocked by #393's slice).
- [#1011](https://github.com/rigortype/rigor/issues/1011) needs a ruling before work starts.

## Where the worktrees are

One remains: `rigor-wt/perfbench-harness-775`, deliberately kept — it is the instrument behind the
#775 allocation work, not leftover scratch. The fifteen worktrees the previous handoff listed are
gone, and every PR they carried is merged.
