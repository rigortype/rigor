# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.15 released (2026-05-29). v0.1.16 prepared (2026-06-03) — version bumped + `CHANGELOG.md` § `[0.1.16]` sealed; `bundle exec rake release` is gated on explicit user authorisation and has not been run.**

**An unreleased performance / caching / incremental cycle (the planned v0.1.17 "internal-structure review + performance tuning") is in flight on top of v0.1.16 — see `CHANGELOG.md` § `[Unreleased]` for the shipped entries; do not re-summarise them here.** Landed: allocation profiling of `rigor check` on Mastodon + GitLab (notes `docs/notes/20260604-mastodon-allocation-profile.md` + `…-gitlab-plugin-contribution-allocation.md`) → ~−42% allocations on Mastodon + ~−14% wall on GitLab via ADR-44 (per-dispatch / per-narrow allocation churn) and the plugin-contribution de-churn; **ADR-45** the unchanged-project fast path (record-and-validate whole-run cache — unchanged GitLab 2,630 files 113 s → ~2.7 s, ~42×); **ADR-46 design + slice 1a** the per-file incremental successor (cross-file dependency recorder). The cycle has NOT been version-bumped or released.

v0.1.16 lands the full plugin-contract interface-segregation + ergonomics suite (ADR-37/38/39/40), ADR-43 RBS-complete ancestor resolution + the `make check-plugins` gate, the v0.2.0 gate-1 executable evidence (external-plugin fixture + conformance / all-plugins-load / demos-run guards), RBS-robustness synthesis for malformed project `signature_paths:`, and the `rigor-activerecord` missing-schema memoization fix (Redmine −86% memory). Full detail is in `CHANGELOG.md` § `[0.1.16]`; do not re-summarise it here.

Headline realism numbers (measured at the v0.1.12 OSS-realism cut; still current — later cuts added onboarding / `def.override-*` / the plugin-contract suite rather than new full surveys):

| Project | Scope | Before | After | Delta |
|---|---|---:|---:|---:|
| Mastodon | `app + lib` | 789 | 6 | **−99.2%** |
| Redmine | full plugin set | 163 | 79 | −51% |
| GitLab FOSS | `app/{controllers,mailers,workers,services}` | ~670 | ~140 | ~−79% |

The 6 remaining Mastodon errors are unrelated to engine precision: 5 nil-receiver in test fixtures + 1 upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass-narrowing gap (see [`docs/notes/20260528-rbs-upstream-pr-resolv-typeclass.md`](notes/20260528-rbs-upstream-pr-resolv-typeclass.md)).

## Next-session entry point

