<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This cut's own lesson: the release-gate perf failure
  read like a regression but was legitimate feature drift (54 merges after a mid-cycle baseline) —
  confirmed by an FP-clean OSS sweep before the baseline was recalibrated, not blessed blind.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.0 is released** (2026-07-19): tag `v0.3.0`, RubyGems, and the GitHub Release are all live;
  master is at the merged release commit and `CHANGELOG.md` `[Unreleased]` is empty. The cut sealed
  75+ entries (perf-arc-led summary), bumped the version, and **recalibrated `bench/baseline.json`**
  for the cut — the release-gate perf failure was legitimate default-on feature drift
  (`lib` self-check allocations 22.24M → 32.40M across ~54 post-baseline merges, chiefly the #101
  default rules and #102 Hash/Kernel typing), FP-clean on the OSS Mastodon sweep.
- **The 2026-07-19 survey iteration shipped inside v0.3.0**: #162 transitive `static.value-use.void`
  (`VoidTailSummary`), #194 auto-wire version-skew guard (ADR-93 WD5, three slices), probe/check
  environment parity (#196), ADR-58 massign ivar seeding (#201), and ADR-67 WD6 opt-in call-site
  parameter inference (#202) + its pre-pass perf pass (#203). Net protection lift +198 sites, zero
  new false positives.
- `make verify` / `make docs-check` clean on master.

## Next session — the v0.4.x backlog (all filed as issues)

Nothing is release-blocking; pick by interest. Effort-ordered:

- **[#163](https://github.com/rigortype/rigor/issues/163)** (`ready-for-agent`, area:docs) — **first
  pass landed (`e7a7e8ee`); the three large documents remain.** ADR-92's probe was applied to the 14
  unswept `docs/internal-spec/` documents: five divergences marked (ledger:
  [`docs/notes/20260725-internal-spec-status-fidelity-sweep.md`](notes/20260725-internal-spec-status-fidelity-sweep.md)).
  `inference-engine.md` / `plugin.md` / `cache.md` got the enumerated-surface and status-claim pass
  but not a line-by-line read — that is the next slice. The sweep's own finding is that the dominant
  drift class is **not** ADR-92's: it is a version-anchored future tense the release outran, now
  filed with a gate proposal as **[#211](https://github.com/rigortype/rigor/issues/211)**
  (`ready-for-agent`).
- **[#207](https://github.com/rigortype/rigor/issues/207)** — **PR #210 merged.** The issue's premise
  was stale: the five #101 rules were already `RuleWalk`-hosted (or comment-based). The one rule
  still re-traversing every file was `static.value-use.void`; folding it in was byte-identical and
  worth −158k allocations (−0.49%). That exhausts the traversal-sharing lever — the v0.3.0 +45.7%
  drift is the rule bodies and #102 typing doing real per-node work, so the follow-up is
  per-collector allocation attribution, not more folding. Baseline deliberately left alone (0.5% is
  inside the threshold's noise band). The issue stays open for that call.
- **[#204](https://github.com/rigortype/rigor/issues/204)** (`ready-for-human`, area:engine) — wire
  ADR-46 cross-file caller→callee-param edges so `parameter_inference:` composes with `--incremental`
  (lifts the WD6c mutual exclusion). Needs the edge-recording design call.
- **[#205](https://github.com/rigortype/rigor/issues/205)** (`ready-for-human`, area:engine) — decide
  whether to flip `parameter_inference:` on by default (ADR-50 gate; needs accumulated protection
  evidence + a mutation-oracle honesty check on the WD6b guard). Not before the evidence exists.
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).

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
