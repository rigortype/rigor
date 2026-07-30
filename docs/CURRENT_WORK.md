<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This session's lesson, three times over: two issues were
  filed on premises that had since become false, and one of this session's own findings was wrong
  until re-measured. Re-run the measurement before implementing against a written number.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **[#227](https://github.com/rigortype/rigor/issues/227) closed** by
  [#232](https://github.com/rigortype/rigor/pull/232): `sig-gen` reads `Data.define` / `Struct.new`
  classes in both the constant-assigned and `class X < Data.define(...)` forms, emitting the member
  accessors, a `.new` / `.[]` pair matching the constructor forms the class accepts, and the
  `::Data` / `::Struct[untyped]` ancestry. It reads the ADR-48 member layouts `ScopeIndexer` already
  builds rather than re-recognising the syntax, so the two views cannot drift again — they had.
- **[#228](https://github.com/rigortype/rigor/issues/228) closed "no"**: `RBS::Rewriter` is not worth
  adopting ([note](notes/20260730-rbs-rewriter-sig-gen-writer-evaluation.md)).
- **[#229](https://github.com/rigortype/rigor/issues/229) closed**:
  [ADR-32](adr/32-rbs-inline-comment-ingestion.md) WD11 keeps the `rbs-inline` gem as the reader, and
  WD12 makes a parsed-but-unhonoured annotation report instead of vanishing
  ([#234](https://github.com/rigortype/rigor/pull/234)). Grounded in the measured grammar diff,
  [`notes/20260730-inline-rbs-parser-grammar-diff.md`](notes/20260730-inline-rbs-parser-grammar-diff.md).
- **The perf baseline is recalibrated** ([#233](https://github.com/rigortype/rigor/pull/233)) from
  32.40M to 23.52M `lib` allocations, and `make bench-perf` now says when its baseline has gone stale.

## Next session

Nothing is release-blocking, and nothing is half-landed.

**One thing is queued but not filed**: an upstream `rbs-inline` bug report — its parser accepts an
annotation (`# @rbs module-self: Foo`) that its own writer then discards. Fixing it upstream would
close the gap for every rbs-inline user rather than only Rigor's, which beats our downstream
mitigation. Left for the maintainer because it is an external filing.

The two v0.4.x decision items still need a call, not an implementation:

- **[#204](https://github.com/rigortype/rigor/issues/204)** (area:engine) — wire ADR-46 cross-file
  caller→callee-param edges so `parameter_inference:` composes with `--incremental`. Needs the
  edge-recording design call.
- **[#205](https://github.com/rigortype/rigor/issues/205)** (area:engine) — decide whether to flip
  `parameter_inference:` on by default. Not before the protection evidence exists.

Agent-ready work, effort-ordered:

- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — **read the 2026-07-30
  comments first; the title and body describe work that no longer exists.** The RuleWalk lever is
  closed (all five #101 rules together are 0.24% of the run) and direction 1 is measured and declined
  (sharing pass 1's `DefinitionBuilder` recovers −0.96%, cold runs only — on a cache hit
  `build_env_for` never runs). What is left is `stub_missing_referenced_types` **pass 1**: 7.84M
  allocations, **33% of the run**, building every project class to find nothing once `sig/` is
  self-consistent. The only direction with real headroom is static reference detection, and it carries
  genuine FP risk — a false detection stubs a name that would have resolved, and an empty stub
  shadowing a real type is worse than the fail-soft miss ADR-5 tier 2 exists to prevent. A design call.
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- The editor cluster **#142** / **#146** / **#147** — still the largest untouched `ready-for-agent`
  block in the v0.4.x milestone.

## What this session learned that is not in a commit

- **A stale document costs more than a missing one, and it happened three times.** #207 was filed on a
  premise already false when filed. The 2026-07-25 attribution note predicted a −24.2% drop from a
  `sig/` fix that landed four days later, and nobody recalibrated, so two sessions of perf reasoning
  were anchored to a number that had moved. #229 listed three rbs 4.1 features as gaps; two were not.
- **Test a dialect's syntax against that dialect.** The `module-self` row of the inline-parser diff was
  reported backwards because the snippet was written in the built-in's spelling and run against the
  gem — after the note's own Method section warned about exactly that. Corrected finding: both support
  the feature, in incompatible spellings, and the gem's failure mode is the silent one.
- **A one-sided gate loses its teeth without ever going red.** The perf band is a percentage of the
  *baseline*, so an unrefreshed improvement widens the real ceiling — a 27% drop left the +5%
  allocations band permitting +44% over the true cost, reported as `OK` on the release run. Any gate
  defined relative to a committed number needs to notice drift in **both** directions.
- **Check that a documented procedure actually runs.** `bench/baseline.json` said to commit the
  release-gate artifact's targets; `tool/bench.rb` only wrote that artifact when the baseline was
  *uncalibrated*, i.e. never when a refresh was wanted, and `if-no-files-found: ignore` hid the gap.
- **Declaring a class narrows dispatch, which can manufacture false positives.** Going from no
  declaration to `class Point < ::Data` moves the receiver from `Dynamic` to a nominal, so everything
  the runtime synthesises but RBS does not declare starts reading as *missing*. `::Data.new` is
  `() -> bot` and `.[]` is undeclared upstream — emitting them is FP prevention, not completeness.
  Worth asking of any change that adds declarations.
- **Probe RBS spellings against `rbs validate`, not against recall.** A bare `< ::Struct` raises
  `InvalidTypeApplicationError` (`Struct[E]` is generic — arity 1 on both rbs 3.10 and 4.1, only the
  parameter's name differs), while parenthesised unions in named-positional position and members named
  `type` / `class` / `self` / `end` all validate.
