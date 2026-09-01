# ADR-106 — Migrating the spec suite to minitest

Status: **Accepted (declined — the suite stays on RSpec), 2026-09-02.**

Records the project's answer to "should new tests be written in minitest, migrating gradually and
tolerating both frameworks in the interim?" so the question resolves against a written premise instead
of being re-litigated. The answer is **no**, and the reason is not the one usually given: the migration
arithmetic works here, and the framework is not what the suite costs. What the proposal actually asks
for is a second copy of the suite's shared harness, and a step away from the code shapes Rigor's users
write. **Nothing is scheduled by this ADR**; the re-evaluation triggers below are the way back in.

## Context

The question arrived out of CI cost — the `Tests` job was ~11 minutes and dominated the workflow. That
premise is now spent. Two changes ([#563](https://github.com/rigortype/rigor/pull/563) deduplicated
identical RBS environment builds, [#566](https://github.com/rigortype/rigor/pull/566) sharded the job
three ways) took the whole workflow from ~10m30s to ~3m10s without touching a test framework, which is
itself the first piece of evidence: the cost was never in RSpec.

The proposal as put was the strangler-fig form — new tests in minitest, no bulk port, dual frameworks
accepted for as long as it takes. That shape deserves to be judged on its own terms rather than
dismissed with the usual "migrations never finish" — in this repository, this one plausibly would.

## Decision

Do not migrate. New tests are written in RSpec, like the rest.

Two criteria carried the decision, both intended to be reusable beyond this question:

1. **When a proposal's cost sits in shared harness rather than in the component being replaced, extract
   the harness first and re-measure** — extraction usually removes the reason to replace. Here the
   replaceable part (RSpec's runner and DSL) is ~1.7s of a ~12-minute suite, while the irreplaceable
   part (`spec/spec_helper.rb` + `spec/support/runner_helpers.rb`, the mutation harness, the sharded CI
   matrix) is where the whole cost lands, and a second framework duplicates all of it.
2. **Rigor does not migrate away from the shapes its users write.** Where Rigor's own source is a corpus
   for Rigor, adopting a more analysable framework converts a product gap into a private convenience and
   removes the pressure that would have fixed it for every user.

## Grounding

Measured 2026-09-02 on `master`; each row is reproducible from the command beside it.

| Claim | Measurement | How |
| --- | --- | --- |
| Framework overhead is seconds | 1.7s to load 424 files and register 10,207 examples | `rspec --dry-run` |
| The time is real analysis, not the framework | 98.3% of measured example time is in the 2,108 examples taking ≥0.1s; 5,583 examples under 1ms total 1.0s between them | aggregate `tmp/binpacker.timings` |
| The suite's mass is not in the framework | 110,764 lines across 424 spec files | `find spec -name '*_spec.rb'` |
| New-test inflow is high | 426 spec files added since the first commit (2026-04-26); 38–89 per month recently | `git log --diff-filter=A -- 'spec/**/*_spec.rb'` |
| RSpec-shaped code is not opaque to Rigor | 51.15% precision on a 25-file spec sample, against 61.33% on `lib` | `rigor coverage spec/rigor/cache spec/rigor/type_node` vs `rigor coverage lib` |

## Rejected and considered alternatives

| Option | Why not |
| --- | --- |
| **Full port to minitest, one cycle** | Rejected on cost with no benefit to buy it: 110,764 lines, ~1,131 `let` sites, ~400 mock sites, and a rewrite of the binpacker integration, for a measured 1.7s. |
| **New tests in minitest, gradual migration (the proposal)** | Rejected — see the cost analysis below. Notably *not* rejected on convergence: at the observed inflow a minitest lane would out-number the 424 RSpec files inside a year. |
| **Move only new *unit* tests, keep integration on RSpec** | Rejected as the worst of both: it makes the lane boundary a judgement call on every new file, and the harness duplication is paid in full regardless of which lane is larger. |
| **Keep RSpec (chosen)** | The framework is not a cost centre, and the harness stays single-homed. |

### Why the arithmetic is not the objection

The usual argument against a gradual test-framework migration is that the old lane never empties. That
argument does not hold here. The repository is four months old and its entire 424-file suite was written
inside that window; recent inflow is 38–89 new spec files a month. A minitest lane would reach parity by
count well within a year without anyone porting a line.

It should be read with its caveat — that rate is a young project's initial build-out and will
decelerate — but the honest summary is that convergence is the proposal's strongest point, not its
weakest, and the decision does not rest on denying it.

### What the cost actually is

The suite's framework is thin; its **harness** is not, and it is single-homed in three places that a
second lane would each have to duplicate and then keep in sync.

- **`spec/spec_helper.rb` carries twelve process-wide invariants**, each attached to a defect: the
  engine-identity memo reset (#289), the temp-directory leak guard (#330), the deferred-YJIT pin (#567),
  the pool-spec exclusion (ADR-15), the CI-detection pin (ADR-51), the rbs-inline auto-wire pin
  (ADR-93), and the RBS-environment memo added with #563. These do not fail loudly when missing. #567 is
  the shape to expect: a leaked JIT sleeper surfaced as a flake in a *different* file, passing at twelve
  workers locally and failing at four on CI. Two lanes are two chances to get each of these wrong, and
  this repository has a drift precedent — the ADR-72 ActiveSupport overlay diverged twelve selectors
  from its plugin twin (#449).
- **`spec/support/runner_helpers.rb` is where the suite's performance lives** — the shared cache store,
  content-keyed `sig:` materialisation, the shared workspace, the RBS environment memo. A minitest copy
  that missed one of these would be silently ~2× slower per test rather than wrong, which is harder to
  notice than a failure.
- **The mutation harness would under-report protection, silently.** `tool/mutation/self_mutate.rb:245`
  runs `bundle exec rspec` against the specs covering each mutated file. A mutant killed only by a
  minitest survives, and is reported as a test-unprotected site. That is a false positive in the
  measurement the harness exists to produce, and it would undo the 1,969→22 de-noising that made the
  funnel usable.

Two further costs are real but ordinary: `binpacker.yml` binds one `test_runner` per profile, so the
three-shard matrix and its `shard-coverage` gate would need a second copy —
plausibly *raising* wall time during the transition, since each job pays its own setup — and the repo
would carry two lint regimes.

### The dogfooding argument, and why it inverts

The strongest case *for* minitest is not speed but dogfooding: RSpec's block DSL is close to worst-case
for inference, `make check` covers only `lib`, and 110,764 lines of specs sit outside Rigor's own
analysis. Migrating would open that corpus up.

Measured, the premise is weaker than it sounds — Rigor reaches 51.15% precision on RSpec-shaped spec
files against 61.33% on `lib`. Roughly half of RSpec-shaped code is already precisely typed; the gap is
about ten points, not a wall.

And the remaining ten points argue the other way. Rigor's users write RSpec. If RSpec shapes are where
inference is weakest, then moving Rigor's own suite off RSpec removes the pressure to fix them from the
people best placed to do it, and hides a customer-facing gap behind a private convenience. The 51.15%
figure is better read as an input to `docs/type-specification/` than as a reason to migrate.

## Consequences

- **Positive.** The harness stays single-homed, so an invariant like #567's is fixed once. The mutation
  harness keeps measuring what it claims to. The CI matrix stays one matrix.
- **Positive.** RSpec-shaped inference stays a live product concern rather than an internal annoyance.
- **Negative.** `spec/` remains outside `rigor check`, so the largest body of Ruby in the repository is
  not dogfooded. This is a real loss and is not mitigated by this ADR.
- **Negative.** The project stays on a dev dependency it does not control. The exposure is small — RSpec
  is a development dependency and does not ship in `rigortype` — but it is not zero.
- **Carry-over.** Nothing is scheduled. No spec files change.

## Re-evaluation triggers

Reopen this if any of the following becomes true:

1. **The harness is extracted.** If `spec_helper`'s invariants and `RunnerHelpers` become plain
   framework-agnostic objects that a runner merely calls, criterion 1 no longer applies and the cost
   collapses to the framework itself. That extraction is worth doing on its own merits; doing it first
   is the precondition, not a courtesy.
2. **The mutation harness learns to find covering tests across frameworks**, so a split suite cannot
   produce a false unprotected-site report.
3. **RSpec-shaped precision stops being a product concern** — because it has been closed, or because a
   survey shows Rigor's users are not on RSpec. Either removes the inversion in criterion 2.
4. **A measured cost appears that is attributable to the framework**, rather than to the analysis the
   tests drive. Nothing in the grounding above suggests one today.

Absent those, treat this as settled.

## Relationship to other ADRs

- [ADR-21](21-rubydex-evaluation.md) — the same shape: an adoption question answered once, in writing,
  with explicit re-evaluation triggers rather than a standing debate.
- [ADR-31](31-contribution-and-supply-chain-policy.md) — a suite-wide framework migration is a sweeping
  change under WD1, so it would be issue-first regardless of its merits.
- [ADR-5](5-robustness-principle.md) — the false-positive discipline, applied here to Rigor's own
  tooling rather than to its diagnostics: a measurement that silently under-reports (the mutation
  harness under a split suite) is worse than one that fails loudly.
