<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This session's instance: re-measuring #205's perf figure
  on the current tree (instead of citing the 11-day-old note) surfaced a live WD6b guard hole on the
  first codebase outside the landing corpus. The re-measurement WAS the discovery.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **Both v0.4.x decision items are resolved.**
  [#204](https://github.com/rigortype/rigor/issues/204) closed by
  [#235](https://github.com/rigortype/rigor/pull/235): `parameter_inference:` composes with
  `--incremental` via a **table diff**, not the edge recording the issue sketched — the pre-pass is
  whole-project by design, so the freshly recomputed table is ground truth and a missing invalidation
  edge is impossible by construction. Snapshot SCHEMA 10 → 11.
  [#205](https://github.com/rigortype/rigor/issues/205) closed **stays opt-in** — recorded as an
  ADR-67 addendum with the re-measured cost (+48% allocations / ~2× wall on our own `lib`, an order
  of magnitude over ADR-50's 5% band), and three re-evaluation triggers. The mutation oracle was
  deliberately not run: it gates the *yes* path.
- **[#236](https://github.com/rigortype/rigor/pull/236)** fixed the WD6b guard hole #205's
  re-measurement surfaced: `call.argument-type-mismatch` now declines on an inferred-param
  *receiver* (the method contract was resolved through a lower-bound type), not just an inferred
  argument. Found on the seventh codebase the gate ever ran against — our own.
- Earlier this session: [#227](https://github.com/rigortype/rigor/issues/227) (sig-gen reads
  `Data.define`/`Struct.new`), [#228](https://github.com/rigortype/rigor/issues/228)
  (`RBS::Rewriter` declined), [#229](https://github.com/rigortype/rigor/issues/229) (ADR-32
  WD11/WD12 — stay on the rbs-inline gem; unhonoured annotations now report), and the perf-baseline
  recalibration + staleness notice ([#233](https://github.com/rigortype/rigor/pull/233)).
- `make verify` green on merged master (8,323 examples); CHANGELOG carries all six Unreleased entries.

## Next session

Nothing is release-blocking and nothing is half-landed. The v0.4.x `ready-for-human` queue is empty —
what remains needs either implementation or investigation, not a maintainer call:

- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — **read the 2026-07-30
  comments first; the title and body describe closed work.** What is left is
  `stub_missing_referenced_types` **pass 1**: 7.84M allocations, **33% of a cold `check lib`**,
  building every project class with a throwaway `DefinitionBuilder` to find nothing once `sig/` is
  self-consistent. Direction 1 (share the builder) is measured and declined (−0.96%, cold-only).
  The only lever with headroom is static reference detection, and it carries genuine FP risk — a
  false detection stubs a name that would have resolved, worse than the fail-soft miss ADR-5 tier 2
  prevents. Start with an evaluation: does static detection agree with builder-based detection on a
  real corpus? Suggest retitling the issue to the pass-1 sweep first.
- The editor cluster **[#142](https://github.com/rigortype/rigor/issues/142)** /
  **[#146](https://github.com/rigortype/rigor/issues/146)** /
  **[#147](https://github.com/rigortype/rigor/issues/147)** — the largest untouched
  `ready-for-agent` block in the v0.4.x milestone (Ractor-pool publish dispatch, per-file diagnostic
  cache for whole-project scope, editor-mode throughput).
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- **Unfiled upstream report** (small, external): `rbs-inline`'s parser accepts
  `# @rbs module-self: Foo` (upstream's own documented spelling) and its writer then discards it —
  the defect behind ADR-32 WD12. Fixing it upstream helps every rbs-inline user; needs maintainer
  sign-off because it is an external filing.

## What this session learned that is not in a commit

- **Re-measure before deciding; the re-measurement can BE the discovery.** #205's decision could have
  been written from the 2026-07-19 figures. Running the A/B fresh on our own tree instead surfaced a
  live guard FP (#236) — the seventh codebase broke a guard six corpus targets had validated. A
  guard's clean corpus result is evidence about that corpus, not about the guard.
- **When a whole-input recompute is cheap enough to already exist, diff its output instead of
  recording dependency edges.** The #204 design: the param table is recomputed whole-project every
  run anyway, so diffing it against the snapshot's copy makes a missing invalidation edge impossible
  by construction — and caller-appears, caller-vanishes, fail-soft-empty all fall out of the same
  comparison. Edge recording would have had to handle each specially.
- **A stability gate can be the wrong oracle for a new invalidation source.** The ADR-89 WD2
  behavioural-stability pruning re-evaluates returns under the snapshot's *old* seeds — correct for
  body edits, wrong for seed changes, where the seeds are the thing that moved. New invalidation
  sources must be audited against every existing pruning gate they flow past.
- **Don't run an expensive check to support a decision already made on other grounds.** The mutation
  oracle gates default-on; the perf cost alone declined it. Running the campaign anyway would have
  been evidence theatre. Record it as the precondition it is, for the decision it actually gates.
- **`Rigor.dump_type` is the observation channel for seed-sensitive specs.** WD6b guards every
  negative rule on inferred-param values, so a seed change never adds a negative diagnostic — an
  oracle comparison without a positive channel is vacuous. `dump_type` prints the inferred type as
  an info diagnostic no guard touches.