`make verify` is clean. The **active in-flight work is the ADR-46 incremental-analysis track** (the v0.1.17 perf cycle's headline). Resume there:

**ADR-46 — incremental analysis via a cross-file dependency graph** ([`docs/adr/46-incremental-dependency-graph.md`](adr/46-incremental-dependency-graph.md), § "Staging"). The per-file incremental successor to ADR-45's coarse whole-run cache: edit a leaf controller → re-check 1 file; edit a model → re-check the model + its callers. **Slice 1a landed** (commit `4eccc390`): `Analysis::DependencyRecorder` + the instrumented `Scope#user_def_for` choke point, opt-in via `Runner.new(record_dependencies: true)` → `runner.file_dependencies`, off by default. **Next, in order:**

1. **Finish slice 1.** **Slices 1b + 1c landed.** 1b (the ancestry edge): a `class_sources` map (`class_name → Set<declaring file>`) is built in `ScopeIndexer.accumulate_project_index`, seeded onto the recording scope, and `Scope#superclass_of` / `#includes_of` record the full declaring-file set on resolution (a class reopened across files → consumer depends on every reopening; over-records by design). The same change fixed a latent slice-1a gap — the ADR-44 single-allocation body scopes (`build_user_method_body_scope` / `build_fresh_body_scope`) dropped `discovered_def_sources`, so the method-body edge was silently unrecorded for implicit-self ancestor-resolved calls; both now carry `def_sources` + `class_sources`. 1c (the §2 inversion): `Runner#file_dependents` builds `dependents[X] = { A : A read from X }` on demand from the recorded `sources` sets (frozen, default-proc dropped). The positive discovered-*class* lookup edge (a file depending on `class Foo`'s bare *existence*) is **deliberately not recorded** — it is redundant for the body tier (class appear/disappear/move is a *structural* change caught by the declaration-fingerprint tier in slice 2/3; a bare `Post` reference depends on `Post`'s *methods*, already recorded via `user_def_for`) and its read sites are diffuse (the `discovered_classes` hash is read directly, no single accessor), so it is not worth a choke-point refactor. Off by default, `make verify` green, diagnostics byte-identical. **Still TODO in slice 1:** (a) persist `deps` / `dependents` + per-file diagnostic entries (reuse ADR-45's `Cache::Store#fetch_or_validate`). (b) the **mandatory** `--verify-incremental` cross-check mode (incremental vs full `--no-cache` must be byte-identical — the acceptance gate). The recording + inversion side (1a–1c) is done; what remains is persistence + the verify harness.
2. **Slice 2 — the body tier** (re-analyse `ΔF ∪ dependents` when the declaration-structure fingerprint is unchanged). This is the slice that delivers the MVC win. **Soundness core landed:** `Analysis::Incremental` carries the side-effect-free set algebra — `affected(changed, dependents)` (closure = changed ∪ their dependents) + `changed_files(before, after)` (per-file `Diagnostic#to_h` diff) — and a spec drives real runs to assert the soundness *property* end-to-end (a fingerprint-unchanged leaf body edit confines every diagnostic change to `affected`, leaves unrelated files' cached diagnostics untouched). **Empirical finding:** Rigor's FP discipline means inferred cross-file return types almost never drive a *dependent's* diagnostic (`String#+ Integer`, `Integer#upcase`, `if <inferred-bool>` all stay silent across a file boundary), so `changed ≈ ΔF` for body edits — the dependents re-analysis is conservative insurance, and the leaf-controller → 1-file win is the common case. **Subset-analysis hook landed:** `Runner.new(analyze_only:)` filters `target_files` to the supplied paths while the full-project pre-pass runs over everything (cross-file index stays complete); a subset run's per-file diagnostics are byte-identical to the full run's (`runner_subset_analysis_spec.rb`), and pool mode inherits the filter for free. **In-memory orchestrator landed:** `Analysis::IncrementalSession` composes everything — `#baseline` (full run + recording, caches per-file diagnostics/digests/sources) → `#recheck` (digest-diff → ΔF → `affected` → `analyze_only:` subset run → merge with cached rest). Its spec asserts the acceptance property end-to-end: after a real on-disk leaf edit, `#recheck`'s merged diagnostics are byte-identical (sorted) to a full re-analysis while re-checking only the changed file, and it stays correct across successive edits. `Runner#analyzed_files` exposes the analyzed set; `Incremental.invert` is now shared with `Runner#file_dependents`. **`--verify-incremental` CLI gate landed:** `rigor check --verify-incremental [paths]` runs a baseline (recording) → re-analyzes every-other file as a subset + serves the rest from the per-file cache → asserts byte-identical to a full `--no-cache` run; one-line PASS or differing diagnostics, exit 0/1. Exercises both the subset-analysis and cache-serving paths against the full-run oracle (no edit needed). Verified on Rigor's own `lib` (131/261 files re-analyzed, matches full). `cli_spec.rb` covers it. **Remaining in slice 2:** (a) lift the in-process cache to disk (ADR-45's `Cache::Store#fetch_or_validate`) so the session survives across processes / CI. (b) wire a user-facing `--incremental` *speedup* flag (the gate proves soundness; the speedup flag is the payoff — and is what earns the CHANGELOG headline + manual entry for the whole ADR-46 track). (c) run `--verify-incremental` on Mastodon + GitLab in CI.
3. Slices 3 (structural-tier negative-dependency tracking) + 4 (symbol granularity) per ADR-46 § "Staging".

**Gotcha (recorded in the ADR-46 memory note):** do NOT extract the `Runner#initialize` ivar pre-seeds into a helper — moving `@class_decl_paths_snapshot = {}` etc. out of the constructor hides them from the engine's OWN flow analysis and `make check` self-flags `snapshot.size` as a nil-receiver false positive. Keep them inline; the constructor carries an `AbcSize` disable.

The two strategic levers before the v0.2.0 cut remain (pull when ready, both need their own planning):

1. **v0.2.0 gate 1 — the documented stability commitment for the external plugin contract** (executable evidence landed v0.1.16; the "won't break within 0.2.x" statement remains). See [`docs/ROADMAP.md`](ROADMAP.md) § "v0.2.0 — first evaluation release".
2. **v0.1.17 remainder** — ADR-24 slice 4 (gated `undefined-method` on resolved closed-class self-calls) + further engine-internal precision uplifts; the perf/cache half (ADR-44/45/46) is the cycle's other half and is underway.

Everything else is demand-driven and lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" — pull from there when a concrete need surfaces.

### Reference reading

1. [`CHANGELOG.md`](../CHANGELOG.md) § `[0.1.16]` — the plugin-contract suite + ADR-43; § `[0.1.12]` for the OSS-realism cycle.
2. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — what gates v0.2.0.
3. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the public-vs-internal stability boundary; cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
4. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.

## Queued tracks

### Residual diagnostics

- **Mastodon `app + lib` residue = 6** — 5 are genuine nil-chain bugs in `spec/` fixtures (Mastodon-side, no Rigor work); 1 is the upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass gap. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` is staged — branch push + `ruby/rbs` PR creation are the user's task.
- **Redmine / GitLab FOSS residues** are larger surfaces; each warrants its own survey cycle if the user wants to chase those numbers down.

### Engine-internal (not survey-driven)

1. **ADR-24 slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. See "ADR-24 — implicit-self method-call resolution, remaining" below.
2. **AR scope-body lambda `self`** — `scope :x, -> { select(...).group(...) }` inside an instance lambda still needs the lambda's `self` rebound to the model class. v0.1.12 closed implicit-self class-side resolution for ordinary method bodies; lambda bodies remain. Empirical case in [`docs/notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) § "What is increasing" item 2 / ADR-26 territory.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog (editor mode, LSP capabilities, dry-rb continuations, ADR-10/13/16 follow-ups, performance levers, plugin-contract ergonomics follow-ons) lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" and is the v0.2.x completion target. This section holds only items with engine-internal detail not captured there.

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. Its own FP-evaluation gate ([ADR-24 WD4](adr/24-self-method-call-resolution.md)) — a large new false-positive surface on metaprogramming-dense code, so v1 was deliberately precision-additive only.
- **Non-`Bot` general adoption inside class bodies** — resolved self-call return type is adopted ONLY when it is `Bot`. Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). (`receiver_type` / `method_name` structured fields on `Analysis::Diagnostic` shipped in v0.1.8; the SKILL integration shipped with the v0.1.9 trio.)

