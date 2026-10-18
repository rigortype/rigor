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

## State at 2026-10-19 (master after #2130)

**`v0.4.4` is released.** The **`v0.4.5` milestone** stands at 26 open / 41 closed. A second
v0.4.5 batch landed about 40 PRs on master between #2062 and #2130, each through an Opus review
and the `bin/lane-push` flow (up to four lanes at once).

## In flight

1. **#2132 (Draft, `Fixes #2121`)** — branch `rbs-env-identity-dependency-leak`, worktree
   `rigor-wt/rbs-env-identity-dependency-leak`, head `3f59c80b5` on master `a4ab2efdb`.
   Product bug: `--incremental` served a stale silent result after a project `attr_*` /
   `alias_method` / `define_method` declaration was removed, because `Scope#discovered_method?`
   recorded no dependency on a hit (shipped in v0.4.4). Fix records the class edge and
   `defines:<method>` on a hit; the spec `RbsEnvMemo` now keys on absolute paths.
   The `scope.rbs` provenance pin moved 113 → 112 **with the maintainer's approval**.
   **The Opus review was stopped mid-way — start it again** (cost of the new file-level class
   edge on `--incremental` is unmeasured; check cold `rigor check` is byte-identical).
   Rebase with `bin/lane-push` before merging (master moved).
2. **#2088 (Draft, `Refs #1956`)** — held until #1064 (CRuby Bus Error in the Ractor pool) is
   fixed: on a real project it moves plugin runs from a degraded-but-complete result to a crash.
   Its first four commits still say `Fixes #1956`: reword at the next rebase or squash-merge.
3. Other sessions' PRs: #2015 (lens), #1828 (refinements), #1771 (do not resume as is).

## Next

1. Finish #2132 (above), then continue `v0.4.5`. Most remaining ready-for-agent items need a
   maintainer decision or wait on something: #1817 (overlaps #1771; inter-procedural read or a
   blanket decline), #1076 (blocked by #1073 / #1074), #1891 (nested literals), #1768 (Grape),
   #1833 (namespaced remainder), #1843 (epic), #1557 (hand-authored sig), #1814 (other session).
2. Independent follow-ups filed this batch, good lane candidates:
   - engine false positives: #2071, #2074, #2075, #2083, #2087, #2090, #2091, #2092, #2094,
     #2104, #2108, #2127, #2128;
   - incremental / cache: #2100, #2119, #2105;
   - sig-gen: #2085, #2095, #1154 (now also cites `refusal_summary`);
   - robustness: #2125 (String folds have no size cap), #2116 (v0.5.0 design: statically
     certain errors as `bot` + `flow.always-raises`);
   - tooling: #2101 (intermittent CRuby GC crash in CI), #2131 (more include-guard spellings),
     #2021, #2053 (still open from the previous batch).
3. **Gated on the maintainer** (unchanged): #1651 / `v0.5.0`, #1676, #120, #1829 / #1814 / #1815.

## How this batch ran (keep doing)

- Route contained lanes (a crash guard, a marker re-point, a spec-only fix) to **Haiku**; Ruby
  semantics, cache soundness and reviews to **Opus**. The maintainer restated this on 2026-10-18.
- A lane STOPS at any ADR-119 gate / census / producers / provenance-pin move and the coordinator
  asks the maintainer. Approved this batch: producers rows for #2081, #2093, #2086, #2107, #2130;
  census rows for #2086 and #2103; the #2132 pin. Never reshape code to dodge a gate.
- After round 3 a narrow severe finding lands through one fix-only check; this batch also used a
  short coordinator-narrowed check for one-line conservative fixes (#2077).
- `make verify-changed` does not run `ancestry_walker_detection_spec` or `producers_spec` on every
  change (#2053): lanes touching dispatch or discovery must run them by hand before pushing.

## What bit

- Rules made "only as precise as provable" still put diagnostics on correct code when the
  fallback was wider than the fact: a declined `**` fell through to RBS `Numeric` (#2122), a
  "foreign self" rule trusted a receiver that could be `self` (#2077, four rounds). When a check
  declines, answer the narrowest sound type, and probe receivers that may be `self`.
- `tool/engine_diag_diff.rb --corpus-dir` under a worktree's `tmp/` can report a vacuous 1/1;
  confirm the base row count is non-trivial or diff direct JSON runs.
- Premise checks matter: three lanes found their issue already fixed (#1959 item 2, #1594) or the
  cause elsewhere (#2121 was a product bug, not only a spec-memo bug).
