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

## State at 2026-10-17 (master after #2051)

**`v0.4.4` is released** (tag `v0.4.4`). The **`v0.4.5` milestone** has 51 open issues. A
v0.4.5 batch landed 20 PRs on master between #1999 and #2051. Each went through an Opus review,
and several needed fix rounds. The batch also ran lanes through the new push tooling:

- **`bin/lane-push`** (#2022) is the only push path for a lane's branch. It rebases onto a freshly
  fetched `origin/master`, runs `verify-changed` on the rebased tree, and refuses untracked files.
  It pushes with an explicit refspec and a lease. It accepts the branch's own earlier pushes through
  the reflog, and it refuses a remote commit the branch never had.
- `verify-changed` now runs every "flip this when #N" pinned example on an engine change
  (`tool/pin_examples.rb`, about 9 s).
- `RIGOR_REGENERATE_GATES=1` regenerates `producers.yml` and the admission census in place, and is
  a no-op on an unchanged tree (#2041).
- `docs/agents/parallel-lanes.md` now lists the three shapes behind this batch's severe rounds:
  - a block that changes `self`;
  - a sibling file defining the same name;
  - a statement that may not run.

  Step 7 re-gates a landing when either side touches the engine. The maintainer's rule: a branch
  need not contain `origin/master` to merge, but every push rebases onto it.

## Next

1. **`v0.4.5` milestone** (51 open). Re-check each premise on master before it enters a batch.
   Run at most two lanes at once; lens work runs in parallel sessions.
   Follow-ups this batch filed: #2002, #2005–#2013, #2018, #2020, #2021, #2023, #2025–#2027,
   #2030, #2031, #2033, #2034, #2037–#2040, #2042, #2044, #2046, #2048, #2050, #2052, #2053.
2. **#2021 blocks `verify-changed` on any branch that touches `rails_i18n.rb`**: `rigor check` on
   that file alone misreads its nested `Effects`. Until it is fixed, lanes push with
   `bin/lane-push --no-verify="#2021: …"` and leave the gate to CI.
3. **#2053**: `verify-changed` misses `ancestry_walker_detection_spec` on engine changes (CI caught
   it on #2051).
4. **Gated on the maintainer** (unchanged): #1651 / `v0.5.0`, #1676, #120, #1829 / #1814 / #1815.

## In flight (not this handoff's lanes)

- #2015 (lens), #1828 (refinement session), #1771 (reference only; do not resume as is).

## What bit

- Three PRs reached round 3 with a severe finding: #2000, #2016, #2036. #2036's last finding was
  in code added in round 1. The maintainer chose to drop that item (#2046) rather than open round 4.
- Removing a narrowing can itself report: on a nilable subject, "narrows nothing" keeps the nil
  (#2036 item 3). Check the nil path whenever a change widens a type.
- Two regressions only showed up on the real tree, not in fixtures:
  - #2035 crashed `rigor unused` on Rigor itself with an invalid-encoding `send` literal (fixed by #2047);
  - #2049's `base:` glob ignored the base for an absolute pattern.
  Run the command on this repository, not only on fixtures.
