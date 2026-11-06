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

## State at 2026-11-06 (v0.4.7 released)

- **v0.4.7 shipped** (tag `v0.4.7`, 2026-11-03). The perf-gate corpus is advanced to it
  (`bench/baseline.json`, `bench-corpus-v0.4.7`). The v0.4.8 milestone holds the open follow-ups.
- **The approval queue is not empty**: `approval-queue.d/` holds 23 entries (ADR-128/129/130,
  typing-state, VS Code and others). The maintainer ratifies them at `/rigor-release-prep`, not before.
- **ADR-129 (typing state) is the active engine campaign**: stage 3 slices are landing as `adr129-s3-*`
  PRs. Its open follow-ups are the `ADR-129` issues (for example #2798, #2805, #2813, #2853).
- **The Pi harness (ADR-115)** now routes reviews to a co-primary pair, Grok:xhigh and
  `devin/swe-2`:high, both of which must Approve (PR #2885). `devin/swe-2` is a free tier "this month",
  so re-check the binding when it ends.
- **The dev-loop post-mortem recurs** after each release (`rigor-release-prep` § "File the next
  dev-loop post-mortem"). The v0.4.7 one is #2333; the v0.4.8 one is filed in its milestone.

## Next

1. Triage the v0.4.8 milestone (`gh issue list --milestone v0.4.8`). Read
   `docs/agents/parallel-lanes.md` before fanning out.
2. Optional cleanup the maintainer has not ruled on: worktrees under `rigor-wt/` whose PRs merged but
   whose local branches still show commits not on `master` (probably merge-queue rebases). Confirm with
   `git range-diff` before removing any.
