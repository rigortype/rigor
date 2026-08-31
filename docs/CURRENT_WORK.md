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

## Where the cycle stands

v0.3.6 shipped 2026-08-30. `[Unreleased]` carries **3 entries** (one Changed, two Fixed), all from
the 2026-08-31 self-check audit below. **No autonomous version bumps** — the next cut needs an
explicit ask.

## The 2026-08-31 self-check audit — what landed, and what the corpus corrected

Ran Rigor over its own `lib` to find where types do not attach. Full method, tables and caveats:
[`docs/notes/20260831-self-check-type-coverage-audit.md`](notes/20260831-self-check-type-coverage-audit.md).
Four PRs, same day, in dependency order: [#504](https://github.com/rigortype/rigor/pull/504) (#501),
[#507](https://github.com/rigortype/rigor/pull/507) (#506),
[#505](https://github.com/rigortype/rigor/pull/505) (#502),
[#508](https://github.com/rigortype/rigor/pull/508) (#503). Integrated master: `lib` precision
55.27% → 58.98%, protection 45.8%, `check` / `check-plugins` zero.

**The reusable finding is not any number: a fold that types more expressions makes existing WRONG
types reachable by the diagnostic rules.** Prototyping the precision lever (#503) produced four
diagnostics; none were caused by it. All four were live false positives in mutation-shape
invalidation that neither the gate nor the corpus had found — `h[k] ||= v` bypassing
`MutationWidening` (#501), and an ivar handed out by a sibling method and filled through that alias
(#506). Put the diagnostic count in the same table as the precision ratio, and expect a precision
lever to be gated on bugs it did not cause.

**The corpus inverted the ranking, so validate there before ranking anything.** Redmine 792 → 792 and
mastodon 2,341 → 2,341 diagnostics: zero change, so all four are precision-additive on code we did
not write. But neutralising the tier on the merged tree gives it **+0.81 / +0.85pp** on the two
applications against +2.27 on our own `lib`, while the seeding fix — filed as a measurement
correction and ranked *below* it — carries **+3.89 / +5.97pp** there against +1.44 here. A lever
measured on this repository's `lib` is calibrated against a type checker, not against the programs
Rigor is for.

## Closed — do not re-open without evidence against the specific claim

- **ADR-67 WD2** (in-body structural parameter inference) — closed by the 2026-07-06 design spike: no
  structural-interface carrier, a 23–29% ceiling, and a body-derived bound is circular for the
  protection metric. The spike's corpus already included `rigor-lib`.
- **ADR-67 WD3 default-on** — needs **all three** of that ADR's re-evaluation triggers; one is
  accumulated real-world opt-in usage, which no session can manufacture. Measured for reference:
  `parameter_inference: true` takes `lib` opacity 41.09% → 37.81%.
- **A `check`-walk analogue of the #502 seed gap** — there is none. The runner seeds every cross-file
  `DiscoveryIndex` slot; the four it does not are per-file by construction, and a census over three
  codebases found 0 / 0 / 17 cross-file ivar reads and zero cross-file global / cvar reads. The
  note's § "Follow-up" has the table.

## What is actually left

- **Parameters remain the whole of the remaining opacity worth sizing** — 30.3% of it on the
  post-#508 tree (`def` parameters 17,246 + block parameters 3,490 of 68,336 opaque expressions),
  and both levers on them are the closed ones above. Re-measure against the note's attribution
  before proposing anything here.
- **`make check-coverage --threshold 0.43`** now gates a different number: `lib` reads 58.98% and the
  two corpus applications 47.8% / 48.9%. Whether to tighten it is an open, self-contained decision.
- **A larger population the ivar census surfaced**: 13–15% of all instance-variable reads are of an
  ivar with **no static write anywhere in the scanned tree** (380 / 394 / 635 across the three).
  `attr_writer`, `instance_variable_set`, framework assignment, or a write outside `paths:`. Bigger
  than anything seeding could reach, and unscoped.
- Still open and independent: **#476** (synthetic Tier B dead in production), **#460** (parked,
  v0.4.x), **#454** (decide before the #409 flip), **#435** (the `file:line` half of item 3).
- Perf: the 2026-08-25 campaign's named levers are spent; the surviving ranked list is in
  [`docs/notes/20260825-feature-warm-cold-corpus-perf.md`](notes/20260825-feature-warm-cold-corpus-perf.md).

## Pitfalls that still bind

- **Read a gate's exit code in its own call.** `make docs-check | tail` returns tail's 0. Run the
  gate after the LAST edit, merge resolutions included — the changelog conformance spec is the only
  net under `merge=union`, and two branches each opening a `###` section merge silently into a
  duplicated heading.
- **A PHASED A/B is not a control** for timings; `tool/perfbench/ab_probe_interleaved.sh` is the
  template. Deterministic counts (diagnostic sets, tier censuses) are exempt — say which you have.
- **A corpus that never fires cannot clear a widening.** Say whether a gate added zero firings
  because the change was safe or because the shape is absent.
- **A config's relative `paths:` resolve against the CONFIG file's directory**, and an
  `effects.envelopes[].match:` glob must be RELATIVE — both make a measurement vacuously green.
- **Running against a survey project** needs cwd = the target AND `BUNDLE_GEMFILE` = this repo's
  Gemfile; without the latter you load the target's own bundle and get a native-extension crash.
- **After an engine-moving merge, re-prime the diagnostics slot with a `check` run** — `unused` never
  writes it, so the next "warm check" measurement is silently a cold one.
