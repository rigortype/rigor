# Inference budgets: spec vs. wired reality, and a scale/time survey

*2026-06-03. Survey note — informational, not normative. The spec binds.*

## Question

How large does a project have to be before the inference "budgets"
kick in, and how much do they cost in inference quality vs. wall time?
Probed against the `rigor-survey` corpus, with Mastodon and Redmine as
the large-app anchors.

## Headline finding: the budget *table* is not wired

[`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md)
defines a ten-row configurable `budgets:` table (`recursion_depth`,
`call_graph_width`, `operator_ambiguity`, `union_size`,
`structural_growth`, …). **None of those keys are read by the engine
today.** `grep` across `lib/` finds no `budgets:` config parsing and no
`recursion_depth` / `union_size` / … enforcement; the table is
normative-for-v1 intent, not current behaviour. The `static.*`
incomplete-inference diagnostic family it references is likewise
unwired.

What actually bounds inference today is three **hard-coded, silent,
non-configurable** structural guards plus one real configurable budget:

| Cutoff | Where | Value | On firing | Diagnostic? |
|---|---|---|---|---|
| Recursion re-entry guard | `ExpressionTyper#infer_user_method_return` | depth-1 on `(receiver, method)` | returns `Dynamic[top]` | none (silent) |
| Ancestor-walk cap | `resolve_user_def_through_ancestors` | 100 nodes (BFS) | gives up self-call resolution | none (silent) |
| HKT reducer fuel | `HktReducer#reduce` | 64 steps (ADR-20) | unwinds to `app.bound` | none (silent) |
| **Per-gem source-walk budget** | ADR-10 `dependencies.source_inference` | `budget_per_gem` 5000 (1250–20000) | catalog truncates → `Dynamic[top]` | `dynamic.dependency-source.budget-exceeded` (the only one) |

Only the last is configurable, and it only engages when a project
**opts a gem into `dependencies.source_inference:`** — off by default.

## Reframing "from what scale do budgets trigger"

The spec's budget categories are **per-construct, not per-LOC**. They
fire on code *shape* (recursion, deep ancestor chains, wide unions),
not on total project size. Project size changes the *frequency* of
firing, not a threshold at which a budget framework "activates." The
data below bears this out.

## Survey 1 — scale × wall time (cold `rigor check --no-cache`, sequential)

| project | target files | wall (s) | s / file | peak RSS | diagnostics |
|---|--:|--:|--:|--:|--:|
| erubi | 3 | 0.30 | 0.10 | 120 MB | 3 |
| jbuilder | 14 | 0.37 | 0.026 | 127 MB | 3 |
| haml | 51 | 1.07 | 0.021 | 126 MB | 13 |
| liquid | 64 | 0.69 | 0.011 | 129 MB | 13 |
| rubocop-ast | 99 | 0.90 | 0.009 | 128 MB | 3 |
| kramdown | 55 | 1.25 | 0.023 | 124 MB | 14 |
| **redmine** | 331 | **172.75** | **0.52** | **1518 MB** | 723 |
| **mastodon** | 1219 | **173.01** | 0.14 | 277 MB | 1920 |

Reading:

- Small plain-Ruby gems are flat and cheap: ~0.01–0.02 s/file, ~125 MB,
  regardless of file count up to ~100 files.
- **The two Rails apps are a different regime.** Redmine's 331 files
  cost the *same* wall time as Mastodon's 1219 — Redmine is ~45× the
  per-file cost of `liquid`, Mastodon ~12×. Cost is governed by code
  shape, not file count.
- **Memory diverges sharply**: Redmine peaks at 1.5 GB vs Mastodon's
  277 MB for 4× fewer files. Redmine accumulates a much larger
  inference state — the signature of wide unions / unbounded structural
  growth (precisely the `union_size` / `structural_growth` categories
  the spec wants to cap but doesn't).

## Survey 2 — where inference actually stops (RIGOR_BUDGET_TRACE, --workers 0)

A new opt-in counter (`Rigor::Inference::BudgetTrace`, gated by the
`RIGOR_BUDGET_TRACE` env var; zero overhead when off) tallies each of
the three silent guards. `rigor check` dumps the counts at end-of-run.

| project | recursion-guard | ancestor-walk | hkt-fuel | wall (s) |
|---|--:|--:|--:|--:|
| erubi | 0 | 0 | 0 | 0.30 |
| jbuilder | 126 | 0 | 0 | 0.37 |
| haml | 421 | 0 | 0 | 1.07 |
| liquid | 83 | 0 | 0 | 0.69 |
| rubocop-ast | 0 | 0 | 0 | 0.90 |
| kramdown | 41 | 0 | 0 | 1.25 |
| redmine | 71 | 0 | 0 | 172.75 |
| mastodon | 162 | 0 | 0 | 173.01 |

Reading — **the wired guards are orthogonal to the cost cliff**:

- The recursion guard fires most on **recursive-descent parsers**
  (haml 421, jbuilder 126, liquid 83, kramdown 41) — cheap projects.
  It is detecting genuine `(receiver, method)` recursion and returning
  `Dynamic[top]`, which is *why those projects stay fast*: the cutoff
  is doing its job.
- **Redmine — the slowest project at 172 s / 1.5 GB — fires the
  recursion guard only 71 times, fewer than 1-second `haml`.** Its
  blow-up is *not* recursion-guarded. The expensive work sails past all
  three wired guards uncapped. Mastodon (173 s, 1219 files) fires 162
  times — the count tracks roughly with project size, but stays a tiny
  fraction (one hit per ~7.5 files) and is uncorrelated with the wall
  time: Mastodon and Redmine cost the same 173 s with a 2.3× difference
  in guard hits.
- `ancestor-walk-limit` and `hkt-fuel` never fire anywhere in the
  corpus. The 100-node ancestor cap and 64-step HKT fuel are not
  load-bearing on real code today.

**Conclusion:** the three guards that *exist* fire on small recursive
code and keep it fast; the real performance/memory cliff (large Rails
apps) is governed by the budget categories that *don't* exist yet
(`union_size`, `call_graph_width`, `structural_growth`). Wiring those is
where the leverage is — not tuning the guards we have.

## Survey 3 — the one real budget: `budget_per_gem` (ADR-10)

A trivial project (`lib/x.rb` = `x = 1 + 1; puts x`) that opts
`activesupport` into `dependencies.source_inference:` (`mode:
when_missing`), swept across the configurable range. The analyzed file
is incidental — the measured cost is the gem source-walk.

| budget_per_gem | gem_walk classes | budget-exceeded diag | wall (s) |
|---|--:|--:|--:|
| _(no source_inference)_ | 0 | — | 0.27 |
| 1250 (floor) | 173 | **1** | 0.30 |
| 5000 (default) | 311 | 0 | 0.33 |
| 20000 (ceiling) | 311 | 0 | 0.32 |

Reading:

- This *is* a real, observable budget. At the 1250 floor the walk
  truncates: only 173 of activesupport's 311 walkable classes are
  catalogued (~44% missing), a `dynamic.dependency-source.budget-exceeded`
  warning fires, and calls into the un-harvested surface degrade to
  `Dynamic[top]` — a genuine **quality** cost.
- At the 5000 default the walk **completes** (311 classes), and raising
  the cap to 20000 changes nothing: activesupport's walkable method
  count (lib roots, via `Gem::Specification.find_by_name`) sits below
  5000, so the default already covers it. The knob **plateaus** once it
  exceeds the gem's real surface.
- **Time impact is small** here (0.27 → 0.33 s, ~0.05 s for 311
  classes) because activesupport's walkable surface is modest. The
  budget's reason-for-being is the libraries the default comment cites
  (10 000+-method gems) where truncation matters for both walk time and
  the diagnostic; this corpus has no such opt-in target.
- **Default-off caveat:** this budget only engages under an explicit
  `dependencies.source_inference:` opt-in. The cold corpus runs
  (Surveys 1–2) opt nothing in, which is why `budget-exceeded` appears
  **zero times** across all 25 corpus projects including Mastodon — the
  per-gem budget is dormant on a default run.
- **Bundle caveat:** `find_by_name` resolves the gem from the *active*
  bundle. Run via `BUNDLE_GEMFILE=<rigor>/Gemfile`, that is Rigor's
  bundle (activesupport 8.1.3), not the target app's — so a faithful
  "Mastodon opts in its own activesupport" run needs Mastodon's bundle;
  the walk measured here is bundle-, not cwd-, determined.

## Spec defaults vs. wired reality (and a documentation bug)

The spec's budget table, the engine, and the user-facing manual disagree
on three points:

| budget | spec default | wired value | note |
|---|---|---|---|
| `recursion_depth` | 5 | **effective 1** (re-entry guard) | the guard returns `Dynamic[top]` on *any* `(receiver, method)` re-entry; it never unrolls 5 levels |
| `ancestor_walk` | _(absent from table)_ | **100** | a real, load-bearing guard the spec table does not list |
| `hkt_fuel` | _(absent from table)_ | **64** (ADR-20) | likewise unlisted |
| `budget_per_gem` | — | **5000** (method-def count) | **manual bug** ↓ |
| `union_size`, `structural_growth`, `call_graph_width`, `overload_candidates`, `operator_ambiguity`, `interface_candidates`, `hash_erasure_*` | various | **unwired** | normative-for-v1 only |

**Documentation bug:** [`docs/manual/03-configuration.md`](../manual/03-configuration.md)
documents `dependencies.budget_per_gem` as *"Per-gem inference **time**
budget, in **ms**"*, default **`1000`**. Both are wrong: the implemented
budget is a **method-definition count** (`Walker` stops when
`catalog.size` reaches it), default **5000**
(`Dependencies::DEFAULT_BUDGET_PER_GEM`). There is also no user-facing
documentation of the `budgets:` table at all. Fix queued (Layer 1 below).

## Re-examination of the defaults — two layers

"Reconsider the default thresholds" splits cleanly, because the survey
showed the numbers that *bind in practice* are not the numbers tuned for
the large-app cost (that cost is unbudgeted).

**Layer 1 — cheap doc/spec hygiene (high confidence, no new measurement
needed):**

- Fix the `budget_per_gem` manual bug (unit = method-def count, default 5000).
- Reconcile `recursion_depth`: the spec's "5" implies unrolling; the
  engine enforces depth-1 re-entry detection as a *termination guarantee*
  (it was added to stop a mutual-recursion `SystemStackError`). Separate
  the two meanings — a hard termination floor (≥1) vs. an optional
  precision-unroll depth (default 1, i.e. off) — and align the spec
  default to the implemented reality.
- Add `ancestor_walk` (100) and `hkt_fuel` (64) to the documented table;
  both are real guards. Neither fired anywhere in the corpus, so the
  values are generous and can stay.
- Keep `operator_ambiguity` low (4): the tarai motivator wants Rigor to
  ask for an annotation *early* rather than enumerate receiver types —
  FP-safe.

**Layer 2 — the consequential, measurement-gated defaults:**

- `union_size` (spec 24) and `structural_growth` (spec 16) are the
  categories the Redmine 1.5 GB profile implicates, and they are unwired.
  Picking their defaults by reasoning is unsafe: set them too low and a
  genuine `A | B | … | 30 types` union collapses to `top`, trading the
  memory win for lost checking or a false positive — a direct violation
  of the false-positive-discipline value. **Decision: instrument actual
  union / object-shape sizes on Redmine + Mastodon first** (the same
  `BudgetTrace`-style approach used for the guards — record the
  *distribution* of join-arity and shape-member growth), then choose a
  default from the observed tail, not from a guess. The spec's 24 / 16
  are placeholders until that measurement exists.
- The remaining unwired rows (`call_graph_width` 16, `overload_candidates`
  8, `interface_candidates` 8, `hash_erasure_*`) never bound any corpus
  project; leave their spec values and defer wiring until a project
  demonstrates the cost.

## Implications for wiring priority

1. **`union_size` + `structural_growth` first.** Redmine's 1.5 GB /
   0.52 s-per-file profile points straight at unbounded join/structural
   growth. These are the categories with measured cost; the others are
   theoretical until a corpus project demonstrates them.
2. **`recursion_depth` is already effectively enforced** at depth 1 by
   the re-entry guard — wiring the configurable version is a refinement
   (allowing depth >1 before cutoff), not a new capability.
3. **`ancestor_walk` / HKT fuel can stay hard-coded** — no corpus
   evidence they bind. Don't spend config surface on them yet.
4. The silent guards should arguably emit `static.*` incomplete-
   inference diagnostics (per the spec) so users can *see* where a
   `Dynamic[top]` came from. `RIGOR_BUDGET_TRACE` is the debugging
   stopgap; it is aggregate-only and single-process.

## Reproduction

- Timing curve: `nix develop` → for each project, cwd = target,
  `BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor check
  <paths> --no-cache --format json`, read `stats.wall_seconds`.
- Guard counts: same, plus `RIGOR_BUDGET_TRACE=1 --workers 0` (the
  counters are process-global and do not cross fork boundaries).
- Paths: `app lib` for the Rails apps, `lib` otherwise (matches the
  survey-init convention).

## Follow-up sequence

This note is step 1. Before wiring anything (Layers 1–2 above):

2. A comparative note — how PHPStan, TypeScript, mypy, Steep, Sorbet,
   and TypeProf bound / terminate inference (signature-boundary vs
   whole-program-with-widening; the specific recursion / union-size /
   instantiation limits each uses).
3. A new ADR proposing Rigor's ideal budget design, synthesising (2)
   with this survey: which categories to wire, the boundary-contract
   escape hatch, and the measurement-driven default-selection rule.

Tracked in [`docs/CURRENT_WORK.md`](../CURRENT_WORK.md) § "Inference
budgets — spec table is unwired".
