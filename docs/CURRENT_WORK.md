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

## State at 2026-10-15 (master after #1913)

**`v0.4.3` is released** (2026-10-15, tag `v0.4.3` = `8ad379542`, RubyGems and GitHub Release), a
stabilization release: 41 merged PRs since `v0.4.2` (plus release PR #1912), every `v0.4.3` milestone issue closed, the
milestone closed. The perf-gate corpus now is `v0.4.3` (#1913); on the `v0.4.2` corpus the `v0.4.3`
engine measured +0.63% allocations, within band.

Fanned-out subagent work now follows `docs/agents/parallel-lanes.md` (#1903): premise check, a design
pass with an edge-case table for semantic changes, an overlap map, the lane and reviewer contracts
(mutation table, honest gates, claims limited to what specs pin), and landing on a merged master.

## Next

1. **`v0.4.4` milestone** (54 open, created 2026-10-15 by a triage session). Most of the review
   follow-ups filed during the `v0.4.3` batch sit there (#1885, #1889, #1891, #1895, #1898, #1900,
   #1902). Re-check each premise on master before it enters a batch (parallel-lanes step 1).
2. **#1651 gates `v0.5.0`**: recover ADR-119 C2-b1's typing loss or accept it. Measured levers:
   #1649 (only together with #1650, which needs an ADR-2 design), #1608, then C2-b2 and C2-d (#1604).
3. **Stale `--incremental` answers** still open: #1647, #1654, #1661, #1833, #1553, #1559, #1560.
4. **Decisions waiting on the maintainer:** #1676 (emit top-level defs as `class Object; private def`),
   #120 (an ADR for a default-capable `--incremental`), #1829 / #1814 / #1815 (refinement edges).

## In flight

- **#1828** (Draft since 2026-10-11, a refinement session's): a gem module read in full counts as a
  known refining module. Not this handoff's lane; leave it to its owner.
- **#1771** (Draft, reference only): five review passes each found a false positive from reading
  "no project file defines the name" as proof. #1715 records the shapes and two non-absence designs.
  Do not resume #1771 as is.
- **#1788** waits for an alba release that ships its `sig/` (merged upstream as
  okuramasafumi/alba#575, unreleased as of alba v4.0.0).

## What bit

- Specs that pass with the fix removed were the most common review finding (7 PRs in the `v0.4.3`
  batch); the lane contract's mutation table exists for this.
- Severe review rounds came from semantics the coordinator had not tabulated (symlinked paths,
  `Complex`, a half-fixed root cause); writing the edge-case table first is the fix.
- The `lens_spec` spec-order failure: see `docs/agents/measurement.md` § "Specs and gates that pass
  without checking".
