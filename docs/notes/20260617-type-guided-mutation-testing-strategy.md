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

## Validation on real projects (2026-06-17)

After landing ADR-69 Seam 1 + ADR-70 (`coverage --protection --mutation --with-tests`),
three subagents validated it against `rigor-survey` targets (faraday / liquid / mail; rgl
and kramdown were rejected as targets — see friction below). Recipe: isolated
`bundle install`, a matched `(source file, single green test file)` pair, and the fused
overlay scoped to that pair.

**The feature works and is FP-free.** The dynamic (test) axis genuinely fires on real
type-survivors: faraday `nested_params_encoder.rb` (test_killed 3), liquid `lexer.rb:152`
`output.last&.first` (1), mail `utilities.rb` (11) / `parts_list` (2) / `field_list` (2).
The mail run reconciled exactly against the type-only baseline (9 type-killed + 11
test-killed + 7 unprotected = 27 survivors), **proving the test axis is consulted only on
type-survivors** (the gradual short-circuit is real). Every `unprotected` site hand-checked
was a genuine coverage gap (zero FPs); files were restored byte-for-byte after every run
(the `ensure` holds); JSON shape correct. Per-run cost = `type_survivors × scoped-test-run`
(~2–9 s on these small suites).

**Two real frictions found — one a genuine bug, now fixed:**

1. **Bundler-env leak (BUG — FIXED).** Running Rigor via `bundle exec exe/rigor` leaks
   `RUBYOPT=-rbundler/setup` + `GEM_HOME` / `BUNDLE_*` into the process; the oracle's plain
   `system` passed them to the test subprocess, which then resolved the *target's* Gemfile
   against *Rigor's* gems and failed → a green suite read as red → the run aborted before
   doing any work. A bare `env -u BUNDLE_GEMFILE` is **not** enough (the `BUNDLER_ORIG_*`
   preservers defeat it). Fixed by wrapping the runner in `Bundler.with_unbundled_env`
   (`test_suite_oracle.rb` `shell_run`); users no longer need any env wrapper in
   `--test-command`. Re-validated: liquid `lexer.rb` with a plain `bundle exec` command now
   runs (was a hard fail).
2. **Non-zero exit on a passing suite (documented).** A SimpleCov per-suite coverage floor
   (faraday) exits non-zero even when all tests pass, so a file-scoped run trips the
   green-precondition. The exit code is the only signal, so this is partly inherent; the
   `suite_not_green_error` message now hints at it (point `--test-command` at a plain
   pass/fail runner).

**Empirical confirmation of the Seam-2 gap (the load-bearing finding).** The overlay reuses
the **biteable** site filter, so it only ever mutates concrete-type sites and the type axis
short-circuits the vast majority (liquid: 92 of 100 sites type-killed; the denominator is
*biteable* sites, not *all* dispatch sites). The test axis is consulted only on the residual
handful of concrete-site type-survivors — so the fused map's headline cell, *"a `Dynamic`
site guarded only by a test"*, is **never reached**, because `Dynamic` sites generate no
mutations at all. This is the critical-analysis point #4 ("type pruning is blind where value
is highest") manifesting in the implementation, now measured rather than predicted. It is
the strongest argument for **pulling ADR-69 Seam 2 (`AllSites`) forward** — without it the
overlay shows where types protect and where the residual concrete survivors land, but not
the most interesting thing a user wants from a *test*-protection view. (Tension: mutating
`Dynamic` sites and running tests on them *is* the expensive test-suite mutation testing
ADR-71 defers — so Seam 2 is the bridge between this overlay and ADR-71, and pulling it
forward is a real scope decision, not a free win.)

**Completeness caveat (document for users).** A `--test-command` scoped to one test file
*over-reports* `unprotected` versus the full suite (a mutation a different test would catch
shows as unprotected). Correct-by-construction — the verdict is only as complete as the test
command's coverage — but for an accurate map the command should run all tests covering the
file, trading cost for completeness.

## Seam 2 landed — `--include-dynamic` (2026-06-17, same day)

The load-bearing finding above (the overlay was blind to `Dynamic` sites) was acted on
immediately rather than left to ADR-71: ADR-69 Seam 2 shipped as `--include-dynamic`. The
`MutationScanner` gained a `site_selector:` (`:biteable` default, `:all` opt-in);
`Mutator#dispatch_site_mutations` keeps every dispatch site (method call or call-argument
literal), `Dynamic` receiver included, dropping only non-dispatch literals. It is gated to
`--with-tests` — at a `Dynamic` site the type pass can never kill, so without the test axis
these are all noise (the ADR-62 Criterion-A trap). The ADR-63 Tier 2 `scan_file` stays
`:biteable`, unchanged. This is *contained*: it reuses the existing warm loop and the fused
classification, changing only which sites are mutated — not the ADR-71 external product.

Re-validated on liquid `lexer.rb` (vs `lexer_unit_test.rb`):

| | dispatch sites | type-killed | test-killed | unprotected |
| --- | --- | --- | --- | --- |
| biteable only | 76 | 75 | 1 | 0 |
| `--include-dynamic` | **115** | 75 | **38** | **2** |

The 39 `Dynamic`-receiver sites the biteable view dropped are now scored: **38 are
test-protected** (the lexer test exercises them — "your `Dynamic` code IS covered"), and **2
are genuinely unprotected** — `#raise` @ L168 (an error path) and `#scan_byte` @ L118 — the
real "add a type or a test here" gaps that only the complete map surfaces. The headline cell
of the fused map ("a `Dynamic` site guarded only by a test") is now reachable, and the map
covers *all* dispatch sites, not just the biteable subset. Cost rises (every `Dynamic` site
is a type-survivor → a suite run), so it is an explicit opt-in. `make verify` clean; files
restored byte-for-byte. This closes the critical-analysis point #4 not by refuting it but by
giving the user the lever to see past it.
</content>
</invoke>
