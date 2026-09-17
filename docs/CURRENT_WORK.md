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

Four PRs, each implemented by an Opus lane in its own worktree and taken through two or three rounds
of adversarial review before landing; master is green at 02d96189.

- [#1029](https://github.com/rigortype/rigor/pull/1029) closed #986 — colliding compact-header
  buckets are kept as alternatives; a name the two crefs resolve to different project classes declines.
- [#1030](https://github.com/rigortype/rigor/pull/1030) closed #963 item 1 — a `define_method`
  block's `self` is the class instance on both evaluation paths. Items 2 and 3 stay open on #963.
- [#1031](https://github.com/rigortype/rigor/pull/1031) closed #1014 — engine identity reaches the
  five `rbs.*` producer keys; the caveat that used to sit below this section is retired.
- [#1032](https://github.com/rigortype/rigor/pull/1032) closed #1002 — `sig-gen` renders a project
  alias whose lossless expansion equals the union, scoped by namespace proximity.

Two `Scope` rows in `sig/rigor/scope.rbs` carry `# sig-gen gap: #1011` markers because no engine
issue tracks the untyped-return gap; if #1011 rules otherwise, each is a one-line repoint.

## What is worth picking up next

- [#963](https://github.com/rigortype/rigor/issues/963) items 2 and 3, and
  [#534](https://github.com/rigortype/rigor/issues/534) items 5 and 6 — the issue bodies carry the
  live status; each item is independently assignable.
- [#1011](https://github.com/rigortype/rigor/issues/1011) needs a ruling before work starts: are the
  `sig-gen gap:` markers wrong, or is the gate's wording? [#1007](https://github.com/rigortype/rigor/issues/1007)
  and [#1008](https://github.com/rigortype/rigor/issues/1008) are engine gaps sitting behind two
  marked `sig/` rows.
- A separate session is checking why `rigor check` stays silent on `call.wrong-arity` shapes the
  `Analysis::Runner` harness reports (found while fixing #986); its outcome lands as an issue or a
  `docs/agents/measurement.md` entry.

## Where the worktrees are

One remains: `rigor-wt/perfbench-harness-775`, deliberately kept — it is the instrument behind the
#775 allocation work, not leftover scratch. The fifteen worktrees the previous handoff listed are
gone, and every PR they carried is merged.
