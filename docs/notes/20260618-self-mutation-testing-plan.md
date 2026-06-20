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

## First implementation + run (2026-06-18)

Phases 1, 3 (existing operators), and 4 (tier-0 selection) landed as a first cut:
`tool/mutation/self_mutate.rb` — a thin driver over `Protection::{MutationScanner,
TestSuiteOracle}` adding exactly the two Product-C-specific pieces (an **in-bundle** test
runner; **convention** spec selection `lib/rigor/a/b.rb → spec/rigor/a/b_spec.rb`), plus the
disk-restore safety (dirty-tree guard + `at_exit`/signal `git checkout`). The type oracle is
the in-process worktree engine — reconsidered and confirmed sound here: the engine is loaded
clean once and a mutation is only ever analysed *input* (the type axis never writes to disk),
so the bootstrap hazard does not bite this fused measure. The independent (mise/clean-HEAD)
oracle remains the right move for the broad-fuzz/robustness variant.

**Type-axis backlog refreshed** (`mutate.rb sweep lib/rigor --per-file 8`): 310 files, 1,751
mutants, **teeth 73.4 %** (was 71.4 % on 2026-06-13), 465 survivors — top clusters still the
deferred ADR-24 self-dogfood ones (`Type::Constant#value` 37, the `MethodCatalog` singleton).

**Fused axis works and finds real holes.** `ci_detector.rb`: type-killed 3, test-killed 14,
**0 holes** (100 % fused) — the test axis genuinely kills the `Dynamic`-site mutations the
type checker cannot. `trinary.rb`: surfaced **9 unprotected sites** the dedicated
`trinary_spec.rb` did not exercise — `#hash` / `#to_s` / `#inspect`, the `new(:invalid)`
`ArgumentError`, and `coerce`'s `TypeError` branch (reached via `#and`/`#or` with a
non-Trinary). All adjudicated as genuine missing tests, not dead code; the harness correctly
did **not** flag `.from_symbol(:wat)` (already tested). **Loop demonstrated**: adding the four
missing `trinary_spec.rb` examples drove `trinary.rb` to **0 holes / 100 %** (test-killed
12 → 21) — find → fix → re-measure-kill.

Confirmed in passing: the **bundler-env divergence** is real and load-bearing (a
`with_unbundled_env` runner makes `bundle exec rspec` fail on Rigor's own suite — the
in-bundle runner is required), and the **scoped-spec completeness caveat** holds (a hole is
relative to the *convention* spec; the broader suite may cover it — tier-1 coverage indexing
is the refinement). `tool/**` is rubocop-excluded, so the dev harness is off the lint gate
like its `mutate.rb` sibling.

**Remaining (unchanged from the plan):** semantic operators (Phase 3 proper — the current
set is runnable but diagnostic-shaped), the `{line → specs}` coverage index (Phase 4 tier 1,
to replace convention selection and fix the completeness caveat), the independent subprocess
oracle (Phase 2), and the diff-scoped advisory CI job (Phase 5).

## Whole-tree coverage-gap backlog sweep (2026-06-18)

The per-mutant fused mode cannot scale to the whole tree (each type-survivor boots a fresh
`rspec`; process startup dominates). The efficient pass — `self_mutate.rb --coverage-gap` —
classifies the cheap in-process type-survivors against a one-shot **suite line-coverage
index** (`COVERAGE_JSON` from `spec_helper`, full sequential suite once: 309 files, 23,530
executed lib lines). A type-survivor whose code the suite never ran is a high-confidence hole
with **zero** `rspec` runs. Scope: the 276 `lib/rigor` files ≤ 400 LOC (the 34 larger engine
files deferred — `:all` re-analysis cost ∝ dispatch-site count).

**Adjudication de-noised the metric twice — the load-bearing methodology lesson.** The raw
result was alarming and wrong:

| classifier | "holes" | what it was |
| --- | --- | --- |
| raw line-coverage | **1,969** | mostly false |
| + method-coldness | 214 | def-level artifact removed |
| + class-body exclusion (def-anchored) | **22** | trustworthy |

Two coverage artifacts, both found by *reading the top survivors* rather than trusting the
count (the ADR-62 "adjudicate, don't assume" discipline):

1. **Multi-line expression attribution.** Ruby line-coverage credits a multi-line
   expression's execution to its *first* line, so continuation lines read as uncovered even
   when the expression runs — `Diagnostic#to_h` is tested, yet its hash-literal entry lines
   (144–149) were all flagged. Fixed by anchoring on **method coldness**: a hole only when
   the enclosing `def` is *entirely* uncovered (a never-run method), so every site in a warm
   method is covered.
2. **Class-body data constants.** `bundle_sig_discovery`'s frozen `Set[…]` of stdlib names,
   `method_parameter_binder`'s `RBS_TYPE_PROVIDERS` hash-of-lambdas, the builtin catalogs'
   `for_topic` constant — all suffer (1) with no `def` to anchor on, and are *data* not
   logic. Excluded: a site with no enclosing `def` is never a high-confidence hole. (The
   signal is trustworthy only inside method bodies — the precision/recall trade for a backlog
   we act on; cold *branches* inside warm methods live in the `needs-verification` tier.)

**Result — the small-file core is method-level complete.** All 22 trustworthy holes were in a
**single** file, `lib/rigor/cli/mcp_command.rb` (the ADR-33 MCP command): its
`#run` / `#parse_options` had no unit spec at all. Every other ≤400-LOC `lib/rigor` file has
no entirely-cold type-blind method — Rigor's unit suite exercises essentially every method
(the `trinary` gaps above were among the few, now closed). **Loop closed**: a 5-example
`spec/rigor/cli/mcp_command_spec.rb` (option parsing + the transport-validation / usage-error
branches of `run`; the long-running stdio server loop is integration territory, deliberately
not unit-tested) drove `mcp_command.rb` to **0 cold-method holes**.

**The `needs-verification` frontier (~10.5k).** Type-survivors on *covered* lines —
covered ≠ asserted. This is the larger test-*effectiveness* gap (a spec runs the line but no
assertion catches the mutation), but it is a mix of real cold-branch gaps and the same
multi-line artifacts, and adjudicating it needs the expensive per-file fused `rspec` pass
(the `trinary` pattern, run file-by-file). Deferred to targeted fused runs rather than a
whole-tree blast.

**Whole-tree completion.** The 34 engine files > 400 LOC (incl. the 3,387-LOC
`statement_evaluator`, `scope_indexer`, `scope`, the plugin core) were then swept the same
way: **0 cold-method holes**. So across all 310 `lib/rigor` files the only def-anchored
cold-method gaps were `cli/mcp_command.rb` and `trinary.rb` — both now closed. **Rigor's unit
suite is method-level complete**: every method in `lib/rigor` is executed by some spec. (The
type-blind-method backlog is the cheap, high-confidence tier; it is now drained.)

**Deferred:** the `needs-verification` adjudication (the covered-but-not-asserted
effectiveness frontier — per-file fused runs, demonstrated below), and the Phase 2/3/4-tier1/5
items above.

## Effectiveness-tier adjudication — fused per-file (2026-06-18)

With the cold-method tier drained, the remaining signal is the `needs-verification` frontier:
type-survivors on *covered* lines — a spec runs the line but no assertion catches the
mutation. The fused per-file mode adjudicates it directly (type pass, then the covering spec
on each type-survivor; a survivor of both is a real effectiveness gap). First worked example,
`type/integer_range.rb` (a clean value object) vs `integer_range_spec.rb`:

- **11 unprotected** initially (type-killed 8, test-killed 34, **79.2 %** fused).
- Adjudicated: `#finite?` (L54) and `#cardinality` (L58) were genuinely unasserted public
  logic methods — the spec built ranges and tested construction / `describe` / `covers?` /
  acceptance but never asserted finiteness or the integer count. `#inspect` (L116) likewise.
  The `validate_bound!` survivors (L35–36) are the **label string argument** (`"min"` /
  `"max"`) — mutating only the *error-message text*, which Rigor's own discipline treats as
  presentation, not contract — i.e. **equivalent mutants**, correctly left.
- Closed the three genuine gaps (`finite?` / `cardinality` / `inspect` examples) →
  **4 unprotected, 92.5 %** (test-killed 34 → 41). The 4 residual are exactly the
  message-text label mutations — the effectiveness tier converges on a clean equivalent-mutant
  floor, not a zero.

This is the same find → adjudicate → fix → re-measure loop as the cold-method tier, but the
adjudication is sharper: most `needs-verification` survivors are either equivalent mutants
(message text, commutative reorderings) or covered-by-a-broader-spec, so the tier is worked
**per file on demand**, not swept whole-tree (which would mostly count noise). The harness
gives the per-file unprotected list; a human decides genuine vs equivalent.

A second batch fused eight core files at once (`type/{tuple,hash_shape,difference,
accepts_result,bound_method}`, `inference/synthetic_method`, `analysis/{baseline,
dependency_recorder}`): type-killed 111, test-killed 381, **35 unprotected**. Adjudicated and
closed the genuine logic gaps:

- `analysis/baseline.rb` (13 → 1): the user-facing `.rigor-baseline.yml` loader's malformed
  -input surface — non-Hash top level, non-Array `ignored:`, non-Hash row, missing `rule:`,
  invalid `message:` regex, message-mode `to_yaml` round-trip. The pass also caught an
  *under-asserted existing test* (unknown `match_mode` checked only the error class, leaving
  the message-text mutation alive) — strengthened in place rather than duplicated. Residual 1
  = the message-mode `bucket_key` branch in `#filter`/`#audit`.
- `inference/synthetic_method.rb` (4 → 0): the `method_name` and `provenance` validation
  branches (`class_name`/`return_type`/`kind` were already tested).
- `type/difference.rb` (4 → 1): `#dynamic` (the lattice delegate) had no caller; residual 1
  is the `#inspect` debug-format site.

Left as documented low-value residual (not closed): the carrier `#inspect` / `describe(:short)`
debug-format sites (`tuple`, `bound_method`, `accepts_result`, `difference`) and the
`hash_shape` raise branches — pinning a debug string is brittle and inspect/message text is
not contract (the same FP-discipline, applied to test-writing: don't add low-value assertions
just to move a metric). `dependency_recorder` was already 0.

**Cumulative this session:** `trinary` (9 → 0), `cli/mcp_command` (22 → 0, new spec),
`type/integer_range` (11 → 4-equivalent), `analysis/baseline` (13 → 1),
`inference/synthetic_method` (4 → 0), `type/difference` (4 → 1). Whole-tree cold-method backlog
empty; the effectiveness tier is a per-file, adjudicate-each workflow — most survivors are
equivalent mutants (message/inspect text), covered-by-a-broader-spec, or genuine gaps now
closed. Each tier converges on an equivalent-mutant floor, not zero.

## Effectiveness-tier adjudication — second per-file batch (2026-06-18)

A further pass over six logic-bearing files; same find → adjudicate → fix → re-measure loop,
all six spec-only (no `lib/` change), `make verify` green:

- `analysis/run_stats` (6 → 0): the Linux `/proc/self/status` `VmHWM:` parser
  (`read_vmhwm_from_proc`) — the existing `.peak_rss_bytes` test only asserts a non-negative
  integer, so the line filter, digit extraction, and kB→byte scale survived even on Linux CI.
  Closed with stubbed-`File` unit tests asserting the *exact* parsed value (and the not-readable
  / no-`VmHWM` nil paths).
