# Type-guided mutation testing — strategy note (internal teeth vs. an external test-suite tool)

Status: design discussion + judgement, authored 2026-06-17 against Rigor v0.1.19
(`[Unreleased]`). Records a two-sided evaluation (maximally expansive vs. severely
critical) of whether Rigor's partially-implemented Prism mutation machinery should stay an
internal analyzer feature or grow into an external, type-pruned mutation-testing framework
driving RSpec / minitest. Feeds [ADR-69](../adr/69-pluggable-mutation-substrate.md),
[ADR-70](../adr/70-fused-protection-coverage.md), and
[ADR-71](../adr/71-type-guided-external-mutation-testing.md). Non-normative; the ADRs and
spec bind.

Grounding: [ADR-62](../adr/62-mutation-testing-teeth-measurement.md) (the internal teeth
harness), [ADR-63](../adr/63-type-protection-coverage.md) (the productized per-file
effectiveness tier), [`20260613-mutation-teeth-harness.md`](20260613-mutation-teeth-harness.md)
(the living harness tracker), and the shipped code: `tool/mutation/mutate.rb` (dev-only
sweep/fuzz), `lib/rigor/protection/mutator.rb`, `lib/rigor/protection/mutation_scanner.rb`.

## The question

Two impulses, stated by the maintainer:

1. Should the mutation framework stay a slice of Rigor (the ADR-62 teeth harness), or
2. become an **external library** that combines with RSpec / minitest to grow into an
   advanced mutation-testing framework — using Rigor's **cross-file dependency graph and
   type information to prune the mutation space smartly**, so it finds latent problems
   without the usual "shotgun, slow, low-yield" reputation of mutation testing?

## What is actually built today (grounding the discussion)

The whole machinery is optimized for one question: **re-run Rigor on mutated bytes — does
a *new Rigor diagnostic* appear?** This matters because it determines how much of the
maintainer's idea is reusable.

- The `kill` definition is a **Rigor diagnostic signature** (`mutation_scanner.rb` `sig` =
  `(rule, path, line, column, message)`). The test suite is **nowhere** in the loop.
- The intelligence — `Mutator#filter_by_type` — keeps a mutation only where **Rigor holds
  a concrete (non-`Dynamic`) type** at the anchor: where Rigor *can bite*. FP-safe
  direction (unresolved type ⇒ keep).
- The operators (`nil_inject` / `type_swap` / `undefined_method` / `arity_extra`) are
  engineered to trip **Rigor diagnostic rules**, not to be "runnable-but-behaviourally
  distinct" mutants a test suite would catch. `undefined_method` renames a call to
  `foo__rigor_absent` — a guaranteed runtime `NoMethodError`, trivial for any covering test
  but low-information (it usually crashes before the assertion).

So ADR-62 measures **the analyzer's false negatives** (does Rigor have teeth). The
maintainer's idea measures **the test suite's false negatives** (do *your tests* have
teeth). These are different products.

## Framing: two products, ~20 % shared

| | **Product A — what exists** | **Product B — the proposal** |
| --- | --- | --- |
| mutation target | analyzed code | the user's code |
| `kill` oracle | **Rigor emits a diagnostic** | **the test suite goes red** |
| a survivor means | a **Rigor false negative** (engine gap) | a **test gap** |
| what runs per mutant | one in-process re-analysis | the user's whole (relevant) test suite |
| status | dev-only, off the ADR-50 frozen surface | an external ecosystem product |

The only shared surface is the **Prism byte-splice mechanism** (`Mutation#apply`, the AST
walk) — roughly 20 %. The other 80 % (a test-runner-driven kill oracle, result attribution,
flaky/timeout/ordering/parallel/Rails-DB handling) is new, and is exactly the 80 % `mutant`
spent a decade on before going commercial.

## Stance 1 — maximize the possibility (expansive)

1. **A fused static×dynamic "protection map" is genuinely novel.** Stryker/mutant measure
   *test* protection; Sorbet/Steep metrics measure *type* protection. **No tool fuses the
   two axes.** Rigor already owns the static half (ADR-63 Tier 1). Overlay the dynamic half
   (does a test kill the mutant) and you get: *a line is unprotected ⟺ neither a type nor a
   test guards it* — and you can point at the **cheaper** of "add a type" vs "add a test".
2. **Type-directed operators attack the #1 complaint (equivalent mutants).** Rigor knows
   the type at each site, so it can emit a `type_swap` that is **well-typed (so it runs)**
   and **provably non-equivalent at the type boundary** — near-zero equivalent-mutant waste
   in the class it covers. A fresh, type-system-specific angle on the oldest mutation
   gripe.
3. **"Kill it with the type checker first" — a gradual story.** A mutant Rigor *itself*
   diagnoses never needs the suite run (type = first line, tests = second). The honest,
   cheap metric becomes *"of mutants the type checker passes, what fraction does your suite
   catch?"* — skipping the expensive 80 % (suite runs) for everything the type net already
   holds.
4. **Incremental / CI mutation testing via ADR-46 — the unsolved dream.** Mutation testing
   never went CI-viable because of cost. The [ADR-46](../adr/46-incremental-dependency-graph.md)
   dependency graph lets you mutate only the diff's closure (ΔF ∪ dependents) and run only
   affected tests: *"mutation testing you can run on every PR."*
