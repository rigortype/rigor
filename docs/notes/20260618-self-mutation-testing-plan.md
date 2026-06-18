# Mutation-testing Rigor's own codebase — plan (RSpec ∪ self-check, with an independent type oracle)

Status: design note + plan, authored 2026-06-18 against Rigor v0.2.0 (`[Unreleased]`).
Non-normative; the ADRs and spec bind. Records a plan to point the existing mutation
machinery **inward** — at `lib/rigor/` itself — so that breaking the implementation in a
type-visible **or** behaviour-visible way is caught by *either* Rigor's RSpec suite *or*
its own self-check, and the residual (caught by neither) is surfaced as an implementation
hole to close.

Grounding (all shipped): [ADR-62](../adr/62-mutation-testing-teeth-measurement.md) (the
internal teeth harness), [ADR-63](../adr/63-type-protection-coverage.md) (productized
per-file effectiveness), [ADR-69](../adr/69-pluggable-mutation-substrate.md) (the
kill-oracle + site-selector seams), [ADR-70](../adr/70-fused-protection-coverage.md) (the
fused static∪dynamic map), [ADR-71](../adr/71-type-guided-external-mutation-testing.md)
(the deferred external form + its soundness rules), and the prior notes
[`20260613-mutation-teeth-harness.md`](20260613-mutation-teeth-harness.md) +
[`20260617-type-guided-mutation-testing-strategy.md`](20260617-type-guided-mutation-testing-strategy.md).
Code: `tool/mutation/mutate.rb`, `lib/rigor/protection/{mutator,mutation_scanner,diagnostic_oracle,test_suite_oracle}.rb`,
`lib/rigor/cli/coverage_mutation.rb`.

## The question — a third target for the same machinery

The existing work measures two different things; this plan adds a third:

| | mutation target | a survivor means | status |
| --- | --- | --- | --- |
| **A — teeth harness** (ADR-62) | analyzed *user* code | a Rigor **false negative** (engine gap) | shipped, dev-only |
| **B — fused protection** (ADR-70) | a *user's* code | a *user's* **type∪test gap** | shipped (`--with-tests`) |
| **C — this plan** | **`lib/rigor/` itself** | a hole in *Rigor's own* tests **and** self-check | proposed |

The maintainer's goal — "mutation-test Rigor's codebase to close 実装の穴, via 型 and/or
RSpec, efficiently and comprehensively" — is **Product B turned inward**, with the
self-check (`make check`) as a *second* kill oracle beside the RSpec suite. The valuable
artifact is the same as ADR-70's: per mutation, *which* axis (if any) caught it, so a
survivor points at the cheaper missing guard — **add a spec** vs **add a type / sharpen a
self-check rule**.

"型" = Rigor's own `rigor check lib` (self-check) as the kill oracle. "RSpec" = Rigor's own
`bundle exec rspec` suite as the kill oracle. The two catch disjoint bug classes
(type-shaped vs behaviour-shaped), so fusing them is what makes the sweep **comprehensive**;
coverage-guided selection + the gradual short-circuit are what make it **efficient**.

## What already works (grounding, measured 2026-06-18)

The "型" half is **essentially already shipped** — `rigor coverage --protection --mutation`
re-analyses each `lib/rigor` file's mutants against its clean baseline via the warm loop and
reports the self-check kill rate. Measured today:

```
$ bundle exec exe/rigor coverage lib/rigor/cli/ci_detector.rb --protection --mutation
  caught breakages: 3 / 4  (75.0%)
  Add a type here … lib/rigor/cli/ci_detector.rb:77
  real 1.1s          # warm loop: env+scan once, then ~ms/mutant
```

`tool/mutation/mutate.rb sweep lib/rigor` already does this at corpus scale with survivor
clustering — that is the 2026-06-13 note's `lib/rigor` sweep (teeth 71.4 %). **So the type
axis on `lib/rigor` is not new work; it is a re-run + a clustering pass.** The deltas this
plan adds are (1) the **RSpec axis**, (2) the **fusion + attribution**, (3) an
**independent type oracle** so analyzer mutation cannot corrupt its own checker, and (4)
**coverage-guided selection** so the RSpec axis is affordable.

Also already present: both kill oracles (`DiagnosticOracle`, `TestSuiteOracle`), the
site-selector seam (`:biteable` / `:all` = `--include-dynamic`), the warm loop
(`LanguageServer::ProjectContext`), and a **mise-shimmed stable `rigor` on PATH** (0.1.18,
independent of the 0.2.0 worktree) — the decoupled oracle the maintainer proposed already
exists.

## The one genuinely new constraint — the bootstrap hazard

For Product B (user code), the type oracle is Rigor's *own, healthy* engine analysing the
user's mutated bytes. For Product C the mutated bytes **are the engine**. If the type oracle
were the worktree's own `exe/rigor` (which loads the mutated `lib/rigor`), a mutation could
break the checker itself — at best a crash (uninformative kill), at worst a silently wrong
oracle (false survivor / false kill). **The type oracle MUST be an independent Rigor.**
Two ways, with a real tradeoff:

- **(a) mise / released `rigor`** (the maintainer's suggestion). Truly independent, always
  available, never breaks. *Cost:* version skew — a released oracle lacks the worktree's
  in-development diagnostic rules, so a mutation a *new* rule would catch reads as a type
  survivor (it is one, for that oracle). Fine for robustness/fuzz; underestimates teeth on
  new rules.
- **(b) a pristine snapshot of the worktree's own `HEAD`** built to a separate prefix (a
  clean `git worktree` / a built gem). Rule-for-rule parity with what is being developed;
  the mutation is applied only to the *copy under check*, never to the oracle. *Cost:* must
  rebuild the oracle when measuring newly-added rules.

**Recommendation:** default to **(b)** for the parity that "do my self-check rules have
teeth" demands; keep **(a)** as the cheap, always-on fallback for broad-fuzz / robustness
runs where exact rule-parity does not matter. Either way the oracle is a **subprocess**
(`rigor check <file> --format json --no-cache`), so the driver process never has to load the
mutated code. Guard the invariant with a startup self-test: confirm `oracle_rigor_path` is
not inside the worktree, and that the oracle still runs after mutating a checker-internal
file.

The **RSpec axis has no bootstrap hazard worth special handling**: the mutant *is* the
system under test, exactly as in classic mutation testing. It runs in a fresh `rspec`
subprocess that loads the mutated disk bytes; the long-lived driver loaded clean Rigor once
at startup and is unaffected by the temporary on-disk change (eager-load `lib/rigor` at
startup so no lazy `require` pulls in a mutated file mid-run).

## Architecture

```
driver (worktree tool/mutation/, loads clean Rigor once)
  ├─ Mutator (lib/rigor/protection/mutator.rb)   ── reused; + semantic operators (new)
  ├─ type oracle  = subprocess: <independent rigor> check <mutant> --format json   (decoupled)
  └─ test oracle  = TestSuiteOracle, runner = `bundle exec rspec <coverage-selected specs>`
                    in RIGOR's OWN bundle (NOT with_unbundled_env — see gotcha)
fused classify per mutation: type-killed | test-killed | unprotected(+crash bucket)
```

The fused classification reuses ADR-70's gradual short-circuit: **try the type oracle
first**; only type-survivors reach the (expensive) test oracle. A line is an implementation
hole iff **neither** axis kills its mutants.

## Efficiency — the 80 % is test selection, and the sound lever is coverage

Mutation cost is suite execution, not mutant generation. Running Rigor's ~6,300-example
suite per mutant is the `mutant` graveyard. Levers, in order:

1. **Gradual short-circuit (free, ADR-70).** Every mutant the self-check kills never runs a
   spec. On `lib/rigor` the type axis already kills ~70 %+, so the test axis runs on the
   residual only.
2. **Coverage-guided test selection — the load-bearing efficiency move.** For a mutation at
   `lib/rigor/foo.rb:42`, run only the specs that *execute* line 42. Build the inverted
   index `{lib_file:line → [spec_files]}` once (the suite already supports
   `Coverage.start(lines: true)` under `COVERAGE=1` in `spec_helper.rb`; run it per spec
   file, or once with file-granular coverage). This is **runtime coverage, not the static
   dependency graph** — ADR-71 §critical-3 is explicit that a static graph for test
   *selection* over-approximates and, worse, manufactures **false survivors** (it misses the
   metaprogramming/`send` paths a test actually exercises). For Rigor's own suite the sound
   choice is unambiguous: use coverage. Convention tier first (`lib/rigor/a/b.rb` →
   `spec/rigor/a/b_spec.rb`), coverage index as the precise fallback.
3. **Stop at first failure.** One red covering spec kills the mutant; don't run the rest.
4. **Diff-scoped runs for CI.** On a PR, mutate only the changed `lib/` files (the
   `changed_ruby_files` helper already exists) and coverage-select their specs — "mutation
   testing you can run on every PR", ADR-71's surviving wedge, here justified because it is
   *Rigor's own* repo (no external-product support burden). Advisory, non-blocking at first.
5. **Per-mutant timeout** (a mutation can induce an infinite loop) — `tool/mutation` fuzz
   mode already has the timeout plumbing.

## Comprehensiveness — semantic operators for the behaviour axis

The shipped operators (`nil_inject` / `type_swap` / `undefined_method` / `arity_extra`) are
engineered to trip **diagnostic rules** — right for the type axis, thin for the RSpec axis
(`undefined_method` renames to a guaranteed `NoMethodError` that crashes before any
assertion: a low-information kill). For "do my *tests* have teeth" we need classic
**runnable, behaviourally-distinct** operators, added behind ADR-69's **operator seam**:

- relational/equality flips (`<`↔`<=`, `>`↔`>=`, `==`↔`!=`), boolean (`&&`↔`||`),
  truthiness (`true`↔`false`, condition negation),
