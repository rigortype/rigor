# `rigor check lib` allocation attribution — where the 32.4M actually live

Status: measurement note, no design commitments. Observations taken against
`master` @ `4c6b5912` (post-v0.3.0), macOS arm64, Ruby 4.0.5, `RIGOR_DISABLE_YJIT=1`,
2026-07-25. Follow-up to [#207](https://github.com/rigortype/rigor/issues/207).

## Why

[#207](https://github.com/rigortype/rigor/issues/207) was filed on the premise that the
five [#101](https://github.com/rigortype/rigor/pull/101) diagnostic rules ran as
standalone AST walks, and that folding them into the shared `RuleWalk` would recover a
chunk of the v0.3.0 allocation drift (`lib` self-check 22.24M → 32.40M, +45.7%). That
premise was wrong: four of the five were already `RuleWalk`-hosted, and folding in the
one rule that was not (`static.value-use.void`,
[#210](https://github.com/rigortype/rigor/pull/210)) bought −158k (−0.49%). The
traversal-sharing lever is exhausted.

This note answers the question that replaced it: **of the 32.4M allocations
`make bench-perf` measures, which code allocates them?**

## Method

The unit is `GC.stat(:total_allocated_objects)` over an in-process
`rigor check --no-cache --no-stats --format json lib`, i.e. exactly what
`tool/bench.rb` measures. `parallel.workers` defaults to `0`, so the run is sequential
in one process and the parent's counter sees everything — no fork-child accounting gap.

Three independent instruments, all of them **outside `lib/`** (`Module#prepend` from a
scratch script; nothing in the tree was edited):

1. **Exclusive phase accounting.** Wrap pipeline regions, charging each its own
   allocations minus those of nested instrumented regions. Recursive phases
   (`propagate`, `walk_class_ivars`) carry an outermost-only re-entrancy guard, without
   which they double-count once per recursion level.
2. **Allocation-site census.** `ObjectSpace.trace_object_allocations` with `GC.disable`
   over a scoped window, so every object allocated in the window survives to be counted
   and the usual "only live objects are visible" bias is removed. Aggregated by
   `file:line`, by allocating method, and by class.
3. **Whole-process A/B.** Suppress one component, re-run the *whole* unmodified
   benchmark, diff allocations and diagnostics.

### Instrument validation

The probe must not perturb what it measures, and it must be able to report a signal:

- `GC.stat(:total_allocated_objects)` is allocation-free: 100k calls cost 2 objects.
  The probe uses parallel scalar stacks (no frame object), frozen `String` labels,
  `Integer` accumulators, and fixed-arity wrappers on the per-node path — a `*args`
  splat there would have added one `Array` per visited node.
- **Neutrality**: uninstrumented run 32,433,047; fully instrumented run 32,275,907
  (−0.49%, inside the run-to-run band). The probe does not pay for itself.
- **Sensitivity**: the per-collector probe fires on collectors it reports as ~zero
  (`DuplicateHashKeyCollector` 2,344 visits → 8,122 allocations;
  `ReturnInEnsureCollector` 318 visits → 14). A zero here is a measured zero, not a
  probe that never ran.
- **Agreement between independent instruments** is the load-bearing check. The
  fine-grained phase probe put the second stub pass at **7,842,517**; the whole-process
  A/B, which shares no code with it, put the same component at **7,839,4xx** — a 0.04%
  disagreement. Two instruments of different design converging is what licenses the
  headline.

Each row below is a percentage **of its own instrumented run's total**, because the
runs are separate (totals ranged 32.28M–33.35M depending on probe weight). Absolute
figures are not additive across rows; the percentages are.

## The result

**One file, `lib/rigor/analysis/baseline.rb`, is charged 18.03M of the run's 32.4M
allocations — 55.8%.** Per-file cost is brutally skewed: mean 90,133, median 11,927,
and `baseline.rb` at 343 lines is 1,500× the median.

It is not `baseline.rb`'s fault. The cost is a **one-time lazy build**, charged to
whichever file first forces it. `baseline.rb` is simply the first file `rigor check lib`
analyses (alphabetically first under `lib/rigor/analysis/`).

Scaling test — one file, N classes each with an ivar-writing ctor:

| classes | allocations |
| --- | --- |
| 0 | 200,718 |
| 1 | 17,999,642 |
| 2 | 18,000,089 |
| 5 | 18,001,189 |
| 20 | 18,006,652 |
| 100 | 18,035,854 |

Marginal cost per class ≈ **360**. The first class costs **17.8M**. A file with an
*empty* class body costs 200,922 — the trigger is typing anything inside a class body,
which is what forces `RbsLoader#instance_definition` → `#build_env`.

### What the 17.8M is

Allocation-site census over the minimal one-class fixture (14.5M of 18.0M objects
enumerable, 80.8% — see limitations):

| site | objects |
| --- | --- |
| `rbs-4.0.3/lib/rbs/substitution.rb:25` | 3,196,786 |
| `rbs-4.0.3/lib/rbs/ast/type_param.rb:119` | 3,145,904 |
| `rbs-4.0.3/lib/rbs/substitution.rb:13` | 1,595,358 |
| `rbs-4.0.3/lib/rbs/substitution.rb:27` | 1,590,733 |
| `rbs-4.0.3/lib/rbs/types.rb:173` | 1,582,197 |
| `rbs-4.0.3/lib/rbs/parser_aux.rb:31` (`_parse_signature`) | 923,414 |
| `rbs-4.0.3/lib/rbs/definition_builder.rb:349` | 211,650 |

By class: `Array` 6.32M, `Hash` 3.52M, `Enumerator` 1.65M, `RBS::Substitution` 1.60M.
This is RBS's own `DefinitionBuilder` doing generic type-parameter substitution
(`Substitution.build`'s `vars.zip(types).to_h`), not Rigor code.

The Rigor-side trigger is a single call site — `Environment::RbsLoader.build_env_for` →
`.stub_missing_referenced_types` (`lib/rigor/environment/rbs_loader.rb:158`), the
[ADR-5](../adr/5-robustness-principle.md) second robustness tier. It detects
referenced-but-undeclared types by **building every project class, instance and
singleton side, with a throwaway `RBS::DefinitionBuilder`**, reading the missing name
out of the raised `NoTypeFoundError`, appending an empty stub, and looping to a
fixpoint (`MAX_STUB_PASSES = 5`).

Per-pass, on this repo:

| pass | project `class_decls` built | missing types found | allocations |
| --- | --- | --- | --- |
| 1 | 1,915 | 1 (`Inference::VoidOrigin`) | 7,833,818 |
| 2 | 1,917 | 0 | 7,842,517 |
| | | **total** | **15,676,335** (87.3% of the one-time burst) |

Pass 2 rebuilds all 1,917 classes from scratch to discover nothing. It exists only
because pass 1 found something.

## Attribution table

Percentages of each instrumented run's own total (≈32.4M).

| region | share | notes |
| --- | --- | --- |
| **One-time RBS environment build** | **54.2%** | charged to the first file with a class body |
| — `stub_missing_referenced_types` pass 1 | 24.2% | ADR-5 tier-2 detection proper |
| — `stub_missing_referenced_types` pass 2 | 24.2% | confirmatory; finds nothing |
| — rest of `build_env` | 6.6% | RBS signature parse, `resolve_type_names`, namespace synthesis |
| **Per-file typing — `StatementEvaluator`** | **29.1%** | the actual inference work, 346 files |
| `MainPassCollector#visit` | 5.0% | every main-pass rule, incl. `call.raise-non-exception` |
| outside `analyze_file` | 3.4% | CLI, config, project scan, output |
| other `ScopeIndexer` pre-passes | 2.5% | ivar / cvar / global / constant / method indexes, all files but the first |
| `RuleWalk` traversal itself | 2.0% | the shared DFS, dispatch and `Context` descent |
| `ScopeIndexer#propagate` | 1.8% | |
| Prism parse | 1.2% | |
| pre-#101 collectors | 0.62% | always-truthy 0.41%, ivar-write 0.10%, void-value-use 0.07%, dead-assignment 0.04%, unreachable-clause 0.001% |
| **the #101 rules** | **0.23%** | see below |
| `filter_suppressed` + self-undefined + explain | 0.08% | |

### The #101 rules, itemised

The question [#207](https://github.com/rigortype/rigor/issues/207) was filed to answer:

| rule | allocations | share |
| --- | --- | --- |
| `suppression.*` (comment scan + marker diagnostics) | 65,673 | 0.20% |
| `flow.duplicate-hash-key` (2,344 visits + builder) | 8,470 | 0.026% |
| `flow.shadowed-rescue-clause` (318 visits + builder) | 1,666 | 0.005% |
| `flow.return-in-ensure` (318 visits + builder) | 362 | 0.001% |
| `call.raise-non-exception` | — | inside `MainPassCollector`, not separated |
| **total (measurable)** | **76,171** | **0.24%** |

The five #101 rules cost roughly a quarter of one percent of the benchmark. Nothing
about how they are hosted or traversed can matter at that magnitude. This is consistent
with, and independently corroborates, [#210](https://github.com/rigortype/rigor/pull/210)'s
−0.49% for folding in the one genuinely standalone walk.

## What this does NOT show

- **It does not attribute the v0.3.0 drift.** The 22.24M → 32.40M rise is a comparison
  between two trees, and this session was measurement-only with no git checkout, so no
  A/B against the pre-drift tree was run. What is shown is the *current* composition.
  One negative datum: `stub_missing_referenced_types` landed 2026-06-01 (`15845436`),
  well before the 22.24M baseline was calibrated on 2026-07-15 (`8ed9f756`), so the
  mechanism is not new. Its *cost* scales with the project RBS surface (1,915
  `class_decls`), and whether that surface grew across the ~54 merges was **not**
  measured. Do not read this note as saying the drift is the stub scan.
- **The allocation-site census is a sample, not a census.** `ObjectSpace.each_object`
  reaches 80.8% (one-class fixture) to 85.5% (mid-run window) of the
  `total_allocated_objects` delta; the remainder is VM-internal (`T_IMEMO`, `T_NODE`)
  slots that `each_object` does not enumerate. Site-level ranking is reliable; site-level
  absolute counts are a lower bound. **The phase-level `GC.stat` numbers have no such
  gap** — every headline figure above comes from those, not from the census.
- **`call.raise-non-exception` is not separated.** It runs inside
  `MainPassCollector#visit`'s `case`, so its cost is folded into that row's 5.0%. Below
  the per-collector seam the probe does not resolve.
- **A rule's induced type queries are charged to the rule**, which is the right answer
  for "what would disabling it save", but means a rule's own allocation and the typing it
  forces are not separated.
- **The 3.4% outside `analyze_file`** was measured as a bucket, not broken down.
- **Cross-run variance.** Instrumented totals ranged 32.28M–33.35M with probe weight.
  Shares are good to ≈±2 points; the two large components were pinned by independent
  instruments agreeing to 0.04%.

## Where a lever plausibly is

Measured end-to-end, on the real unmodified `rigor check --no-cache lib`, with
`unresolved_referenced_types` suppressed from pass 2 onward, two runs each:

| | allocations | wall | diagnostics |
| --- | --- | --- | --- |
| unmodified | 32,419,273 / 32,419,278 | 9.64s / 9.53s | 1 |
| pass ≥ 2 suppressed | 24,579,881 / 24,579,823 | 8.73s / 8.73s | 1 |
| **delta** | **−7,839,400 (−24.2%)** | **−0.85s (−9%)** | **byte-identical** |

Diagnostic output compared as serialised JSON: identical, single
`rbs.coverage.missing-gem` row.

That is the measured headroom, and it bounds two candidate directions — neither of
which has itself been measured:

1. **Scope pass N > 1 to the classes that failed in pass N−1.** A fresh stub can expose
   a deeper reference, so a second pass is needed in general — but only over the classes
   whose build previously raised, not all 1,917. The −7.84M above is the headroom for
   skipping pass 2 *entirely*; the cost of a correctly-scoped pass 2 was not measured, so
   the recoverable fraction is somewhere below it, plausibly most of it.
2. **Declare `Inference::VoidOrigin` in Rigor's own `sig/`.** `sig/rigor/scope.rbs:14`
   and `:43` reference `Inference::VoidOrigin`; nothing in `sig/` declares it. That single
   dangling reference is the *only* thing that makes pass 1 non-empty, and therefore the
   only reason pass 2 runs at all. Fixing it would take this repo's benchmark down by the
   same −24.2% — but it is a repo-local sig fix with **zero** effect on any other project,
   so landing it would improve the number `bench/baseline.json` tracks without improving
   Rigor. If it lands, it should land as a correctness fix to `sig/` with the baseline
   recalibrated, and explicitly not be counted as a performance win.

A third direction is visible but unmeasured: pass 1's 7.83M builds definitions for every
project class and **throws them away**; the analyzer then rebuilds on demand through
`RbsLoader#instance_definition` with a different builder. Whether sharing that builder
recovers anything was not tested, and no headroom figure should be attached to it.

The one thing the evidence does settle: **the rule bodies are not where the allocations
are.** 84% of `rigor check lib` is the RBS environment build plus the per-file typing
pass, and every built-in diagnostic rule together is under 6%.

## Reproducing

Nothing was left in the tree. The instruments were scratch scripts using
`Module#prepend`; recreate them from the method list here:

- Phase probe: prepend to `Analysis::Runner#{analyze_file, parse_source, seed_project_scope,
  node_rule_results_by_plugin, explain_diagnostics}`, `Inference::ScopeIndexer.{index,
  build_class_ivar_index, walk_class_ivars, collect_def_ivar_writes, gather_ivar_writes,
  propagate, …}`, `Inference::StatementEvaluator#evaluate`, `Analysis::CheckRules.{diagnose,
  filter_suppressed, suppression_marker_diagnostics, *_diagnostics}`, and each
  `CheckRules::*Collector#visit`.
- Pass probe / A/B: prepend to `Environment::RbsLoader.unresolved_referenced_types`.
- Pin YJIT off (`RIGOR_DISABLE_YJIT=1`) — it arms on a deadline, so a >5s and a <5s run
  are not comparable — and always pass `--no-cache`.
