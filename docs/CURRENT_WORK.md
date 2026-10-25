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

## State at 2026-10-25 (v0.4.6 released)

- **v0.4.6 shipped** (tag `v0.4.6` at 25e637732, RubyGems, GitHub Release). The perf-gate corpus is
  advanced to v0.4.6 (#2331). The approval queue is empty.
- **The development loop changed** in #2332. Premise checks and small post-review edits stay in the
  coordinator's own loop. Lane briefs load the `rigor-lane` skill and carry the inline floor from
  `docs/agents/parallel-lanes.md` step 5. Fix rounds return to the same lane. A per-PR allocation
  delta above `pr_allocations_pct` holds the PR. Read parallel-lanes.md before fanning out.
- **A post-mortem of that loop is due after v0.4.7 ships** (#2333), before any v0.4.8 triage. During
  v0.4.7, record the metrics #2333 lists as work happens.
- The approval queue may now be ratified in batches during a long window, and ratified entries are
  deleted on `master` (`approval-queue.d/README.md`).

## Next

1. Triage v0.4.7. The milestone holds the follow-ups filed during v0.4.6. The engine ones are
   #2287 (loop aliases), #2289 (Tier C ordering), #2292 (value-position memo), #2294 (Set
   mutation), #2296/#2297 (callee floor), #2299–#2306, #2310, #2312, #2314, and #2317–#2326. Also
   #2300 (sig-gen per-file indexing: measure first) and #2305 (Devise RBS: not bundled for now).
2. Optional cleanup the maintainer has not yet ruled on: about 14 worktrees under `rigor-wt/` whose
   PRs merged but whose local branches still show commits not on `master`. They are probably
   merge-queue rebases. Confirm with `git range-diff` before removing any.
