<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This session's instance: the corpus said "both detectors
  agree, zero missing names" on six of eight targets — and that agreement was vacuous until a fixture
  proved the harness could report a name at all. The fixture is where both real defects came from.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **[#207](https://github.com/rigortype/rigor/issues/207)'s open question is answered.** Static
  dangling-reference detection **agrees** with the builder-based `unresolved_referenced_types` sweep
  when scoped to the positions the builder actually validates: no detection lost on any of eight real
  projects or three fixtures, diagnostics digests identical across arms on all ten targets, and pass 1
  drops from **7,841,785 to 21,257 allocations — −32.8% of a cold `check lib`** (−83.6% on a
  Rails-shaped project). Measurements:
  [`docs/notes/20260730-stub-pass1-static-detection-evaluation.md`](notes/20260730-stub-pass1-static-detection-evaluation.md);
  verdict and numbers also on the issue, which is retitled to the pass-1 scope.
  - The scope is not a free parameter: applying the wider sweep (types appearing only in `initialize` /
    a singleton method / an `@ivar:`) changes no diagnostic and costs **+11.3%** allocations on
    binpacker. Restrict to the parity buckets.
- **[#237](https://github.com/rigortype/rigor/issues/237) is new, and lands before #207.** The
  evaluation surfaced two live defects in the stub *synthesis* half: `append_stub_declarations` emits
  `class <name>` for every missing name in one buffer, so a dangling **interface** (`_Foo`) or
  **type-alias** (`foo`) reference makes the parse fail and `rescue RBS::BaseError` drop the entire
  batch — and the fixpoint then re-detects the same set until `MAX_STUB_PASSES` is exhausted. On
  **herb** all 74 missing names are dangling type aliases, so the pass is a **complete no-op** while
  costing +3.11M allocations (44% of its cold run). Fix shape is measured: −30.1% allocations, 5 → 2
  passes, precise coverage 59.3% → 60.0%, diagnostics unchanged.
- Earlier: [#204](https://github.com/rigortype/rigor/issues/204) /
  [#205](https://github.com/rigortype/rigor/issues/205) resolved,
  [#236](https://github.com/rigortype/rigor/pull/236) (WD6b receiver guard),
  [#227](https://github.com/rigortype/rigor/issues/227),
  [#228](https://github.com/rigortype/rigor/issues/228),
  [#229](https://github.com/rigortype/rigor/issues/229),
  [#233](https://github.com/rigortype/rigor/pull/233).
- `make docs-check` green (310 examples). No code changed this session — the deliverable is the
  evaluation, the note, and the two issue updates.

## Next session

- **[#237](https://github.com/rigortype/rigor/issues/237)** (`bug`, `ready-for-agent`) — implement the
  measured fix: per-name declaration kind (`interface` / `type` / `module` / `class`), per-declaration
  validation so one bad name cannot poison the batch, and a loop break when a pass appends nothing.
  Check whether the env cache's `SCHEMA_VERSION` needs a bump (the stub set rides in the cached env,
  ADR-54). Corpus FP diff over the survey targets — the probe already showed all seven
  diagnostics-identical, so a regression there is a real signal.
- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — then replace pass 1's builder
  sweep with the parity-scoped static walk. The note's § "Method" names the exact rbs raise sites the
  walk mirrors (`definition_builder.rb:219/237/283`, `variance_calculator.rb:158`, and the
  `initialize` skip at `definition_builder.rb:529`), which is the specification for the implementation.
  Keep the builder sweep as a spec-level oracle, not a runtime path.
- The editor cluster **[#142](https://github.com/rigortype/rigor/issues/142)** /
  **[#146](https://github.com/rigortype/rigor/issues/146)** /
  **[#147](https://github.com/rigortype/rigor/issues/147)** — still the largest untouched
  `ready-for-agent` block in v0.4.x. #146 is the one with user-visible value and no new machinery
  (wire editor mode onto ADR-46's `dependents` index + per-file cache).
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- **Unfiled upstream report** (small, external): `rbs-inline`'s parser accepts
  `# @rbs module-self: Foo` and its writer then discards it — the defect behind ADR-32 WD12. Needs
  maintainer sign-off because it is an external filing.

## What this session learned that is not in a commit

- **A clean corpus result can be a silent harness failure.** Six of eight targets reported "both
  detectors found nothing", which reads as agreement and is actually no evidence at all. The 17-shape
  fixture that forced a positive is what produced the shape matrix, the bucket attribution, *and* both
  #237 defects. Build the positive control before running the corpus, not after it disagrees.
- **`rescue RBS::BaseError; nil` around a batched synthesis is an availability bug.** Rigor's fail-soft
  discipline is per-unit; `append_stub_declarations` batches N units into one parse, so the rescue
  degrades all N for one bad input. Any fail-soft rescue wrapping a batch needs the batch split, or the
  degradation is unbounded in the input.
- **A fixpoint that cannot make progress still burns its whole budget.** `MAX_STUB_PASSES.times` has no
  progress check, so the pathological case costs 5× the healthy one. Bound a fixpoint by *progress*,
  and keep the iteration cap only as a backstop.
- **`--config=PATH` resolves relative `paths:` against the config file's directory, not the cwd.** A
  scratch config outside the target silently analyses nothing (0.03s, one bogus diagnostic). Use
  absolute paths in a probe config.
- **`Rigor.dump_type` is the right observation channel for env-build differences too.** For a class that
  fails to build, the difference is `String` (from RBS) vs a body-inferred literal — visible in
  `dump_type` output, invisible in the diagnostic count, since a fail-soft `Dynamic` merely produces
  *fewer* diagnostics.