- arithmetic (`+`↔`-`, `*`↔`/`), literal/constant tweaks (`n`→`n±1`, `0`↔`1`, `""`/`nil`),
- statement / `return` / argument deletion.

For the **type axis keep the type-aware filter** (only biteable sites can be type-killed;
ADR-62's de-noising holds). For the **RSpec axis do *not* filter by type** — type-invariant
mutants are exactly the behaviour-shaped bugs the suite must catch — but exclude
non-behavioural regions (logging strings, `frozen_string_literal`, comments) to cut
equivalent-mutant noise. Note honestly (ADR-62 framing): the type lattice only proves
equivalence for its own sliver; the dominant equivalent-mutant classes (never-hit
boundaries, commutative reorderings) are semantic and will show as survivors needing
adjudication, not automatic holes.

## Phased plan (easiest-first; reuse vs new)

| # | Phase | Reuses | New |
| --- | --- | --- | --- |
| 1 | **Type-axis baseline + backlog** on `lib/rigor` | `mutate.rb sweep` (whole machinery) | re-run + cluster survivors (the 2026-06-13 backlog, refreshed at v0.2.0) |
| 2 | **Independent type oracle** (decouple) | `DiagnosticOracle` shape | subprocess oracle to mise/clean-HEAD rigor + the non-worktree invariant self-test |
| 3 | **Semantic operators** | operator seam (ADR-69) | the operator set above + non-behavioural-region exclusion |
| 4 | **RSpec axis + coverage selection** | `TestSuiteOracle` | the `{line→specs}` coverage index, convention tier, stop-at-first-failure, own-bundle runner |
| 5 | **Fuse + attribute + CI** | `FusedProtection*` accumulator/renderer, `changed_ruby_files` | per-site `add-a-spec / add-a-type` attribution over `lib/rigor`; diff-scoped advisory CI job |

Phase 1 is runnable today and produces value immediately (the self-check hole list).
Phases 2–4 are independent and can land in any order; Phase 5 is the payoff (the fused map).

## Gotchas / risks (record before building)

- **Bundler-env divergence (opposite of ADR-70).** `TestSuiteOracle#shell_run` wraps the
  command in `Bundler.with_unbundled_env` because for a *user* project the SUT bundle ≠
  Rigor's bundle. Mutating Rigor itself, the SUT bundle **is** Rigor's bundle —
  unbundling would break `bundle exec rspec`. Inject a custom `runner:` (or add a flag) that
  runs the suite **in Rigor's own bundle**. Concrete, easy to get wrong.
- **Disk-write safety.** The test axis writes the mutant to `lib/rigor/…` on disk and
  restores in `ensure`; an interrupt mid-suite leaves a mutant. Run the whole sweep in a
  **dedicated `git worktree`** (so the working clone is never touched) and add a `trap` that
  `git checkout`s the file on abort — belt-and-suspenders over the existing `ensure`.
- **Load-time crashes ≠ teeth.** A mutation that makes `lib/rigor` fail to *load* errors
  every spec (a trivial "kill") and crashes the type oracle subprocess. Bucket these as a
  **`crash` class** (robustness signal, like fuzz mode's zero-crash result) — not a
  meaningful test/type kill, and not an implementation hole.
- **`runner_pool_spec` exclusion.** It runs as its own process (`make test-ractor-pool`,
  excluded from the default suite) and spawns workers/Ractors — never include it in a
  per-mutant selection; coverage-scoped selection naturally avoids it.
- **Oracle version skew** (Phase 2 decision above) — clean-HEAD snapshot for rule-parity,
  mise release for availability.
- **Encoding.** Byte-splicing a non-ASCII file under the Flake's US-ASCII default external
  encoding raises — read sources as `Encoding::UTF_8` (already handled in `mutate.rb`).
- **Self-check baseline is clean** (`make check` is a gate and stays at zero), so the type
  axis baseline is empty — any new diagnostic is unambiguously a kill. No baseline drift to
  subtract.

## Relationship to the ADRs

This is **C** in the strategy note's product taxonomy: it reuses ADR-69's seams and ADR-70's
fused map, and it is the *internal-target* sibling of ADR-71 — but it **escapes ADR-71's
deferral**, because ADR-71 deferred an *external general-purpose* tool (the 80 % test-runner
graveyard on other people's suites). Pointed at Rigor's own repo, the 80 % is just *our*
suite, the test-selection lever is unambiguously sound (coverage, not the static graph), and
there is no external support surface — exactly the conditions ADR-71 said the wedge needs.
It also stays off the ADR-50 frozen public surface (a dev harness, like ADR-62 WD4). If the
fused-inward map proves its keep, it feeds a future ADR ("self-mutation testing of
`lib/rigor`"); until then this note is the living tracker.

One-line takeaway: **the type half already ships; the new work is the RSpec axis +
coverage-guided selection + an independent (mise/clean-HEAD) type oracle, fused into a
per-site "add a spec / add a type" map of Rigor's own implementation holes.**
