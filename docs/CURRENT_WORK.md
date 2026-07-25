<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This cut's own lesson: two of the three issues picked up
  this session had premises that did not survive contact with the filesystem. Check that the shape an
  issue describes still exists before implementing against it — `ready-for-agent` labels the
  readiness of the description, not of the premise.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.0 is released** (2026-07-19); `CHANGELOG.md` `[Unreleased]` has since accumulated entries
  under Changed / Fixed / Performance. No version bump is due — releases wait for an explicit ask.
- **The 2026-07-25 session landed five PRs**, all merged: #210 (fold the last standalone rule walk),
  #212 (ADR-92 WD6 gate), #213 (the internal-spec sweep, 31 findings), #214 (sig-gen nested update
  path), #215 (producer-declared cache generation cap). Issues #151, #153, #163, #211 closed.
- `make verify` (8,199 examples) / `make docs-check` clean on master.

## Next session

Nothing is release-blocking. The two v0.4.x items that remain are **both `ready-for-human`** — they
need a decision, not an implementation:

- **[#204](https://github.com/rigortype/rigor/issues/204)** (area:engine) — wire ADR-46 cross-file
  caller→callee-param edges so `parameter_inference:` composes with `--incremental` (lifts the WD6c
  mutual exclusion). Needs the edge-recording design call.
- **[#205](https://github.com/rigortype/rigor/issues/205)** (area:engine) — decide whether to flip
  `parameter_inference:` on by default (ADR-50 gate; needs accumulated protection evidence plus a
  mutation-oracle honesty check on the WD6b guard). Not before the evidence exists.

Agent-ready work, effort-ordered:

- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — the scope has changed: the
  traversal-sharing lever is exhausted (−0.49% was all of it), so what remains is **per-collector
  allocation attribution** to find where the v0.3.0 +45.7% drift actually lives. It is the #101 rule
  bodies and #102 Hash/Kernel typing doing real per-node work, not duplicated walks. An
  investigation, not a refactor.
- **[#216](https://github.com/rigortype/rigor/issues/216)** (area:perf) — `evict!` leaves empty shard
  directories behind forever (57 dirs for 16 live entries in one real cache). One-line fix,
  inode-only impact.
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- The editor cluster (**#144** / **#142** / **#146** / **#147**) is the largest untouched
  `ready-for-agent` block in the v0.4.x milestone.

## What this session learned that is not in a commit

- **An issue's premise is not evidence.** #207 said five rules ran standalone walks; four had been
  `RuleWalk`-hosted since the day they landed. #163's ADR-92 class recurred once in fourteen
  documents while a *different* class accounted for most of the findings. Ten minutes of
  `git log --diff-filter=A` and `rg` answered both. Check first, then implement.
- **A mechanical rename can invert prose.** ADR-80's `type_specifier` → `narrowing_facts` sweep
  rewrote the parenthetical that named the *removed* surfaces, so `plugin.md` spent a release telling
  plugin authors that the three live, drift-pinned APIs had been deleted. Search-and-replace cannot
  distinguish a name being used from a name being quoted as removed — grep for a rename's old name in
  prose afterwards, and read each hit.

## Also open, lower priority

- `static.value-use.top`, `static.incomplete-inference.*` (ADR-100 / ADR-41 / #158) stay reserved.
- The next release (`0.3.1`) is the first to trigger the CHANGELOG archival rule — it moves the
  `0.2.x` cycle into `docs/CHANGELOG-0.2.x.md` (the `rigor-release-prep` skill has the procedure).

## Waiting on the user / external

- The dependabot rubocop **PR #86** stays deliberately held (upstream autocorrect bug).
- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs`; push + upstream PR are the user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork.
- **rigor-rs:** `rigor_rs.ruby` reserved in our schema (ADR-99); harness re-pinned, battery clean.
