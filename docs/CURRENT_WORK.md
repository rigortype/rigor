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

## State at 2026-10-19 (v0.4.5 released)

**`v0.4.5` is released** (release PR #2145, merged as `56cbfce60`; tag `v0.4.5`). The `v0.4.5`
milestone has 0 open issues (45 closed); the triage before the release kept only #1833 and moved
the rest to the new **`v0.4.6` milestone**, which now holds the open work.

**The perf-gate corpus advances to `v0.4.5`** with #2149 (recalibrated from a branch cut at the
tag). The release gate first failed on allocations (+3.4% over corpus v0.4.4). The largest per-PR
share was #2051 (+618k of +1.89M), which amplified a subclass-map rebuild on every ivar proof;
#2146 memoised the map, bringing the gate back to +0.79% without re-baselining. The baseline's
`note` carries the numbers. Its wall_s (56.5s) came from a fast runner: a `wall_s`-only red cut is
noise, rerun it (rigor-release-prep), never recalibrate for wall.

**The landing flow (ADR-123).** `master` has a merge-queue ruleset; land with
`bin/land-pr N <reviewed-head-sha>` in the background (`gh pr merge` fails: auto-merge is off).
Non-serious decisions are made by precedent and recorded in `approval-queue.d/`, which release prep
reports for ratification; it holds only its README after the v0.4.5 ratification.

## In flight

1. **#2088 (Draft, `Refs #1956`)** — held until #1064 (CRuby Bus Error in the Ractor pool) is
   fixed: on a real project it moves plugin runs from a degraded-but-complete result to a crash.
   Its first four commits still say `Fixes #1956`: reword at the next rebase or squash-merge.
2. Other sessions' PRs: #2015 (lens), #1828 (refinements), #1771 (do not resume as is).

## Next

1. **#2148 first** — `rigor check --workers 2` crashes the VM with `[BUG] Bus Error` over the
   v0.4.4 tree in most runs (frames in `digest.rb`, `plugin/base.rb:930`, `marshal`). It is the
   default pool backend, not the Ractor one, so a user with `--workers` can get a crash instead of
   a report; the release gate and the per-PR allocation A/B run single-process and never see it.
   Needs a Linux and a macOS reproduction with the full `[BUG]` report, and a plugins-off run.
2. **Incremental silent-hit edges filed this cycle** (ADR-46; the same shape #2132 fixed for
   `Scope#discovered_method?`): #2133 (`RubyDeprecations#project_defines?`), #2134
   (`Scope#discovered_method_visibility`), #2137 (`SelfCallIvarWrites#rewritten?`). Each is a
   lookup that records no dependency on a hit, so `--incremental` can serve a stale result.
3. **#2147** — editor publish drops the self-call ivar-write proof across files and reports a false
   `call.undefined-method` that the CLI does not.
4. The rest of `v0.4.6`: ready-for-agent #1956, #1891, #1817, #1768, #1557; needs-triage #1934;
   the sig-gen `ready-for-human` cluster (#1148–#1155, #1157, #1167, #1183).
5. Lane candidates from the previous batch still open: engine false positives #2071, #2074, #2075,
   #2083, #2087, #2090, #2091, #2092, #2094, #2104, #2108, #2127, #2128; incremental / cache #2100,
   #2119, #2105; sig-gen #2085, #2095; robustness #2125, #2116; tooling #2101, #2131, #2021, #2053.
   Verify each is still open before starting it.
6. **Gated on the maintainer** (unchanged): #1651 / `v0.5.0`, #1676, #120, #1829 / #1814 / #1815.

## How the last batches ran (keep doing)

- Route contained lanes (a crash guard, a marker re-point, a spec-only fix) to **Haiku**; Ruby
  semantics, cache soundness and reviews to **Opus**.
- A lane STOPS at any ADR-119 gate / census / producers / provenance-pin move and reports to the
  coordinator, who decides by precedent and adds an approval-queue entry; a row with no same-kind
  precedent still goes to the maintainer. Never reshape code to dodge a gate.
- `make verify-changed` does not run `ancestry_walker_detection_spec` or `producers_spec` on every
  change (#2053): lanes touching dispatch or discovery must run them by hand before pushing.
- An engine PR's "Engine allocations (advisory)" summary is a finding even when green. A red cut is
  usually several PRs' deltas summed: attribute each before blaming one (v0.4.5: #2051 was only
  the largest share).

## What bit

- Rules made "only as precise as provable" still put diagnostics on correct code when the
  fallback was wider than the fact (#2122, #2077). When a check declines, answer the narrowest
  sound type, and probe receivers that may be `self`.
- A cache lookup that hits without recording an edge is invisible until `--incremental` serves a
  stale result (#2121 → #2132, then #2133 / #2134 / #2137). Audit sibling lookups when fixing one.
- `tool/engine_diag_diff.rb --corpus-dir` under a worktree's `tmp/` can report a vacuous 1/1;
  confirm the base row count is non-trivial or diff direct JSON runs.