- `analysis/fact_store` (11 → 0): three untested validation branches (`Fact.new` bad bucket,
  `join` non-FactStore guard, `normalize` non-`Fact` element — a mutated `.class`/`.inspect` in
  the raise path throws `NoMethodError` ≠ `ArgumentError`, so a bare `raise_error(ArgumentError)`
  kills them), the entirely-untested `with_local_fact`, the `==`/`eql?`/`hash` value-equality
  contract, and the deliberate string-bucket `to_sym`/`map(&:to_sym)` coercion leniency.
- `type/app` (2 → 0): `accepts` (delegates to `bound` — pinned against
  `Inference::Acceptance.accepts`) and `reduce` (delegates to a registry with a default-fuel
  wiring — pinned with a minimal fake registry recording the fuel).
- `inference/synthetic_method_index` (4 → 0): `knows_class?` (incl. the `name.to_s` coercion,
  exercised with a Symbol argument) and `to_h` serialisation — both untested.
- `inference/indexed_narrowing` (6 → 0): `.lookup_for_call` and `.invalidate_chain_after_call`
  were only exercised via the integration fixture, not the unit spec; added direct unit cases
  (stable `receiver[key]` lookup + the non-`[]` / multi-arg / no-narrowing nils; chain-narrowing
  drop on a stable receiver + the unstable-outer-receiver no-op).
- `inference/multi_target_binder` (4 → 1-equivalent): the ADR-57 optional-slot softening
  (`X | nil` slot → non-nil constituent) was untested. The residual `:111` `slot_type` site is a
  **confirmed equivalent mutant** — it lives in the no-rest `backs` block, but `back_count =
  rights.size` and post-splat `rights` are non-empty only when `rest_present`, so that block is
  `Array.new(0){…}` and never runs.
- `inference/hkt_body` (16 → 0): the `HktBody` `Data.define` node constructors had partial
  validation coverage — the happy path + the `*-non-empty` / namespaced guards were tested, but
  the `*-must-be-an-Array` / `*-must-be-a-Symbol` / `*-must-not-be-nil` guards were not, and
  `TestEquality` had no describe block at all. Added the missing guard cases (matching the file's
  existing message-fragment style — user-facing validation messages, a defensible contract); the
  message-fragment assertions also kill the `type_swap`-on-raise message-argument mutants.

`inference/{budget_trace,struct_fold_safety,closure_escape_analyzer,rbs_type_translator}`,
`analysis/incremental`, and `type/intersection` were measured and left at
their floor (already 100 %, or only the `percentile` `hist.keys.max` defensive fallback — reached
only when the nearest-rank loop fails to return, which `rank = ceil(fraction·total) ≤ total`
makes impossible — and the `inspect`/`describe(:short)` debug-format residual).

## Effectiveness-tier adjudication — third per-file batch (2026-06-21)

A fused batch over eight more logic-bearing files (`builtins/regex_refinement`,
`analysis/self_call_resolution_recorder`, `config_audit`, `configuration/severity_profile`,
`environment/lockfile_resolver`, `environment/rbs_coverage_report`, `flow_contribution/fact`,
`inference/coverage_scanner`). Six were already 100 %; the eight survivors clustered in two
files, both spec-only fixes, `make verify` green:

- `config_audit` (6 → 0): `explicit_path_warnings`'s three `add_missing_dir`/`add_missing_file`
  call sites. The tests asserted each warning's `kind` and the descriptor substring
  (`is not a directory` / `does not exist`) but not the config-key label embedded in the
  message, so the `:bundler_bundle_path` / `:bundler_lockfile` / `:rbs_collection_lockfile`
  KEY argument (the human-readable `"bundler.bundle_path"` etc.) survived `nil_inject` /
  `type_swap` — the `kind` symbol was already pinned by the `find { kind == … }` lookup, the
  message key was not. The three assertions now also `include` the key label (+ the missing
  message assertion on the `rbs_collection.lockfile` case).
