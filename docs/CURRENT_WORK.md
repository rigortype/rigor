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
- **The referenced-type stub pass is rebuilt, both halves, and merged.**
  - [#237](https://github.com/rigortype/rigor/issues/237) →
    [#238](https://github.com/rigortype/rigor/pull/238): stubs are emitted in the declaration kind each
    name requires (`interface` / `type` / `module` / `class`) and validated one at a time, so a dangling
    interface or type-alias reference no longer takes the whole batch down; the fixpoint also stops on a
    pass that appends nothing. herb — 74 dangling references, all type aliases — went from a **complete
    no-op** to 5 → 2 passes, −30.1% allocations, precise coverage 59.3% → 60.0%. Cache
    `SCHEMA_VERSION` 5 → 6.
  - [#207](https://github.com/rigortype/rigor/issues/207) →
    [#240](https://github.com/rigortype/rigor/pull/240): detection reads the project declarations and
    applies RBS's own membership test instead of building every project class. Pass 1: **7,841,785
    allocations / ~810ms → ~25k / ~9ms**. The builder sweep survives in spec as the oracle the walk must
    keep agreeing with. Diagnostic-identical, zero new firings, across the eight RBS-shipping corpus
    projects.
  - Evaluation behind both:
    [`docs/notes/20260730-stub-pass1-static-detection-evaluation.md`](notes/20260730-stub-pass1-static-detection-evaluation.md).
- **Perf baseline refresh is open in [#242](https://github.com/rigortype/rigor/pull/242).** Linux CI on
  merged master measures `check lib` at **15,769,515 allocations** (was 23,521,131, −33.0%), and the
  #233 staleness notice fired on the first run after the merge — the stale target left the +5% band
  permitting +57% over the real cost. Verified armed after the refresh, not merely quiet.
- **The changelogs now conform to Keep a Changelog 1.1.0**
  ([#241](https://github.com/rigortype/rigor/pull/241)). Six section types only, one per type per
  release, in the format's order — gated by `spec/docs/changelog_conformance_spec.rb` over
  `CHANGELOG.md` and every archive. There is **no `Performance` section**: a speed-up is `Changed`, a
  docs correction is `Fixed`. The rule was already in the `rigor-release-prep` skill and drifted anyway,
  which is why it is mechanical now.
- `make verify` (13 groups) and `make docs-check` (324 examples) green on merged master.

## Next session

- **[#239](https://github.com/rigortype/rigor/issues/239)** (`bug`, `ready-for-agent`) — a **false**
  `call.undefined-method`: on an RBS-known class whose method is not declared in `sig/`, an instance
  method masks a same-named `class << self` method, so `self.class.helper(1)` reads as undefined. The
  issue carries a minimal repro and a byte-identical control. False positives outrank everything else in
  the queue (AGENTS.md § Implementation Guidelines), and #240 had to route around this one.
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

- **A clean corpus result can be a silent harness failure.** Six of eight targets reported "both
  detectors found nothing". The 17-shape fixture built to force a positive produced the shape matrix, the
  bucket attribution, and both defects. Build the positive control before the corpus run, not after it
  disagrees.
- **`rescue <Error>; nil` around a batched synthesis is an availability bug.** Rigor's fail-soft
  discipline is per-unit, but `append_stub_declarations` batched N declarations into one parse, so the
  rescue degraded all N for one bad input. Any fail-soft rescue wrapping a batch needs the batch split,
  or the degradation is unbounded in the input.
- **A fixpoint that cannot make progress still burns its whole budget.** Bound it by progress; keep the
  iteration cap as a backstop.
- **Read the raise sites, don't infer them.** The static walk is only equivalent because
  `references/rbs` says exactly where `NoTypeFoundError` comes from — and three of the four resulting
  exclusions (`initialize`, the singleton side, interface-imported methods) were invisible from the
  outside. Each would have been a scope error.
- **A written rule with no gate is a temporary state.** The Keep a Changelog vocabulary was already in
  the release-prep skill and six `### Performance` sections accumulated anyway. Same shape as ADR-97's
  index budgets; the fix is a spec, not a firmer sentence.
- **`--config=PATH` resolves relative `paths:` against the config file's directory, not the cwd.** A
  scratch config outside the target silently analyses nothing (0.03s, one bogus diagnostic). Use absolute
  paths in a probe config.
- **`Rigor.dump_type` observes env-build differences too.** For a class that fails to build, the
  difference is `String` (from RBS) vs a body-inferred literal — visible in `dump_type`, invisible in the
  diagnostic count, since a fail-soft `Dynamic` only produces *fewer* diagnostics.
