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

## What is worth picking up next

- [#1002](https://github.com/rigortype/rigor/issues/1002) — `sig-gen` expands a 22-arm union that a
  project-declared RBS alias already names. Unimplemented, but the `sig/` rows it was filed against
  were retired by #1000; the first step is finding a fresh position, as the issue now says.
- [#1014](https://github.com/rigortype/rigor/issues/1014) — the static half is settled (no engine
  identity reaches the five `rbs.*` keys; the issue records the evidence). What remains is the
  warm-run reproduction and the fix or the documented reason. Closing it retires the caveat below.
- [#1011](https://github.com/rigortype/rigor/issues/1011) needs a ruling before work starts: are the
  `sig-gen gap:` markers wrong, or is the gate's wording? [#1007](https://github.com/rigortype/rigor/issues/1007)
  and [#1008](https://github.com/rigortype/rigor/issues/1008) are engine gaps sitting behind two
  marked `sig/` rows.

## Standing caveat until #1014 closes

A cache slot written by a different build can serve stale plugin-synthesized RBS to new rule code.
#1012 fixed the synthesizer and the plugin producers by adding engine identity to their keys; the
`rbs.*` producers keyed by `RbsDescriptor` are unaudited. Until #1014 closes, judge "does this rule
fire?" on a cold run, and diagnose a suspected stale slot with `rigor check --cache-stats`.

## Where the worktrees are

One remains: `rigor-wt/perfbench-harness-775`, deliberately kept — it is the instrument behind the
#775 allocation work, not leftover scratch. The fifteen worktrees the previous handoff listed are
gone, and every PR they carried is merged.