5. **An open ecosystem seat + the best marketing Rigor has.** Ruby mutation testing is
   underserved (`mutant` license-restricted, `mutest` a fork, both slow). A type-aware,
   incremental, RSpec/minitest tool could own that seat and double as a banner — "Rigor
   doesn't just check types, it proves your tests have teeth." "Type-guided mutation
   testing" is also a distinctive, near-publishable research angle.

## Stance 2 — be severe (critical)

1. **The shared part is the easy 20 %; the hard 80 % is `mutant`'s graveyard.**
   Test-runner driving, result attribution, flaky/timeout/ordering/parallel/Rails-DB — all
   new, all the reasons `mutant` went commercial. A pre-1.0 sponsorware type checker about
   to **freeze its contract** ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md))
   forking attention into a second product with a second support surface is a strategic
   risk.
2. **For test *selection*, the static graph LOSES to runtime coverage.** "Prune with the
   dependency graph" misreads the problem: deciding *which tests touch this mutant* is done
   best by runtime line / per-test coverage — which `mutant` / Stryker / PIT already use.
   The static graph is an **over-approximation**, so it runs *more* tests than needed —
   slower, not faster.
3. **Worse: a static graph used for test selection produces FALSE survivors — which is an
   FP.** Rigor's dependency graph records **type** reads, not the **runtime** call graph a
   test exercises. Tests hit metaprogramming, dynamic dispatch, `send` — exactly the
   `Dynamic` region Rigor can't see. Select tests with the graph and you **skip the test
   that would have killed the mutant, then report a "test gap" that doesn't exist.** That is
   the mutation-testing analogue of a false positive — and FP-avoidance is this project's
   top-tier value (`feedback_false_positive_discipline`). Using the graph for selection
   betrays Rigor's own ethos.
4. **Type pruning helps where value is LOW and is blind where value is HIGH.** The type
   filter bites at **typed** sites — which already have a static net, so a test's marginal
   value there is *lowest*. Tests are most needed at **`Dynamic`** sites (no static net),
   where the filter can neither prune nor prove non-equivalence. The tool's intelligence
   concentrates exactly where the test-gap value does not.
5. **Equivalent-mutant detection only sees the type-shaped sliver.** Rigor proves
   equivalence for the narrow class its lattice captures (constant folds, dead clauses,
   type-invariant swaps). The dominant equivalent-mutant classes are **semantic**
   (never-hit boundaries `<=` vs `<`, commutative reorderings, masked off-by-one) — invisible
   to types. "Types solve equivalent mutants" chips a corner.
6. **The expensive part doesn't shrink.** Mutation cost is *suite execution*, not mutant
   generation. The type filter removes mutants to run — but per (4) it removes the
   high-value `Dynamic`-site ones, optimizing the cheap side and keeping the costly one.
7. **The project already deliberated and deliberately kept it internal.** ADR-62 WD4 (off
   the frozen surface, not shipped); ADR-63 ships only a *narrow curated subset* with a
   load-bearing **"always effectiveness, never raw survival"** framing — because raw
   survival frightens working code. An external product re-runs that risk on other people's
   suites, outside Rigor's control.

## Judgement (synthesis)

Split apart, the critical fire lands on the **external general-purpose form** but spares the
**genuinely valuable core**. So: not a binary, but an ordering.

1. **Do not fork an external product now.** The 80 % test-runner graveyard, taken on right
   before the v1.0 contract freeze, is bad timing.
2. **The cheap, on-mission, novel move is the fused protection map — as an ADR-63
   extension**, not a general framework. Add a thin "run the suite once against the
   *survivors* and overlay static∪dynamic protection" layer to `coverage --protection`.
   Minimal new surface; a new artifact nobody else ships. → **ADR-70.**
3. **Buy optionality cheaply: clean the seam.** Make the **kill oracle** and the
   **operators** pluggable so the oracle can be *"new Rigor diagnostic"* (today) or *"the
   suite went red"* (future) without re-architecture. `lib/rigor/protection/mutator.rb` is
   already shared between lib and `tool/mutation/`; this finishes the seam. → **ADR-69.**
4. **Gate the external tool on demand × ADR-46 being real, and market the surviving
   wedge honestly.** The wedge that survives the critical case is **incremental / CI
   mutation testing** (run on every PR), **not** "we prune smarter" (we lose to coverage at
   selection). Use each lever only where it is sound: **runtime coverage** selects tests
   (sound), the **dependency graph** scopes *which files to mutate on a diff* (sound for
   "what changed"), **type info** does generation + stratified reporting (never test
   selection — avoids the (3) false survivor). The two honest assets are (a) the fused
   protection metric and (b) diff-scoped runs. → **ADR-71** (evaluation; demand-gated).

One-line takeaway: **"types prune the mutation space smartly → better than ordinary
mutation testing" is overstated** (loses to coverage at selection; pruning bites where
value is lowest), but **"fuse static and dynamic protection into one map" and "diff-scope
mutation testing into CI viability" are real and novel.** Take the first now inside Rigor,
prepare the seam, demand-gate the rest.

## Decomposition into ADRs

- **ADR-69 — Pluggable mutation substrate (kill-oracle + operator seam).** Mechanical /
  architecture; the enabling refactor. Actionable now.
- **ADR-70 — Fused static∪dynamic protection coverage.** Deliberative; extends ADR-63;
  ADR-69's first consumer. Actionable now (thin slice).
- **ADR-71 — Type-guided external incremental mutation testing.** Evaluation / proposal;
  records the wedge, the rejected oversells, and the demand × ADR-46 gate. Deferred.
</content>
</invoke>
