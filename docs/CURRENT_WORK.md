<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This session's own lesson: two of its three findings were
  a *stale document*, not a bug — an issue whose premise had been disproven, and a note whose predicted
  fix had already landed unremarked. Re-measure before implementing against a written number.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **[#232](https://github.com/rigortype/rigor/pull/232) closed [#227](https://github.com/rigortype/rigor/issues/227)**:
  `sig-gen` reads `Data.define` / `Struct.new` classes, in the constant-assigned and the
  `class X < Data.define(...)` forms. It now emits the member accessors, a `.new` / `.[]` pair matching
  the constructor forms the class accepts, and the `::Data` / `::Struct[untyped]` ancestry — and it
  attributes a `do ... end` block's defs to the constant instead of the enclosing namespace. The
  implementation reads the ADR-48 member layouts `ScopeIndexer` already builds rather than
  re-recognising the syntax, so the two views cannot drift again (they had).
- **[#228](https://github.com/rigortype/rigor/issues/228) is closed "no"**: `RBS::Rewriter` is not
  worth adopting. Evaluation in
  [`docs/notes/20260730-rbs-rewriter-sig-gen-writer-evaluation.md`](notes/20260730-rbs-rewriter-sig-gen-writer-evaluation.md).
- **[#233](https://github.com/rigortype/rigor/pull/233) recalibrates the perf baseline** from 32.40M to
  23.52M `lib` allocations and teaches `make bench-perf` to say when its baseline has gone stale.

## Next session

Nothing is release-blocking. **[#233](https://github.com/rigortype/rigor/pull/233) is open** — merge it
before trusting any perf number, since the committed baseline is 27% too high until it lands.

The two v0.4.x decision items are unchanged and still `ready-for-human` — they need a call, not an
implementation:

- **[#204](https://github.com/rigortype/rigor/issues/204)** (area:engine) — wire ADR-46 cross-file
  caller→callee-param edges so `parameter_inference:` composes with `--incremental`. Needs the
  edge-recording design call.
- **[#205](https://github.com/rigortype/rigor/issues/205)** (area:engine) — decide whether to flip
  `parameter_inference:` on by default. Not before the protection evidence exists.

Agent-ready work, effort-ordered:

- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — **read the 2026-07-30 comment
  first; the issue's title and body describe work that no longer exists.** The RuleWalk lever is closed
  (all five #101 rules together are 0.24% of the run). What is left is `stub_missing_referenced_types`
  **pass 1**: it builds every project class with a throwaway `RBS::DefinitionBuilder`, costs 7.84M
  allocations — now **33% of the whole run** — and finds nothing once `sig/` is self-consistent. Two
  unmeasured directions are in the comment; direction 2 (static reference detection) carries genuine FP
  risk, because a false detection stubs a name that would have resolved and an empty stub shadowing a
  real type is worse than the fail-soft miss ADR-5 tier 2 exists to prevent.
- **[#229](https://github.com/rigortype/rigor/issues/229)** (area:plugins) — decide which inline-RBS
  implementation Rigor speaks. `rigor-rbs-inline` is built on the `rbs-inline` gem, but rbs 4.1's three
  new inline features landed in RBS's *built-in* `InlineParser`. ADR-93 default-wires the plugin, so this
  is the whole user base's dialect. Outcome belongs in an ADR-32 amendment. Note
  [ADR-94](adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md) already adjudicated the adjacent migration
  against narrowing the rbs floor — this is the *dialect* question, not the floor question.
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- The editor cluster **#142** / **#146** / **#147** — still the largest untouched `ready-for-agent`
  block in the v0.4.x milestone.

## What this session learned that is not in a commit

- **A stale document costs more than a missing one.** #207 was filed on a premise (five standalone rule
  walks) that was already false when filed; the 2026-07-25 attribution note then predicted a −24.2%
  drop from declaring `Inference::VoidOrigin` in `sig/`, that declaration landed four days later, and
  nobody recalibrated. Two sessions of perf reasoning were anchored to a number that had moved. Re-run
  the measurement before implementing against a written one.
- **A one-sided gate loses its teeth without ever going red.** The band is a percentage of the
  *baseline*, so an unrefreshed improvement widens the real ceiling: a 27% drop left the +5% allocations
  band permitting +44% over the true cost, reported as `OK` on the release run. Any gate defined
  relative to a committed number needs to notice drift in **both** directions.
- **Check that a documented procedure actually runs.** `bench/baseline.json` told you to commit the
  release-gate artifact's targets; `tool/bench.rb` only wrote that artifact when the baseline was
  *uncalibrated*, i.e. never when a refresh was wanted, and `if-no-files-found: ignore` hid the gap.
  The instruction had probably never worked.
- **Probe RBS spellings against `rbs validate`, not against recall.** A bare `< ::Struct` raises
  `InvalidTypeApplicationError` (`Struct[E]` is generic — arity 1 on both rbs 3.10 and 4.1, only the
  parameter's name differs), while parenthesised unions in named-positional position and members named
  `type` / `class` / `self` / `end` all validate. Cheap to check, and two of those were not what
  reasoning predicted.
- **Declaring a class narrows dispatch, which can manufacture false positives.** Going from no
  declaration to `class Point < ::Data` moves the receiver from `Dynamic` to a nominal, so everything the
  runtime synthesises but RBS does not declare starts reading as *missing*. `::Data.new` is `() -> bot`
  and `.[]` is undeclared upstream — emitting them is FP prevention, not completeness. Worth asking of
  any change that adds declarations.
