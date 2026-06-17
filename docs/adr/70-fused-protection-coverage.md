# ADR-70 — Fused static∪dynamic protection coverage

Status: **Accepted — implemented 2026-06-17 (`coverage --protection --mutation --with-tests`),
co-landed with [ADR-69](69-pluggable-mutation-substrate.md) Seam 1, over
[ADR-63](63-type-protection-coverage.md).** Adds an optional **dynamic overlay**: for each
mutant the *type* checker fails to kill, it asks whether a *test* kills it (via the ADR-69
`Protection::TestSuiteOracle`, the runner hook = `--test-command`, default `bundle exec
rake`) and classifies each site by **both** axes. The artifact is the fusion: a line is truly
unprotected only when **neither** a type nor a test guards it, and the report names the
**cheaper missing axis** ("add a type" vs "add a test"). No existing tool fuses static
type-protection and dynamic test-protection into one map.

Implemented: `Protection::MutationScanner#scan_file_fused` (the gradual short-circuit +
three-bucket classification), `Protection::TestSuiteOracle` (`test_suite_oracle.rb`, the
injectable-runner kill oracle that restores the file in an `ensure`), and the
`CoverageCommand#run_fused_protection` wiring (`coverage_command.rb`) + `FusedProtectionReport`
/ `FusedProtectionRenderer` (text + `mode: "protection-fused"` JSON).

Grounding: [`docs/notes/20260617-type-guided-mutation-testing-strategy.md`](../notes/20260617-type-guided-mutation-testing-strategy.md)
(judgement step 2 — the cheap, on-mission, novel move), ADR-63 (the protection-coverage
command this extends), ADR-69 (the oracle seam it consumes).

## Context

