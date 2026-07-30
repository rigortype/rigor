<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This session's instance: the corpus reported "both detectors
  agree, zero names" on six of eight targets, which reads as agreement and was no evidence at all. The
  fixture built to force a positive is where both landed defects came from.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **[#237](https://github.com/rigortype/rigor/issues/237) landed** ([#238](https://github.com/rigortype/rigor/pull/238), merged). Referenced-type stubs are now
  emitted in the declaration kind each name requires (`interface` / `type` / `module` / `class`) and
  validated one at a time, so a dangling interface or type-alias reference no longer takes the whole stub
  batch down with it; the fixpoint also stops on a pass that appends nothing. herb — 48 signature files,
  74 dangling references, all type aliases — went from a **complete no-op** (byte-identical to stubbing
  nothing) to 5 → 2 passes, −30.1% allocations, precise coverage 59.3% → 60.0%. Cache
  `SCHEMA_VERSION` 5 → 6 so stale envs rebuild.
- **[#207](https://github.com/rigortype/rigor/issues/207) is implemented and open for review in
  [#240](https://github.com/rigortype/rigor/pull/240).** Detection reads the project declarations and
  applies RBS's own membership test instead of building every project class: pass 1 falls from
  **7,841,785 allocations / ~810ms to 24,661 / ~9ms**, the whole cold `check lib` from 23.81M to 16.03M
  (**−32.7%**), conference-app −83.6%. The builder sweep survives in spec as the oracle the walk must keep
  agreeing with. Diagnostic-identical with zero new firings across the eight RBS-shipping corpus projects.
- Evaluation behind both:
  [`docs/notes/20260730-stub-pass1-static-detection-evaluation.md`](notes/20260730-stub-pass1-static-detection-evaluation.md)
  (carries a same-day correction: project interfaces are outside the implemented scope, because the
  builder does not report their dangling references either).
- **[#239](https://github.com/rigortype/rigor/issues/239) is a new FP**, surfaced by Rigor's own
  `make check` while landing #207: on an **RBS-known** class whose method is not declared in `sig/`, an
  instance method **masks a same-named `class << self` method**, so `self.class.helper(1)` reports a false
  `call.undefined-method`. Minimal repro + a byte-identical control in the issue. #240 sidesteps it rather
  than depending on the fix.

## Next session

- **Review / merge [#240](https://github.com/rigortype/rigor/pull/240)**, then re-run
  `make bench-perf` — the perf baseline was recalibrated on 2026-07-29 to 23.52M allocations for
  `check lib` and this change takes ~7.8M off it, so the baseline needs a deliberate refresh (see
  [#233](https://github.com/rigortype/rigor/pull/233) for the refresh path, and note the suggested-baseline
  artifact is only produced for an *uncalibrated* baseline).
- **[#239](https://github.com/rigortype/rigor/issues/239)** (`bug`, `ready-for-agent`) — a false
  `call.undefined-method` on ordinary Ruby. Likely in whatever records `class << self` bodies into the
  discovered-methods table, where the instance-side entry displaces the singleton-side one.
- The editor cluster **[#142](https://github.com/rigortype/rigor/issues/142)** /
  **[#146](https://github.com/rigortype/rigor/issues/146)** /
  **[#147](https://github.com/rigortype/rigor/issues/147)** — the largest untouched `ready-for-agent`
  block in v0.4.x. #146 has the user-visible value and needs no new machinery (wire editor mode onto
  ADR-46's `dependents` index + per-file cache).
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- **Unfiled upstream report** (small, external): `rbs-inline`'s parser accepts
  `# @rbs module-self: Foo` and its writer then discards it — the defect behind ADR-32 WD12. Needs
  maintainer sign-off because it is an external filing.

## What this session learned that is not in a commit

- **A clean corpus result can be a silent harness failure.** Six of eight targets reported "both detectors
  found nothing". The 17-shape fixture built to force a positive produced the shape matrix, the bucket
  attribution, and both defects. Build the positive control before the corpus run, not after it disagrees.
- **`rescue <Error>; nil` around a batched synthesis is an availability bug.** Rigor's fail-soft discipline
  is per-unit, but `append_stub_declarations` batched N declarations into one parse, so the rescue degraded
  all N for one bad input. Any fail-soft rescue wrapping a batch needs the batch split, or the degradation
  is unbounded in the input.
- **A fixpoint that cannot make progress still burns its whole budget.** `MAX_STUB_PASSES.times` had no
  progress check, so the pathological input cost 5× the healthy one. Bound a fixpoint by progress and keep
  the cap as a backstop.
- **Read the raise sites, don't infer them.** The static walk is only equivalent because
  `references/rbs` says exactly where `NoTypeFoundError` comes from: `validate_type_presence` on ancestor
  type *args*, and `VarianceCalculator#type` on method types — which skips `initialize`, never runs for the
  singleton side, and does not walk interface-imported methods. Three of those four exclusions were
  invisible from the outside and each one would have been a scope error.
- **`--config=PATH` resolves relative `paths:` against the config file's directory, not the cwd.** A
  scratch config outside the target silently analyses nothing (0.03s, one bogus diagnostic). Use absolute
  paths in a probe config.
- **`Rigor.dump_type` observes env-build differences too.** For a class that fails to build, the difference
  is `String` (from RBS) vs a body-inferred literal — visible in `dump_type`, invisible in the diagnostic
  count, since a fail-soft `Dynamic` only produces *fewer* diagnostics.
