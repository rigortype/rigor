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

v0.3.6 shipped 2026-08-30. `[Unreleased]` carries **5 entries** (three Changed, two Fixed), all from
the 2026-08-31 session. **No autonomous version bumps** — the next cut needs an explicit ask.

## What landed 2026-08-31 (eight PRs)

The session started as "run Rigor over its own `lib` and find where types do not attach". Full
method, tables and caveats: [`docs/notes/20260831-self-check-type-coverage-audit.md`](notes/20260831-self-check-type-coverage-audit.md).

Engine — two live false positives and two precision tiers:
[#504](https://github.com/rigortype/rigor/pull/504) index `||=` / `&&=` / `+=` bypassing
`MutationWidening` (#501) · [#507](https://github.com/rigortype/rigor/pull/507) an ivar handed out by
a sibling method and filled through that alias (#506) ·
[#508](https://github.com/rigortype/rigor/pull/508) receiver-independent `Object` selectors (#503) ·
[#514](https://github.com/rigortype/rigor/pull/514) `Foo.instance` for the stdlib `Singleton` mixin.

Measurement and tooling: [#505](https://github.com/rigortype/rigor/pull/505) the precision lens's
discovery seed (#502) · [#511](https://github.com/rigortype/rigor/pull/511) the same for `type-scan` ·
[#510](https://github.com/rigortype/rigor/pull/510) the precision gate recalibrated 0.43 → 0.57 ·
[#515](https://github.com/rigortype/rigor/pull/515) `type-of` answers N positions per invocation and
makes the column optional.

Integrated master: `lib` precision 55.27% → 58.99%, `check` / `check-plugins` zero, and **redmine
792 → 792 / mastodon 2,341 → 2,341 diagnostics — no application gained or lost one.**

## Two findings worth more than the numbers

**A fold that types more expressions makes existing WRONG types reachable by the diagnostic rules.**
Prototyping #503 produced four diagnostics; none were caused by it. All four were live
mutation-shape false positives (#501, #506) that neither the gate nor the corpus had found. Put the
diagnostic count in the same table as the precision ratio, and expect a precision lever to be gated
on bugs it did not cause.

**A lever measured on this repository's own `lib` is calibrated against a type checker, not against
the programs Rigor is for.** The corpus inverted this session's own ranking twice: #508 is worth
+2.27pp here and +0.81 / +0.85pp on the two applications, while #505 — filed as a measurement
correction — carries +3.89 / +5.97pp there. And the cause mix is a different shape entirely:
`inferred_return_untyped` is 56.6% of `lib`'s unprotected sites against 27–30% on the applications,
where `unsupported_syntax` is 29.7% / 44.0% against 7.2% here. **Validate on the corpus before
ranking anything.**

## Closed — do not re-open without evidence against the specific claim

- **ADR-67 WD2** (in-body structural parameter inference) — closed by the 2026-07-06 design spike: no
  structural-interface carrier, a 23–29% ceiling, and a body-derived bound is circular for the
  protection metric. The spike's corpus already included `rigor-lib`.
- **ADR-67 WD3 default-on** — needs **all three** of that ADR's re-evaluation triggers; one is
  accumulated real-world opt-in usage, which no session can manufacture.
- **A cross-file `class_ivars` index** — 0 / 0 / 17 foreign ivar reads across the three codebases,
  and zero cross-file global / class-variable reads. The note's § "Follow-up" has the census.
- **Ivars as a lever of their own** — 79% of `lib`'s opaque ivar reads have a write whose own rvalue
  is a parameter. They are ADR-67's frontier seen one hop downstream.

## What is open

- **[#513](https://github.com/rigortype/rigor/issues/513)** — the precision lens seeds 2 of the 11
  discovery slots the check walk seeds, and `rigor coverage` builds a plugin-LESS environment while
  `--protection` does not. Measured: +0.77pp (mastodon) from the tables, ~1.2pp (redmine) from the
  environment. **This is why #514 moves `coverage` by +3 and the check walk by 365.** Re-check the
  0.57 gate in the same change.
- **[#512](https://github.com/rigortype/rigor/issues/512)** — `type-of` answers `Dynamic` for a
  cross-file constant. The obvious fix works and costs 2× (1.1 → 2.1 s) and took `cli_spec` past ten
  minutes, so it was withdrawn: it needs a cached seed, not a fresh whole-project parse.
- **[#147](https://github.com/rigortype/rigor/issues/147)** — the disk-backed `ProjectScan` snapshot
  cache. It is the shared answer to #512 and to the ~1.9 s floor #515 left, and the design pathway
  already exists (`docs/design/20260518-cli-disk-snapshot-cache.md`).
- The real remaining hole, from the corpus: **calls whose receiver the engine CAN name but whose
  dispatch still falls to `Dynamic`** — 47.4% / 50.3% of all `CallNode`s on redmine / mastodon
  against 9.8% on `lib`. Top pairs are `ActionController::Parameters#[]` (1,056), `Singleton[User]
  #current` (494, resolves to an untyped chain), `Singleton[X]#table_name`, `Singleton[Rails]#…`,
  `Constant#minutes`. Several are plugin territory rather than engine.
- Still open and independent: **#476**, **#460** (parked, v0.4.x), **#454**, **#435**.

## Pitfalls that still bind

- **Read a gate's exit code in its own call.** `make docs-check | tail` returns tail's 0. Run the
  gate after the LAST edit, merge resolutions included — two branches each opening a `###` section
  merge silently into a duplicated heading, and the changelog conformance spec is the only net.
- **When you add an output form to a CLI, verify the contract, not just the speed.** #515 shipped a
  review round because the enumeration printed Prism's 0-based column where the command's contract is
  1-based (and a spec pinned the wrong value), `group_by(&:file)` reordered results away from
  argument order, mixing exact and line queries rendered as one block, and the 40-row cap truncated
  silently. Run your own new form the way a user would before measuring how fast it is.
- **A PHASED A/B is not a control** for timings; `tool/perfbench/ab_probe_interleaved.sh` is the
  template. Deterministic counts (diagnostic sets, censuses) are exempt — say which you have.
- **A config's relative `paths:` resolve against the CONFIG file's directory**, and an
  `effects.envelopes[].match:` glob must be RELATIVE — both make a measurement vacuously green.
- **Running against a survey project** needs cwd = the target AND `BUNDLE_GEMFILE` = this repo's
  Gemfile; without the latter you load the target's own bundle and get a native-extension crash.
- **After an engine-moving merge, re-prime the diagnostics slot with a `check` run** — `unused` never
  writes it, so the next "warm check" measurement is silently a cold one.