ADR-63 ships two protection tiers, both **static**: Tier 1 (could-Rigor-bite, receiver
concreteness) and Tier 2 (does-Rigor-bite, mutation kill rate). Both answer *"is the **type
system** protecting this site"*. Neither sees the user's **test suite** — yet a site Rigor
leaves `Dynamic` (its protection blind spot, and per the strategy note exactly where the
type filter can't help) may be thoroughly guarded by a test, and a fully-typed site may have
no test at all. Reporting only the static axis mislabels both: it calls a test-covered
`Dynamic` site "unprotected" and a test-free typed site "protected". The actionable question
a user has is the **union**: *given my types AND my tests, where is this line actually
unguarded, and which is the cheaper fix?*

The strategy note's critical analysis kills the *general* "type-pruned external mutation
framework" (loses to coverage at test selection; pruning bites where value is lowest), but
spares this: a fused **report**, scoped to survivors, reusing machinery Rigor already owns.

## Decision

Extend `coverage --protection --mutation` with an opt-in dynamic overlay (e.g.
`--with-tests` / a `RIGOR_PROTECTION_TESTS` runner hook) that runs the suite **only against
the mutants Rigor did not kill**, then reports a fused per-site classification.

> **Criterion (extends ADR-63's framing):** the metric is always *effectiveness /
> where-to-add-protection*, never raw survival — **and** the fusion's payload is the
> **attribution**, not a single number: each unprotected site is tagged with its **cheapest
> missing axis** (a `Dynamic`-receiver hole ⇒ "add a type"; a typed-but-test-unkilled hole
> ⇒ "add a test"). A site is reported unprotected **only** when both axes miss.

- **Gradual short-circuit (the cost model).** A mutant the type checker already kills never
  reaches the suite — the static net is the first line, tests the second. The expensive
  suite run is paid only for *type-survivors*, so the overlay's cost is proportional to the
  protection hole, not the file. This is the honest, cheap framing: *"of mutants the type
  checker passes, what fraction do your tests catch?"*
- **Three observed buckets (the short-circuit collapses the fourth).** type-protected
  (ADR-63 killed) · test-protected (type-survived, suite red) · **unprotected** (both
  survived — the ranked "add protection here" list). The conceptual *doubly-protected* bucket
  is collapsed **into type-protected**: a type-killed mutant never reaches the suite, so
  whether a test *would also* catch it is deliberately not paid for (the static net already
  suffices). `--format json` carries the three counts (`type_killed` / `test_killed` /
  `unprotected`) + the attributed sites; `--threshold` gates on the **fused** protected
  ratio.
- **Selection is the suite's job, never the dependency graph.** The overlay runs the user's
  suite (or their chosen subset) as-is. It MUST NOT use Rigor's type dependency graph to
  pick which tests to run: that graph records *type* reads, not the *runtime* call graph, so
  it would skip the test that kills the mutant and report a **false** test-gap — an FP, the
  one line this project will not cross (`feedback_false_positive_discipline`). Coverage-based
  selection is a later optimization (ADR-71), and runtime coverage — never the static graph.

## Working decisions

- **WD1 — survivor-scoped, opt-in, changed-files default.** The overlay attaches to the
  existing Tier-2 command, inherits its changed-files default (ADR-63 WD4), and is off
  unless the test hook is given. Whole-project stays an explicit opt-in (cheaper once
  ADR-46 lands).
- **WD2 — the test oracle is a candidate signal, adjudicated, not a verdict (ADR-59).** A
  "test-survivor" means *no run test killed it* — pending / tagged-out / skipped / flaky
  tests are unknowable, so a survivor is a *candidate* test gap surfaced for review, never a
  claim that the suite is broken. The report says so. This is the ADR-59 witness rule
  applied to the dynamic axis: the suite *prioritizes and verifies* attention, it does not
  *certify* absence of a test.
- **WD3 — consume ADR-69's `TestSuiteOracle`; co-land the seam.** The overlay is the first
  oracle consumer; it exercises the ADR-69 interface rather than reaching into a runner
  directly. The `DiagnosticOracle` path (ADR-63 Tier 2) stays byte-identical.
- **WD4 — new flag + JSON keys are frozen vocabulary under ADR-50 WD1.** Name them once,
  deliberately (the overlay flag, the four classification keys), as public contract.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Run the suite for **every** mutant (no short-circuit) | **Rejected** — pays the expensive axis where the cheap type net already holds; the gradual short-circuit is the cost model that makes this affordable. |
| Headline a single fused "protection %" | **Rejected (sharpens ADR-63)** — the number buries the payload; the **attribution** (which axis is missing, which is cheaper) is the actionable output. A `%` may accompany it, never replace it. |
| Use the dependency graph to select which tests to run | **Rejected** — produces false survivors (type-graph ≠ runtime call-graph); an FP. Selection is runtime coverage's job, deferred to ADR-71. |
| A new `rigor protection` / `rigor teeth` command | **Rejected** — same call as ADR-63 WD1: protection is a coverage dimension; extend `coverage`, reuse threshold/JSON. |
| Treat a test-survivor as a proven test gap | **Rejected (WD2)** — pending/tag/flaky unknowability; it is an adjudicated candidate (ADR-59). |

## Consequences

- **Positive** — a genuinely new artifact: the static∪dynamic protection map, with
  cheapest-fix attribution, that no Stryker/mutant/Sorbet-metrics tool ships; minimal new
  surface (one flag + JSON keys over existing plumbing); the gradual short-circuit keeps
  cost proportional to the hole.
- **Negative** — introduces a test-runner dependency into a coverage command (the surface
  ADR-62 deliberately avoided) — hence opt-in, survivor-scoped, and behind the ADR-69 seam;
  the WD2 unknowability means the dynamic axis is softer than the static one, and the report
  must teach that.
- **Carry-over** — co-landed with ADR-69 Seam 1. Whole-project affordability and
  coverage-based suite selection are ADR-46 / ADR-71 follow-ups, not v1 of this overlay;
  `--with-tests` inherits the changed-files default (no path = git-changed only).
- **Validated on real projects (2026-06-17, faraday / liquid / mail).** The test axis fires
  on genuine type-survivors, FP-free, with byte-for-byte file restore; the type/test/unprotected
  split reconciles exactly against the type-only baseline. Two frictions surfaced: a
  **bundler-env leak** (`bundle exec exe/rigor` leaked `RUBYOPT`/`GEM_HOME` into the suite
  subprocess → green read as red) — **fixed**, `TestSuiteOracle#shell_run` now wraps the
  runner in `Bundler.with_unbundled_env`; and a **non-zero-exit-on-pass** case (a SimpleCov
  coverage floor) the green precondition can't distinguish from red — surfaced in the error
  message. The **load-bearing finding**: because the overlay reuses the biteable-site filter,
  the type axis short-circuits the vast majority and the test axis is only ever consulted on
  concrete-site survivors — the fused map's headline cell (*a `Dynamic` site guarded only by
  a test*) is unreachable without **ADR-69 Seam 2 (`AllSites`)**, which the validation
  re-prioritizes from "with ADR-71" toward sooner. See
  [`docs/notes/20260617-type-guided-mutation-testing-strategy.md`](../notes/20260617-type-guided-mutation-testing-strategy.md)
  § Validation.

## Relationship to other ADRs

- **ADR-63** — the direct parent; adds the dynamic axis its two static tiers lacked, same
  framing rule and command.
- **ADR-69** — consumes the `TestSuiteOracle` seam; first consumer, co-lands.
- **ADR-59** — WD2 is its witness-not-signature rule on the test axis: a survivor
  prioritizes/verifies, it does not certify.
- **ADR-46** — the incremental story that makes whole-project + coverage-selected overlays
  affordable later.
- **ADR-71** — the external generalization this stays deliberately *short* of; the fused
  metric is a prerequisite that tool would inherit.
- **ADR-50** — the overlay flag + JSON keys are frozen public vocabulary.
</content>