### Inference budgets — spec table is unwired; Layer 1 doc hygiene remains

The spec's configurable `budgets:` table ([`docs/type-specification/inference-budgets.md`](type-specification/inference-budgets.md)) is normative-for-v1 but **not wired** — the only operative cutoffs are three hard-coded silent guards (recursion re-entry ≈ depth 1, ancestor walk 100, HKT fuel 64) plus ADR-10 `budget_per_gem`. Survey + the `RIGOR_BUDGET_TRACE` / `RIGOR_HEAP_PROFILE` / `RIGOR_HEAP_TRACE` probes landed 2026-06-03 (note [`docs/notes/20260603-inference-budget-reality-survey.md`](notes/20260603-inference-budget-reality-survey.md)); the probes are reusable.

**Layer 2 resolved, and it was not a budget.** The large-app cost cliff was traced to 4.2 M retained Strings from one unmemoized failure in `rigor-activerecord` (`schema_table_or_nil` when `db/schema.rb` is missing) — fixed in v0.1.16 (Redmine 1518 MB / 173 s → 217 MB / 84 s). `union_size` was refuted as uncorrelated with memory. Budget wiring is now **demand-deferred** — no corpus project demonstrates a budget-shaped cost; if one ever does, re-run the 2a-style distribution probe first ([ADR-41 WD3](adr/41-inference-budget-design.md)).

**Layer 1 (demand-gated doc/spec hygiene, awaits ADR-41 acceptance):** fix the `docs/manual/03-configuration.md` `budget_per_gem` description (it says "time budget in ms, default 1000"; really a method-def **count**, default **5000**); reconcile `recursion_depth` (spec 5 vs the wired depth-1 termination guard — split "termination floor" from "precision-unroll depth"); add `ancestor_walk` (100) + `hkt_fuel` (64) rows to the documented table; author the missing user-facing budget explanation (placement TBD).

### Performance / caching / incremental (ADR-44 / 45 / 46) — in flight

The unreleased v0.1.17 perf cycle. Shipped entries are in `CHANGELOG.md` § `[Unreleased]`; this is the engine-internal resume detail.