- `environment/lockfile_resolver` (2 → 0): the two `warn` sites in the defensive rescue
  branches — `parse`'s `rescue LoadError` (bundler unavailable) and `do_parse`'s
  `rescue StandardError` (parser raises). Neither was driven deterministically: bundler is
  always loadable in the test env, and a corrupt body's failure mode is Bundler-version-
  dependent (the existing "truly corrupt lockfile" case parses without raising on the current
  Bundler, never reaching the `warn`). Two stubbed tests now force each branch
  (`Bundler::LockfileParser.new` raising; `described_class.require("bundler")` raising
  `LoadError`) and assert the stderr warning (path + error class), killing the
  `undefined_method` mutants on the `warn` calls.

`builtins/regex_refinement`, `analysis/self_call_resolution_recorder`,
`configuration/severity_profile`, `environment/rbs_coverage_report`, `flow_contribution/fact`,
and `inference/coverage_scanner` measured at their floor (already fully protected).

A second 2026-06-21 batch over eight more files (`builtins/predefined_constant_refinements`,
`builtins/static_return_refinements`, `configuration/dependencies`, `environment/class_registry`,
`environment/reflection`, `flow_contribution/conflict`, `flow_contribution/merge_result`,
`inference/builtins/method_catalog`) — four closed to zero, the rest at floor, all spec-only,
`make verify` green:

- `inference/builtins/method_catalog` (4-after-de-noise → 0): the whole `resolve_alias_entry`
  path (the `aliases` section mapping an alias selector to its canonical target) and `reset!`
  were unexercised, and the `FOLDABLE_PURITIES` Set gating `safe_for_folding?` was unpinned
  (no test asserted leaf / trivial / leaf_when_numeric fold while a `dispatch` purity does not).
  A temp-YAML catalog (via a `with_catalog` helper — NOT an `around`+`@path`, which trips
  `RSpec/InstanceVariable`) drives the alias hits, the dangling-target and singleton-bucket
  non-resolution, `reset!`, and one method per foldable purity plus a non-foldable one. The
  line-27 `Set[...]` constant counts as data per the de-noising rule but DID gate behaviour,
  so pinning the purity contract was worth it.
- `environment/class_registry` (5 → 0): `register`'s two guard raises (non-Module naming the
  class; anonymous name-less class) and the entire `class_ordering` / `normalize_name` path
  (equal / subclass / superclass / disjoint / unknown, plus the leading-`::` strip and Symbol
  coercion) were untested — the spec only covered `registered?` / `nominal_for_name`. `register`
  tests use a fresh (non-frozen) `new` registry; ordering uses the `default` built-ins.
- `flow_contribution/conflict` (1 → floor): `to_h` serialises each provenance as `p.to_h` when
  it responds, else `p.to_s`; the to_s fallback (a provenance without `#to_h`) was untested.
  Residual line-68 `require_relative "../analysis/diagnostic" unless defined?(…)` is an
  equivalent mutant — Diagnostic is already loaded in-test, so the guard short-circuits and the
  require never executes.
- `environment/reflection` (1 → 0): `freeze_set`'s `else raise ArgumentError` guard (a
  `known_class_names` that is not Set / Array / Hash) was never driven — `for_project` always
  passes a Set. A direct-construction case asserts the raise (naming the type) plus the
  Array→frozen-Set happy path.

`predefined_constant_refinements`'s `inspect_runtime_string` line-114 `name.split("::")`
`nil_inject` is an **equivalent mutant**: `split(nil)` splits on whitespace, but for the test
inputs (`"Ruby::VERSION"` etc.) `const_defined?` / `const_get` parse the `"::"` themselves, so
resolution is identical; distinguishing it needs a contrived `inherit=false`-sensitive constant
(a brittle, low-value test). `static_return_refinements`, `configuration/dependencies`, and
`flow_contribution/merge_result` measured at their floor.
