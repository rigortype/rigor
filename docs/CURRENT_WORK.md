<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Last session's own "next unaudited sections" pointer was wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Next session: cut v0.3.6

`[Unreleased]` carries **16 entries** across Changed and Fixed. **No autonomous version bumps** — this
needs an explicit ask. Two things the release note must say, because a user meets both without asking:

- the effect **snapshot schema moved 1 → 2**, so a committed `.rigor-effects.yml` reports one
  `regeneration: schema: 1 → 2` line on the next `rigor effects check` and needs one `update`;
- **every diagnostic line now ends with its rule identifier** in brackets, which changes what CI logs
  and screenshots look like even though nothing about the analysis moved.

## The pre-release issue sweep (2026-08-26/27) — six closed, all measured

Every one of these turned out to be something other than what its issue said, which is the reusable
part: **the issue's own diagnosis was wrong or incomplete in five of six cases.**

- **#449** (#485) — not one missing overlay row but **twelve**: the ADR-72 overlay had drifted from its
  plugin twin since #437. A parity spec pins the two surfaces, parsing with RBS because a regex over
  `def` lines cannot see nesting and reported parity while `ERB::Util` was missing.
- **#427** (#486) — the lockfile blindness was real, but a FULLY warm arm never loads
  `rbs.environment` either, so the issue's own priming proposal would have moved the arm from one
  blind state to another. It now primes *and drops the whole-run slot*;
  `tool/warm_cache_assertion.rb` asserts the environment was served.
- **#431** (#487) — the formatter was never id-less; it has carried `[qualified.rule]` for every
  family EXCEPT builtin since v0.1.0, so the fix removed an exception rather than adopting a
  convention. Cost measured first: 13 distinct ids on redmine, +14 chars on a 165-char median line.
- **#370** (#489) — the "design question this needs answered first" was already answered by the tier
  contract in internal-spec. Applying it alone would have shipped a regression (80 spurious rows on
  mastodon): a data-file mention and an interpolated `constantize` shared one carrier shape, so
  "Administrasie" in a locale file demoted 18 `Admin::*` rows. `DynamicUse` carries a `scope` now,
  which also fixed a live defect nobody had filed — "Redmine" in a YAML was demoting 47 rows out of
  `candidates`.
- **#488** (#490) — all five plugin pages' example blocks were stale in three ways at once, one of
  them never accurate. Rewritten from each plugin's own `demo/`, matched on message text. The guard is
  static by a **measured** choice: the execution version costs 6.3 s on `make verify` against a
  monthly drift rate.
- **#430** (#491) — **284** dead links across 66 shipped docs, an order of magnitude over the
  estimate, and that number picked the option: shipping the specs is +30 % gem size and still leaves
  128, replacing each pointer is a docs rewrite. All now name canonical URLs, with a gate that
  resolves against the **packaged** file list and a second assertion restoring the coverage the
  rewrite would have removed.
- **#420** (#492) — adjudicated silent, no behaviour change. `Object.new` and a `() -> Object`
  declared method carry the identical `Object`, so convergence fires on correct code. The corpus gate
  ran and is recorded as **unable to decide** (0/2/0/0 baseline, +0) rather than as a clearance.

Still open and independent: **#476** (synthetic Tier B is dead in production —
`project_pre_passes` passes `environment: nil` while the env consumes the scanner's output; two-phase
env, lazy resolution, or retire the tier, and whichever lands removes #477's gate), **#460** (parked
— v0.4.x), **#454** (decide before the #409 flip), **#435** (the `file:line` half of item 3 only — a
decision, and its comment carries the three options plus why the line costs the warm probe).

## The 2026-08-25 warm/cold perf campaign (all merged, master green after integration)

What do the NON-check surfaces cost warm? Note:
`docs/notes/20260825-feature-warm-cold-corpus-perf.md`; harness on branch
`perfbench-harness-20260825`; memory `project_feature_warm_perf_campaign_20260825`.

`rigor unused` 8.4 → ~1.1 s on mastodon (#473 cache reuse + narrowed template scan, #481
`Reachability::ScanCache`). Effects: the whole-run entry stores the propagated table (#475), the
synthetic scan short-circuits when trait registries cannot emit (#477), a per-run validation-stat memo
(#478), and the cold `effects` +41 % cell was YJIT — only check/coverage armed the deadline, now every
command does (#480). **#474** was the one correctness find: `%a(pure)` and every other non-brace RBS
spelling was invisible to `ANNOTATION_HINT`, so the probe served the fast path while a bound existed —
the #428 family reached through an orthography.

**#483 / ADR-104 (Accepted, implemented)** — `Analysis::EffectsCacheProbe` serves `rigor effects` and
the four snapshot verbs with **zero** engine features in `$LOADED_FEATURES`; #482's two-entry split
landed in the same slice. Interleaved A/B ×3: effects redmine 0.76 → 0.50 s, mastodon 0.93 → 0.58 s.
**#484** — the snapshot surface: a regeneration event withholds the per-symbol diff it was documented
as unable to compare, `unresolved:` became a count at schema 2 (redmine 326,964 → 197,968 bytes), and
`explain` expands `exhaustive → not` by naming the causes the record stopped keeping.

## Next perf levers, evidence-ranked (do not re-derive; the note has the numbers)

The campaign's named levers are spent. Integrated warm floor on merged master (`db0cf0ab`):
redmine check 0.31 / effects 0.47 / effects check 0.46 / unused 0.72 s; mastodon 0.39 / 0.49 /
0.51 / 1.05 s. What is left is smaller and needs attribution before code:

1. **Environment restore at scale** — 0.83 s on gitlab warm, unattributed below
   `Environment.for_project`; sub-attribute before touching (RbsDescriptor digest vs Marshal vs
   lockfile resolve). The only remaining item measured in whole seconds.
2. **`fresh?` scope hoist** for the probe-decline `check` path needs a `with_run` inheritance
   flag — nesting installs a fresh table by design (coverage_mutation relies on it).
3. **`unused`'s residue** is now graph + plugin roots + boot, all sub-100 ms on the corpus; the
   per-file work is cached. Nothing here is worth a slice on its own.

## Pitfalls that still bind

- **Read a gate's exit code in its own call.** `make docs-check | tail` returns tail's 0; the
  changelog conformance spec is not in `docs-check`, so run the gate after the LAST edit, merge
  resolutions included.
- **A PHASED A/B is not a control.** "All of master, then all of the branch" reported a 45 % redmine
  regression that did not exist; alternating arms rep by rep showed −34 %.
  `tool/perfbench/ab_probe_interleaved.sh` is the template.
- **A corpus that never fires cannot clear a widening.** #420's gate added zero firings because the
  shape is absent from the corpus, not because the change was safe. Say which one it is.
- **After an engine-moving merge, re-prime the diagnostics slot with a `check` run** — `unused` never
  writes it, so the next "warm check" measurement is silently a cold one.
- **A config's relative `paths:` resolve against the CONFIG file's directory**, and an
  `effects.envelopes[].match:` glob must be RELATIVE — both make a measurement vacuously green.
- **GitHub Actions can wedge a run before it is queued** (2026-08-26): `updated_at` never moves, the
  cancel API answers 409 "not been queued yet" while `status` reads `queued`, and a force-push creates
  no new run because the concurrency group is held. Check githubstatus before debugging the workflow.
