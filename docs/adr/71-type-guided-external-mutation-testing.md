# ADR-71 — Type-guided external incremental mutation testing

Status: **Proposed — deferred / demand-gated; nothing implemented.** Evaluates whether
Rigor's mutation substrate should grow into an **external** library that drives RSpec /
minitest as a smarter mutation-testing framework, pruning the mutation space with Rigor's
type information and cross-file dependency graph. Verdict: **defer.** The headline pitch
("types prune the mutation space → smarter/faster than ordinary mutation testing") is
**overstated**; the surviving, genuinely-novel wedge is **incremental / CI-scoped** mutation
testing built on [ADR-46](46-incremental-dependency-graph.md), not smart pruning. Build only
when demand and ADR-46 both arrive.

Grounding: [`docs/notes/20260617-type-guided-mutation-testing-strategy.md`](../notes/20260617-type-guided-mutation-testing-strategy.md)
(the full two-sided analysis — expansive and critical — this records the verdict of).

## Context

The maintainer's hope: a mutation tester that, instead of the genre's "shotgun, slow,
low-yield" reputation, uses Rigor's types + dependency graph to prune smartly and run
RSpec/minitest only where it matters. The strategy note evaluates it as a distinct product —
mutation testing of the **user's test suite** (a survivor = a test gap), not ADR-62's
mutation testing of the **analyzer** (a survivor = a Rigor false negative). The two share
only the Prism splicer (~20 %); the test-runner-driven 80 % is exactly what `mutant` spent a
decade on before going commercial. This ADR records why we defer and what shape it would
take if revived, so the deferral does not have to be re-derived.

## Decision

**Defer externalization.** Do not fork a general type-guided mutation-testing tool now; keep
the value inside Rigor ([ADR-70](70-fused-protection-coverage.md) fused protection over the
[ADR-69](69-pluggable-mutation-substrate.md) seam). If revived, build it around the
incremental wedge under one discipline.

> **Criterion (each lever only where it is sound):** **runtime coverage** selects which
> tests to run (sound; a static graph over-approximates and, worse, *misses* the dynamic /
> metaprogrammed calls a test exercises → a skipped killing test → a **false survivor**,
> which is an FP). The **dependency graph** scopes only *which files to mutate on a diff*
> (sound for "what changed"). **Type info** does mutant *generation* (well-typed ⇒ runnable,
> type-distinct ⇒ non-equivalent) and *stratified reporting* — **never** test selection. The
> wedge is "mutation testing you can run on every PR", not "we prune smarter than coverage".

## Re-evaluation triggers

Proceed only when **both** hold:

- **(a) ADR-46 incremental analysis has landed** — the diff-closure (`ΔF ∪ dependents`)
  that makes diff-scoped mutation affordable is its dependents index; without it the
  "every-PR" wedge has no engine.
- **(b) Demand is demonstrated** — ADR-70's dynamic axis shows, on real projects, that the
  test-protection signal carries value users act on; or users explicitly ask for a
  standalone tester. (The Ruby ecosystem seat is open — `mutant` license-restricted,
  `mutest` a fork — but an open seat is not, by itself, demand.)

Until both: the substrate (ADR-69) and the fused metric (ADR-70) are the only investment;
they are the prerequisites such a tool would inherit, so deferral costs nothing.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| "Static dependency graph prunes test selection → faster than coverage" | **Rejected** — runtime per-test coverage (what `mutant` / Stryker / PIT already use) is strictly more precise; the static graph over-approximates (slower) and, used for selection, produces **false survivors** = an FP. |
| "Type pruning makes mutation testing finally worthwhile" | **Overstated** — equivalent-mutant pruning bites at **typed** sites (which already have a static net → lowest marginal test value) and is blind at `Dynamic` sites (where tests are the only net). It also prunes the *cheap* axis (generation), not the expensive one (suite runs). A real but narrow gain, not the headline. |
| Build it now, before the v1.0 contract freeze | **Deferred** — the 80 % test-runner graveyard (flaky/timeout/ordering/parallel/Rails-DB) is a second product + support surface; bad timing against ADR-50's imminent freeze and the sponsorware bandwidth. |
| Adopt `mbj/mutant` / `mutest` as the engine | **Deferred** — for an *external* tool the Prism-vs-whitequark mismatch matters less than for ADR-62, but the in-process type probe (generation/stratification) and the maintenance burden still argue for the ADR-69 substrate over an incumbent fork; revisit at build time. |
| Type-guided **mutant generation** as a standalone offering (no test runner) | **Folded into ADR-70/69** — generating well-typed non-equivalent mutants is the reusable asset; it ships inside Rigor's protection tooling first, not as a separate product. |

## Consequences

- **Positive** — records the honest wedge and the rejected oversells, so a future build
  starts from "incremental/CI + sound-lever-placement" instead of re-pitching "smart
  pruning"; keeps the pre-1.0 project focused.
- **Negative** — none shipped (an evaluation ADR); the open ecosystem seat may be taken by
  another tool in the interim (an acceptable cost vs. the freeze-window risk).
- **Carry-over** — ADR-69 (substrate) + ADR-70 (fused metric) + ADR-46 (incremental) are
  the prerequisites; this ADR is revisited when (a) and (b) of the triggers are met.

## Relationship to other ADRs

- **ADR-69 / ADR-70** — the internal investments this defers *to*; an external tool would
  inherit the seam and the fused metric rather than rebuild them.
- **ADR-46** — re-evaluation trigger (a): the diff-closure engine the CI wedge needs.
- **ADR-62 / ADR-63** — the analyzer-teeth origin and its productized subset; this is the
  evaluated *third* direction (a test-suite tool), kept distinct from both.
- **ADR-50** — the freeze-window timing that makes "defer" the right call now.
- **`feedback_false_positive_discipline`** — the criterion's load-bearing value: a
  graph-selected false survivor is an FP, and that is the line the lever-placement rule
  keeps.
</content>
