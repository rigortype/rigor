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

## Survey 4 — union-arity distribution (Slice 2a) refutes the union_size hypothesis

ADR-41 Slice 2a added a **read-only** union-arity histogram: the member
count of every `Type::Union` `Combinator.union` produces, recorded with
no cap enforced (`RIGOR_BUDGET_TRACE`, `--workers 0`). The point was to
choose the `union_size` default from an observed distribution rather than
a guess. The result instead **refuted the premise that `union_size` is
the lever for the large-app memory cliff.**

| project | union calls | max arity | p50 | p90 | p99 | ≥10 | ≥24 | ≥40 | wall | peak RSS |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| liquid | 3,514 | 20 | 2 | 3 | 4 | 4 | 0 | 0 | 0.69 s | 129 MB |
| kramdown | 9,685 | **932** | 2 | 2 | 9 | 95 | 38 | 30 | 1.25 s | 124 MB |
| haml | 15,528 | 23 | 2 | 3 | 3 | 5 | 0 | 0 | 1.07 s | 126 MB |
| **redmine** | 254,584 | **37** | 2 | 2 | 3 | 115 | 20 | 0 | 172.75 s | **1518 MB** |
| mastodon | 873,862 | 184 | 2 | 3 | 4 | 117 | 6 | 4 | 173.01 s | 277 MB |

Reading — three findings, all decision-changing:

1. **Memory does not correlate with union width — if anything it
   anti-correlates.** kramdown produces a **932-member** union yet peaks
   at 124 MB / 1.25 s; Redmine's widest union is **37** members yet it
   peaks at **1.5 GB**. A few giant unions are cheap; Redmine's blow-up
   is not wide unions.
2. **`union_size` would barely touch Redmine.** Of Redmine's 254,584
   unions, only **20** are ≥24 and **none** ≥40. Capping at 24 would clip
   20 unions for ~0 memory benefit — and those 20 are presumably
   *legitimate* (Redmine's real branch joins), so the cap would *add* a
   false-positive surface (collapse-to-`top`) while fixing nothing. This
   is exactly the asymmetric-cost failure WD3 warned about, caught
   *before* wiring.
3. **The spec's `union_size = 24` is, if anything, too low, not too
   high.** The earlier prior-art reasoning ("TypeProf runs 10, so 24 may
   be loose") is overturned by data: TypeProf's 10 would clip 95–117
   unions per large project — a large FP surface under Rigor's discipline.
   The p99 is 3–9 everywhere; the only genuinely pathological tail is
   kramdown's 932 and mastodon's 184. If `union_size` is wired at all, it
   is a **display / pathology valve at ~40–64**, not a memory fix and not
   24.

**Consequence:** the load-bearing Layer 2 question is *no longer*
"wire `union_size`." Redmine's 1.5 GB is driven by something that scales
with the project's type universe but not with union width — candidates:
`structural_growth` (object-shape accumulation), fact-store / narrowing
accumulation, the RBS environment for a 67k-LOC Rails app, or retained
per-method scopes. **The real next step is to memory-profile Redmine to
find what actually allocates**, not to wire a union cap. Slice 2a did its
job: it spent one read-only measurement to stop us wiring the wrong
budget.

## Survey 5 — heap attribution: the cliff was a plugin bug, not a budget

Slice 2a refuted `union_size`, so Slice 2b asked the blunt question: *what
actually allocates Redmine's 1.5 GB?* Two read-only probes
(`RIGOR_HEAP_PROFILE` — live objects by class after GC;
`RIGOR_HEAP_TRACE` — live Strings by allocation `file:line`) answered it
in one run.

**Class breakdown (Redmine, end of run):** of 756.7 MB tracked live heap,
**671 MB was String — 4,435,826 String objects (89%)**. `Rigor::Type::*`
carriers did not appear in the top 30; the type universe is cheap. So the
cliff is raw String retention, not any type-level structure.

**Allocation site:** `4,176,047` of those strings (98.5%) traced to a
**single line** —
`plugins/rigor-activerecord/lib/rigor/plugin/activerecord.rb:562`, the
`rescue Errno::ENOENT` that appends `"… schema file not found …"` to the
plugin's `@load_errors`.

**Root cause:** `schema_table_or_nil` is called once per AR call site (via
`model_index`, which also did not memoize its nil result), and it memoized
only *success*. With Redmine's schema file missing (it ships migrations,
no `db/schema.rb`), every call re-attempted the read, hit `ENOENT`, and
appended a fresh interpolated string. The list grew without bound. This
also explains the Survey-1 anomaly — **Mastodon stayed at 277 MB because
it ships `schema.rb`** and never triggered the bug; the budget framing
mistook one plugin's missing-file handling for a scaling law.

**Fix + verification:** memoize the failure (`@schema_load_attempted`, one
attempt). Re-measured Redmine:

| metric | before | after | Δ |
|---|--:|--:|--:|
| peak RSS | 1518 MB | **217 MB** | −86 % |
| wall | 172.75 s | **84.33 s** | −51 % |
| live Strings | 4,435,826 | **79,973** | −98 % |
| tracked heap | 756.7 MB | **47.6 MB** | −94 % |

Diagnostics are unchanged (the single `load-error` warning was already
correct; only the internal retention was the bug). The whole "large-app
cost cliff" that motivated wiring `union_size` / `structural_growth` was
**not an inference-budget problem at all** — it was one unmemoized failure
in a plugin, fully orthogonal to the budget table. Measurement-first (WD3)
paid for itself twice: it stopped us wiring `union_size` at a harmful
default *and* led the heap probe straight to the real cause.

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
