# Comparative profiling of `--incremental` edit shapes on GitLab

> Grounding recon for PR `perf/incremental-wiring-gaps` (the three incremental
> wiring-gap closures — stat-tier change detection, fork-pool wiring, singleton
> symbol granularity) and the follow-up `perf/recheck-floor-and-bundle-gate` work
> (the fixed closure_analysis floor + the B1 bundle-equality propagation gate).
> Measurements + file:line anchors below are the spec baseline for both.


Worktree `a75adb05` (origin/master, includes PR #85 / ADR-87 null-build floor).
Survey repo `rigor-survey/gitlab` @ `1a15763b5119`, scope `app/models app/controllers`
(1,774 files = 1,225 models + 549 controllers). Config auto-discovered from
`.rigor.dist.yml` (Rails plugins: actionpack, activerecord, actionmailer, rails-routes,
rails-i18n, activesupport-core-ext, devise, sidekiq, dry-types, sorbet). Ruby 4.0.5.

Command shape (per run): from gitlab cwd,
`nix develop <main> -c env BUNDLE_GEMFILE=<wt>/Gemfile BUNDLE_PATH=<main>/vendor/bundle
RIGOR_INCR_TRACE=1 bundle exec <wt>/exe/rigor check --incremental app/models app/controllers`.
Wall/RSS via `/usr/bin/time -l`; phase split, closure, edge-kinds, diags-changed, memo
counters via throwaway env-gated instrumentation in `IncrementalSession` + `Runner`
(`RIGOR_INCR_TRACE`, `RIGOR_BUDGET_TRACE`, `RIGOR_STACKPROF_OUT`). YJIT: unset (real UX) —
armed on a 5.0s deadline (`jit.rb`), so every ≥1-file recheck (all >5s) JITs mid-flight;
the null run (<5s) never JITs. Per-run YJIT state recorded below.

## 0. Baseline prime + null floor

| run | warm | yjit | wall | closure_analysis / baseline | RSS | allocs | snapshot_write |
|-----|------|------|------|------|-----|--------|------|
| cold baseline (full) | false | true | **22.75s** | baseline_full 20.91s (incl. RBS env + seed_fold 0.66s) | 877 MB | 58.5M | 0.34s |
| null recheck (0 changes) | true | **false** | **2.63s** | closure_analysis 0.99s | 378 MB | 2.7M | **0.00s (SKIPPED)** |

Null-recheck phase split (wall 2.63s): closure_analysis 0.993 · snapshot_load 0.235 ·
seed_fold 0.074 (⊂ closure_analysis) · restore 0.070 · change_detect_digest 0.037 ·
change_detect_list 0.010 · closure_compute 0.000 · snapshot_write 0.000. Sum of
instrumented phases ≈ 1.34s; residual ≈ 1.3s is process boot (nix/ruby/bundler + require
rigor + config parse + fingerprint + probe glob), constant across all runs.

**ADR-87 WD3 confirmed**: the zero-change recheck reports `skip_save=true` and
`snapshot_write=0.00s` — the unconditional snapshot rewrite is skipped. The null floor is
genuinely cheap (2.63s, 2.7M allocs, no YJIT).

## 1. Shape comparison (the datum)

All comment/string edits: `diags_changed = 0` (behaviour unchanged). closA = closure_analysis
phase (s), the dominant phase. Wall via `/usr/bin/time`. All warm; all YJIT-fired.

| shape | file | edit | closure | analyze_set | branch | changed_pairs | edge-kinds | diags_chg | closA | wall | allocs |
|-------|------|------|---------|-------------|--------|------|-----------|-----------|-------|------|--------|
| **S1** leaf ctrl | health_controller.rb | comment | **1** | 1 | file_level | 0 | changed=1 | 0/1 | 7.23 | 9.35 | 22.3M |
| **S2** integration | integration.rb | comment | **16** | 16 | symbol_gran | 0 | ancestry=15 +chg1 | 0/16 | 8.83 | 12.18 | 23.6M |
| S2 label | label.rb | comment | 19 | 19 | symbol_gran | 0 | ancestry=18 +chg1 | 0/19 | 9.20 | 11.13 | 27.2M |
| S2 label | label.rb | body (`def self.reference_prefix` `'~'`→`'~x'`) | 19 | 19 | symbol_gran | **0** | ancestry=18 +chg1 | 0/19 | 10.01 | 12.17 | 27.2M |
| **S4** concern | cache_markdown_field.rb (25 includers) | comment | **66** | 66 | symbol_gran | 0 | ancestry=65 +chg1 | 0/66 | 10.43 | 12.68 | 29.7M |
| **S3** max fan-out | application_record.rb | comment | **341** | 341 | symbol_gran | 0 | ancestry=340 +chg1 | 0/341 | 12.83 | 15.07 | 36.4M |
| **S5b** projteam | project_team.rb (anc=0) | comment | 9 | 9 | file_level | 0 | file_level=8 +chg1 | 0/9 | 8.19 | 10.34 | 23.3M |
| S5b projteam | project_team.rb | body inner-comment in **uncalled** method `truncate` | **1** | 1 | symbol_gran | **1** | changed=1 (8 avoided) | 0/1 | 7.90 | 9.84 | 23.0M |
| S5b projteam | project_team.rb | body inner-comment in **called** method `write_member_access_for_user_id` (8 callers) | **9** | 9 | symbol_gran | **1** | **symbol=8** +chg1 | 0/9 | 8.93 | 11.04 | 23.3M |
| **S5a** classmethod | application_record.rb | body `def self.safe_find_or_create_by` (13 callers) | **341** | 341 | symbol_gran | **0** | ancestry=340 +chg1 | 0/341 | 12.15 | 14.04 | 36.4M |

Substitutions (verified with rg + snapshot graph, per task instruction):
- **S2 body** — `integration.rb` is a 7-line thin shell (`class Integration < ApplicationRecord;
  include Integrations::Base::Integration; end`), no method bodies to edit. Kept it for the
  comment/ancestry-fan-out headline; used `Label` (mid-fan-out with method bodies) for the
  body variant. The real Integration behaviour lives in a concern outside the analyzed scope.
- **S5** — the task's `safe_find_or_create_by` is a **class** method (see §6). Ran it as **S5a**;
  added a clean instance-method control on `project_team.rb` (**S5b**, ancestry deps = 0) that
  isolates symbol granularity with zero ancestry noise.
- **S3** — `application_record.rb` has 340 recorded ancestry dependents (the true max is
  `each_batch.rb` at 370, a concern ApplicationRecord includes). S3 wall 15.07s ≪ 30-min box;
  it does NOT degrade to full (341/1774 = 19%).

### Scaling law
Fixed 1-file floor ≈ **7.2–7.9s** closure_analysis (S1 7.23, S5b-uncalled 7.90). Marginal per
closure file ≈ **16–49 ms** (S3: (12.83−7.23)/340 = 16 ms; S4: (10.43−7.23)/65 = 49 ms; varies
with YJIT warmup + file size). The 0→1-file jump is +6.2s (null closA 0.99 → S1 7.23): analysing
*any* file triggers RBS-env/definition materialization + handle-resolution parse + plugin
pre-pass walks that the 0-file null run skips entirely. **The fixed floor dominates every
closure below a few hundred files; closure size is a second-order lever.**

## 2. Phase split (representative warm recheck, S4, wall 12.68s)

closure_analysis 10.434 · snapshot_write 0.298 · snapshot_load 0.245 · change_detect_digest
0.107 · seed_fold 0.096 (⊂ closure_analysis, ADR-85) · restore 0.062 · change_detect_list 0.011
· closure_compute 0.004 · [boot ~1.3s residual].

- **change-detect** (list 0.01 + digest 0.11) re-globs and SHA-256s **all 1,774 files every
  recheck** (`IncrementalSession#digest`, independent of ADR-87 WD1's Cache::Store stat tier);
  cheap now (page-cached) but O(all files).
- **snapshot-load** 0.235s = inflate+Marshal.load of the 3.3 MB snapshot.
- **seed-fold** (ADR-85 WD2) 0.07–0.12s: folds all 1,774 seed bundles, re-walks only changed
  files. **ADR-85 works** — the pre-pass is no longer a bottleneck.
- **snapshot-write** ~0.3s on a changed recheck; 0.00s on the null (ADR-87 WD3).
- **closure-analysis** is 80–90% of the recheck for every shape.

### closure_analysis internals (wall-mode stackprof, step 4)
S2-body (19 files) and S4 (66 files) profiles are near-identical in shape AND absolute:

| frame | S2-body (19f) self% | S4 (66f) self% |
|-------|------|------|
| **Prism.parse** | 21.3% (~2.26s) | 18.8% (~2.29s) |
| Dir.glob | 8.0% | 9.5% |
| IO.binread + IO.read | 11.2% | 12.1% |
| GC (mark+sweep) | 9.2% | 9.2% |
| DryTypes::AliasScanner (plugin walk) | ~7.2% total | ~5% total |
| Sorbet::CatalogWalker (plugin walk) | ~1% | <1% |

**Prism.parse costs the SAME ~2.3s absolute at 19 and 66 files** → parse is a *fixed* cost, not
closure-proportional. It comes from the discovery re-pass + **ADR-85 WD3 lazy def-handle
resolution** (re-parsing the files that *define* the methods the closure calls, to materialize
their AST) + parsing the closure files themselves. Dir.glob (repeated file-set expansion),
per-recheck plugin pre-pass walks (DryTypes/Sorbet scan project files), IO, and GC round out the
fixed floor. **Per-file type inference is NOT the top cost, and repeated callee body-evaluation
is largely deduped (§4).**

## 3. Edge-kind analysis

Three edge kinds populate the closure (`DependencyRecorder`, dependency_recorder.rb:157-190):
- **ancestry** (`ancestry_sources`, symbol=nil): recorded whenever analysis reads a class's
  *declaration/ancestry* — subclassing, `include`, OR a bare-constant reference. File-granular
  ("a superclass edge touches the whole class"). This is *"someone referenced this class"*, far
  broader than textual subclassing — S2 Label's 18 ancestry deps include `issue.rb`,
  `merge_request.rb`, `project.rb`, `user.rb` (they *reference* `Label`, not subclass it).
- **symbol** (`symbol_sources`, `"Class#method"`): a resolved *instance*-method call, recorded at
  method granularity — the ADR-46 slice-4 precision tier.
- **file-level** (`sources`, the coarse union): used only when NEITHER a symbol pair changed NOR
  the file has ancestry deps (S1, S5b-comment).
- **negative** (`missing`): never fired in any shape (0 removed/added files, no appeared symbols).

**Ancestry edges dominate every real-class edit.** Recorded-edge precision means a base class's
closure is smaller than its textual subclass count (Integration: 15 recorded vs 50 textual — the
other 35 resolve via the out-of-scope `Integrations::Base::Integration` concern, not Integration
directly). ApplicationRecord: 340 recorded ancestry deps vs 1,225 models.

## 4. Memo-dedup answer (ADR-84 run-scoped return memo)

`RIGOR_BUDGET_TRACE` counters (single-process, exact — incremental is always `--workers 0`, §5).
The incremental path returns from `dispatch_special_check_mode` (check_command.rb:59) *before*
`write_trace_appendices` (:73), so the native memo profile is never printed — captured via the
instrumentation's `BudgetTrace.snapshot`.

| shape | memo_entries | memo_hits | memo_misses | body_evals | hit rate | refuse_transient |
|-------|------|------|------|------|------|------|
| S2-body (Label, 19f) | 4,787 | 4,092 | 695 | 695 | **85.5%** | 0 |
| S4 (concern, 66f) | 9,697 | 8,259 | 1,314 | 1,438 | **86.3%** | 52 |

**Yes — the ADR-84 run-scoped memo dedups callee body evaluation heavily across closure files
within the run.** Of ~9,700 method-return inferences in the S4 closure, only 1,438 were actual
body evaluations; 8,259 were memo hits (the edited/inherited callees' bodies served from the
run-scoped bucket instead of re-evaluated per calling file). `refuse_transient` (ADR-84 WD3
event-taint gate) fired only 52× on S4, 0× on S2 — the taint gate is not costing meaningful
dedup. This is exactly the cross-file dedup ADR-84 WD2 designed; it is why per-file inference is
not the closure_analysis bottleneck (§2) — **parsing to *get* the callee AST (ADR-85 handle
re-parse) is the residual cost, not re-*inferring* it.**

## 5. Parallelism audit — DEFINITIVE: closure re-analysis is NOT wired to the pool

`run_incremental_check` (`lib/rigor/cli/check_command.rb:189`) constructs
`Analysis::IncrementalSession.new(...)` (**:197**) with no `workers:` and never calls
`CheckRunnerFactory.resolve_workers` / reads `options[:workers]` (the standard path's
`build_check_runner` → `CheckRunnerFactory.build` at :320 does, incremental bypasses it).
`IncrementalSession#build_runner` (`lib/rigor/analysis/incremental_session.rb:406-407`) calls
`Runner.new(...)` with no `workers:` → Runner defaults `workers: 0` (runner constructor) →
`PoolCoordinator#pool_mode?` returns false (`pool_coordinator.rb:79-80`, `@workers.positive?`) →
sequential `analyze_files_sequentially`.

**Empirical confirmation**: S4 recheck with `--workers 4` → closure_analysis **10.449s** vs
without `--workers` **10.434s** (identical, within noise). `--workers` / `RIGOR_RACTOR_WORKERS`
/ `parallel.workers:` are **silently ignored** in `--incremental` mode. Every incremental
closure re-analysis runs single-threaded regardless.

## 6. S5 symbol-granularity verdict

Root mechanism (code + probe): `symbol_fingerprints_for` (incremental_session.rb) computes
per-symbol body fingerprints ONLY from the instance-side `def_sources`/`def_nodes` tables.
Singleton/class methods live in a parallel `singleton_def_nodes` table that it does **not** read.
Probe of `Label`: `reference_prefix` ∈ `singleton_def_nodes` (true), ∉ `def_sources` (false);
instance `to_reference` ∈ `def_sources` (true). Therefore **a class/singleton-method body edit
never produces a changed symbol pair** (`changed_pairs=0`).

Empirical (project_team.rb, ancestry deps = 0, so the closure is *purely* symbol/file-driven —
a clean isolation the graph probe surfaced: sym=8, anc=0, all 8 deps call one method):

| edit | branch | changed_pairs | closure | interpretation |
|------|--------|------|---------|------|
| comment (outside any method) | file_level | 0 | **9** | falls to coarse `dependents` — all 8 file-level callers |
| body: **uncalled** instance method `truncate` | symbol_gran | **1** | **1** | scoped to 0 callers → **8 avoided** (`file_level_would_add=8`) |
| body: **called** instance method (8 callers) | symbol_gran | **1** | **9** | scoped to exactly its 8 symbol callers |
| S5a: **class** method `safe_find_or_create_by` (13 callers, on ApplicationRecord) | symbol_gran | **0** | **341** | changed_pairs=0 → degrades to full ancestry fan-out, identical to a comment edit |

**Verdict:**
- **Instance-method body edits get true symbol granularity** — the closure scopes to *that
  method's* callers. Editing an uncalled instance method re-analyses only itself (1 file, 8
  file-level deps avoided); editing a called one re-analyses exactly its callers.
- **Class/singleton-method body edits do NOT** — `changed_pairs=0` makes them behave *identically
  to a comment edit*: the closure falls to the file's full ancestry/file-level dependents, NOT the
  method's callers. S5a (`safe_find_or_create_by`, 13 callers) re-analysed all **340**
  ApplicationRecord ancestry deps, byte-identical closure to the S3 comment.
- So the answer to the task's question ("does the closure scope to the METHOD's callers or to all
  dependents of the file?") for a *class-method* utility is **all dependents of the file** — the
  symbol tier does not cover singleton methods. This is a concrete, code-anchored gap:
  **extend `symbol_fingerprints_for` (and the `def_sources` lookup in `record_cross_file_method`)
  to singleton methods** to give class-method utilities the same precision instance methods enjoy.

## 7. Summary-gating upper bound (per shape)

ADR-46's deferred "dependency's inferred summary unchanged → skip dependents" tier: for every
comment/string edit here the edited file's public *summary* (method signatures) is unchanged, so
that tier would skip the entire dependent set. `diags_changed = 0` for ALL shapes confirms every
dependent re-analysis was wasted. Avoidable re-analysis = closure − 1 (the edited file must always
be re-checked to *learn* its summary is unchanged):

| shape | closure | diags_changed | avoidable dependents | closA saved (est., ~marginal) |
|-------|---------|---------------|----------------------|------|
| S1 leaf | 1 | 0 | 0 | 0 |
| S5b uncalled (instance) | 1 | 0 | 0 | 0 (already symbol-scoped to 0) |
| S5b comment / called | 9 | 0 | 8 | ~0.3–0.7s |
| S2 integration | 16 | 0 | 15 | ~0.7s |
| S2 label | 19 | 0 | 18 | ~0.9s |
| S4 concern | 66 | 0 | 65 | ~3.2s |
| S3 / S5a app_record | 341 | 0 | 340 | ~5.6s |

Upper bound: a summary-gating tier would avoid up to **340** dependent re-analyses (S3/S5a), 65
(S4), 18 (S2). BUT the wall saving is bounded by the *marginal* per-file cost (16–49 ms), NOT the
fixed floor: S3 would drop ~12.8s → ~7.2s, S4 ~10.4s → ~7.2s, S2 ~9.2s → ~7.2s. The ~7s fixed
floor survives summary-gating entirely.

## 8. Anomalies / notes

1. **The 0→1-file cliff**: null closure_analysis 0.99s vs 1-file 7.23s (+6.2s). Analysing *any*
   file triggers the full per-recheck machinery (env/definition materialization + handle-parse +
   plugin walks) the 0-file run skips. The null floor is not representative of a real single edit.
2. **YJIT confound**: every ≥1-file recheck exceeds the 5.0s deadline → JITs mid-flight; the null
   (<5s) does not. All edit-shape rows are apples-to-apples (all YJIT-fired); only the null differs.
3. **Recorded-edge < textual**: closures are smaller than textual subclass/include counts
   (Integration 15/50, ApplicationRecord 340/1225) — a precision property, gate-sound.
4. **Plugin pre-pass walks recur per recheck**: DryTypes `AliasScanner` (~7% of closure_analysis)
   and Sorbet `CatalogWalker` walk project files every recheck despite ADR-85 WD1 cache threading
   — worth confirming their producers are actually cache-served on the incremental path.
5. **Change-detect digests all 1,774 files every recheck** (`IncrementalSession#digest`, full
   SHA-256, not the ADR-87 WD1 stat tier) — 0.11s now, O(all files).
6. **Singleton-method fingerprint gap** (§6) — the most concrete correctness-adjacent finding:
   class-method edits silently lose symbol granularity.
7. Instrumentation caveat: `RIGOR_BUDGET_TRACE`/stackprof runs have inflated wall (mutex counters
   + sampling); their timings are not used for §1 — only their memo/profile data.

## 9. Ranked levers (which the shapes justify)

1. **Attack the fixed ~7s closure_analysis floor** — it dominates every edit below ~a few hundred
   files (S1–S4, i.e. the overwhelming majority of real edits). Highest-value, evidence-backed:
   - **Cache ADR-85 def-handle AST parses cross-process** (Prism.parse ~2.3s, fixed): resolving a
     called/inherited method re-parses its defining file every recheck. A per-run parse memo
     exists (ADR-85 WD3) but doesn't survive the process; a cross-process AST/handle cache would
     cut the single biggest frame.
   - **Cache/skip per-recheck plugin pre-pass walks** (DryTypes/Sorbet ~8%): verify #prepare
     producers serve from the ADR-85 WD1 store on the incremental path (anomaly 4).
   - **De-duplicate Dir.glob** (~8–9%): the file set is expanded several times per recheck
     (probe, current_files, runner expansion).
2. **Wire the closure re-analysis to the fork pool** (§5) — currently sequential regardless of
   `--workers`. Helps ONLY the marginal per-file cost, so it pays off on large closures (S3: 341
   files, ~5.6s marginal parallelizable) and is neutral on the common small-closure edit (floor-
   bound). A cheap, correct win specifically for base-class/concern edits.
3. **Extend symbol granularity to singleton/class methods** (§6) — closes a precision gap where a
   class-method utility edit degrades to full ancestry fan-out (S5a: 341 files for a 13-caller
   method). Correctness-adjacent and self-contained (fingerprint + `def_sources` lookup).
4. **Summary-gating tier** (§7) — real but second-order: avoids up to 340 dependent re-analyses on
   base-class/concern edits, yet the wall saving is only the marginal per-file cost (bounded by the
   floor it can't touch). Worth it mainly stacked on lever 1, and mainly for the S3/S4 tail.

Levers 1 is the headline: on this corpus a single real edit costs ~9–15s wall of which ~7s is a
fixed, closure-independent floor that neither the shipped symbol granularity (ADR-46) nor a future
summary-gating tier addresses.
