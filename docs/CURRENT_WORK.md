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

Four batches, each PR implemented by an Opus lane in its own worktree and taken through one to four
rounds of adversarial review before landing. master is green through c03fd94d; the #1057 merge run
(63bbfa33) was in progress when this was written.

- Batch 1: #1029 (#986), #1030 (#963 item 1), #1031 (#1014), #1032 (#1002).
- Batch 2: #1034 (#534 item 5), #1035 (#963 item 3), #1036 (#391), #1037 (#392), #1041 (#987),
  #1042 (#1039), #1044 (#534 item 6, closes #534), #1050 (#393 slice; #393 stays open as umbrella).
- Batch 3: #1052 (#1049), #1053 (#1038), #1054 (#1051), #1057 (#1048 edge; `Refs`, see below).
- Batch 4: #1061 (#1055), #1062 (#1056; category 2 → #1060), #1063 (#963 item 2).

Two `Scope` rows in `sig/rigor/scope.rbs` carry `# sig-gen gap: #1011` markers because no engine
issue tracks the untyped-return gap; if #1011 rules otherwise, each is a one-line repoint.

## Waiting on the maintainer

- [#1059](https://github.com/rigortype/rigor/issues/1059) — whether first-party `discharge: true`
  plugin rows may prove. #1057's first draft moved them to the proven lane; that contradicts ADR-103
  WD17 (owner ruling 2026-08-24) and was reverted. Until ruled, `views: strict` and `views: lenient`
  do not differ, and #1048 / #393 stay open on that acceptance line.
- [#1011](https://github.com/rigortype/rigor/issues/1011) — the `sig-gen gap:` marker convention.

## What is worth picking up next

- [#1047](https://github.com/rigortype/rigor/issues/1047) — render-site `locals:` and layouts; a lane
  was started on it from 63bbfa33 (branch `render-locals-and-layouts-1047`). If no PR exists, the
  worktree under `rigor-wt/` is its state.
- [#1043](https://github.com/rigortype/rigor/issues/1043) — allocations +15.6% over the v0.3.9
  baseline; a separate session was bisecting it. Recalibration is release prep.
- [#1065](https://github.com/rigortype/rigor/issues/1065) — `.js.erb` rendering an HTML partial
  (34 of redmine's 72 remaining template-side taints): format fallback in the callee rule.
- [#1064](https://github.com/rigortype/rigor/issues/1064) — the Ractor backend's remaining tail
  (shallow-frozen constants, RBS-gem memo, Ruby Bug #22075, lockfile discovery); #1061 fixed the
  constructor-time memos only.
- [#1060](https://github.com/rigortype/rigor/issues/1060) — a positioned once-per-run channel for
  rigor-rails-i18n's view batch.
- [#1040](https://github.com/rigortype/rigor/issues/1040), [#394](https://github.com/rigortype/rigor/issues/394),
  [#963](https://github.com/rigortype/rigor/issues/963)'s non-meta constant-write asymmetry.

## Where the worktrees are

Two: `rigor-wt/render-locals-and-layouts-1047` (the #1047 lane) and `rigor-wt/perfbench-harness-775`, deliberately kept — it is the instrument behind the
#775 allocation work, not leftover scratch. The fifteen worktrees the previous handoff listed are
gone, and every PR they carried is merged.