- **ADR-44 — per-dispatch / per-narrow allocation churn (LANDED).** `rigor check` is allocation-bound. Body-scope `with_*` chains collapsed into one `Scope.new` (GC runs −29%); `owners_for` / `CallContext` hygiene. **Rejected:** mutable pooled `Scope` / `CallContext` (re-entrant dispatch → silent narrowing corruption → false positives). **Downgraded:** the `ProjectScope` field-regrouping — a Ruby 4.0 object-shape micro-benchmark proved 3–24 ivars all allocate ONE object, so regrouping cuts heap-slot *size*, not allocation *count*; it is a memory-footprint lever only, measure-before-invest. See [ADR-44](adr/44-dispatch-allocation-churn.md).
- **ADR-45 — unchanged-project fast path (LANDED).** Record-and-validate whole-run diagnostic cache (`Cache::Store#fetch_or_validate` + `Descriptor#fresh?`): key on inputs known up front, store the result with the dependency set the run actually read (incl. files plugins read mid-analysis — the Pundit policy hazard), re-digest on the next run. **Coarse by design** — any analyzed-file change → full re-run (this is what ADR-46 refines). `make check` / `check-plugins` run `--no-cache` so the gate never trusts a cached result. Gotchas in the memory note: `@collect_stats` is true by default (can't gate the cache on it; hit → nil stats); lazy `@io_boundary ||=` on a frozen plugin → `FrozenError` (use `instance_variable_get`); cache write/serialize failure is swallowed (never breaks a run). See [ADR-45](adr/45-unchanged-project-fast-path.md).
- **ADR-46 — incremental dependency graph (DESIGN + slice 1a).** The next-session entry point above. Per-file deps recorded at the `Scope` accessor choke point → `dependents` index → per-file cache; soundness gated by a mandatory `--verify-incremental` cross-check. See [ADR-46](adr/46-incremental-dependency-graph.md) + its memory note.
- **CI caching is a near-no-op (measured).** On a code change (the typical CI case) ADR-45's whole-run cache misses, and the intermediate RBS/plugin caches save <1 s on a ~113 s GitLab run; restore/save overhead likely exceeds that. The cache's real win is local dev / editor / re-runs of the same SHA / doc-only PRs. ADR-46 is what makes *CI* fast (re-analyse only changed files + dependents).

### Stdlib RBS coverage-gap pattern

When an upstream `ruby/rbs` RBS gap is surfaced by a single internal Rigor call site, prefer **(a')** an in-source `# rigor:disable` directive + load the library; when it surfaces across multiple call sites or in user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged for an upstream PR — branch push + `ruby/rbs` PR creation are the user's task.

### Smaller queued items

- **Sig-gen `update_existing`** does not collapse sibling parent / child class blocks — `merge_class` resolves each candidate's `class_name` independently, so flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout is out of scope; workaround is to delete the target sig file and regenerate from scratch.
- **`Hash === expr` case-equality narrowing** (`open3.rb:226` shape) — still open.
- **In-memory `Analysis::Runner.run_source(source:, path:, …)` entry point** — bypasses the per-call tmpdir + chdir in `RunnerHelpers#analyze`; ~5 % spec-suite win plus a clean public API for embedders (LSP / editor mode). Demand-driven.
- **Sig-gen remaining gaps after `--params=observed`** — `attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still produce `:untyped_return`; fix is a hand-written sig annotation. Deep chains on untyped receivers → `rbs collection install` or ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin (escalation path A in the SKILL). Documented in `skills/rigor-project-init/references/04-sig-uplift.md` § "Step 5-d".

### Type-coverage uplift — line status (2026-05-23)

Phases 1–4 landed (String / Integer / Float / Comparable / Math / HashShape / Date / DateTime / Time). Remaining items, all **release undetermined** and tracked at full detail in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" → "Type-language / engine":

- **Struct / Data value folding** — ADR-worthy (needs two new carriers); `Data.define` is the likely better first target. `Encoding` value folding is a *permanent exclusion*.
- **`MathFolding` result refinements** — attaching range refinements (`Math.exp` → `positive-float`, `Math.sqrt` / `hypot` → `non-negative-float`) to the value-precise 28-function fold. Demand-driven.
- **Hash `rassoc` shape handler** — the one open low-priority Hash handler; value → `[k, v]` reverse lookup, foldable when every value is a `Constant`. Demand-driven.

## Post-release follow-ups

- **`data/oss-sweep/mastodon-thresholds.json`** — refresh the stored thresholds against the ~6 baseline so the weekly OSS sweep gate is calibrated (the current file is uncalibrated, `max_diagnostics: 999999`).
