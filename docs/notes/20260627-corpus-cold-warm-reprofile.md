# Corpus cold/warm re-profile — new-bottleneck check (2026-06-27)

Status: profiling note, no spec/design commitments. Taken against **Rigor 0.2.6**
(`release/0.2.6` machinery, master @ `23c5a990`). Follow-up to
[`20260620-corpus-cold-warm-reprofile.md`](20260620-corpus-cold-warm-reprofile.md),
re-run after the v0.2.6 feature window landed: ADR-75 (`Dynamic[T]` provenance
side-table), ADR-76 / ADR-78 (shape-carrier preservation through
`freeze`/`dup`/`clone` + the reflective-send over-fold root fix), ADR-72
(Gemfile.lock-gated gem-overlay RBS). The question this note answers: **did any
of that introduce a new bottleneck the prior four regimes did not have?**

## Method

Same harness as `20260620`: `Rigor::CLI.start(["check", …])` driven in-process
(so `require` cost is paid once and the warm run isolates analysis + cache
validation, not code load), wrapped in **wall-mode** StackProf. Wall-mode does
not instrument allocations, so `GC.stat(:total_allocated_objects)` stays the
clean deterministic metric; wall time is machine-noise. stackprof from a
throwaway `GEM_HOME` (native ext ABI must match the Flake ruby 4.0.5 — rebuild
it, do not reuse a stale `/tmp` build).

Nine projects across the four regimes, profiled cold (`--no-cache`) + warm
(cache hit) via parallel sub-agents. Rails apps profiled on `app/models` only
(bounded subset; not directly comparable to the prior full `app`+`lib` rows, but
same regime).

## Corpus shape

| project | paths | cold s | cold allocs | warm s | warm allocs | speedup | vs 2026-06-20 |
|---|---|--:|--:|--:|--:|--:|---|
| mastodon | app/models | 4.3 | 9.34 M | 0.14 | 0.64 M | 30× | subset (regime ✓) |
| redmine | app/models | 7.2 | 13.4 M | 0.16 | 0.76 M | 45× | subset (regime ✓) |
| mail | lib | 4.1 | 18.9 M | 0.69 | 5.18 M | 6× | 4.5 s / 20.6 M → ↓ |
| kramdown | lib | 1.67 | 4.14 M | 0.07 | 0.34 M | 24× | 1.72 / 4.2 M = flat |
| liquid | lib | 1.52 | 4.43 M | 0.05 | 0.20 M | 33× | 1.54 / 4.5 M = flat |
| haml | lib | 0.88 | 2.78 M | 0.04 | 0.16 M | 25× | tiny-lib band ✓ |
| net-ssh | lib | 1.23 | 3.72 M | 0.07 | 0.34 M | 17× | tiny-lib band ✓ |
| faraday | lib | 0.65 | 2.11 M | 0.03 | 0.12 M | 24× | tiny-lib band ✓ |
| oj | lib | 0.58 | 1.64 M | 0.01 | 0.04 M | 58× | tiny-lib band ✓ |
| erubi | lib | 0.65 | 1.47 M | — | — | — | tiny-lib band ✓ |

Allocations are **flat-to-slightly-down** vs the `20260620` baseline everywhere
they are comparable (mail 20.6 M → 18.9 M; kramdown / liquid within noise). The
`bench/baseline.json` note records the v0.2.6 features cost `lib` self-check
**+5.3 %** allocations — that cost does **not** appear in the survey corpus
because those features (provenance recording, shape preservation, the overlay)
rarely fire on these targets.

## Headline result: no new bottleneck from the v0.2.6 features

**None of the ADR-75 / 76 / 78 / 72 code paths appear as a hotspot in any of the
ten profiles.** Specifically absent from every cold and warm top-frame list and
per-file rollup: `dynamic_origins` / provenance recording, shape-carrier
preservation / `freeze`/`dup`/`clone` effect modeling, reflective-send fold
guards, and `data/gem_overlay` loading. The four regimes are intact:

1. **startup-bound** (oj / net-ssh / haml / faraday / erubi) — `require` +
   `RBS::Parser._parse_signature` + RBS-env hash-building
   (`RBS::Namespace#hash` / `TypeName#hash` / `Array#hash`) + GC.
2. **value/AST equality churn** (kramdown) — `Array#== / Constant#== / Tuple#==`
   + `Combinator.unique_members` (18.5 % tot) still dominant, as `20260620`
   diagnosed and declared irreducible by cheap means.
   - *(liquid has shifted within this regime toward RBS hash-cons churn —
     `Array#hash / RBS::TypeName#hash / Hash#fetch` + `lib/rbs/*` — rather than
     value-equality; still classic RBS-env territory, not a new cost.)*
3. **discovery-dense seed walk** (mail) — `ScopeIndexer` seed pass
   (`walk_methods_and_def_nodes` / `walk_method_visibilities` /
   `collect_class_decls`) is cold ~22 % per-file and the warm dominator (46 %),
   exactly the `20260620` "next bottleneck" thesis.
4. **Rails flat-inference** (mastodon / redmine) — `expression_typer` /
   `method_dispatcher` / `statement_evaluator` / `rbs_dispatch` +
   `CallContext.new` / `Data#initialize` per-dispatch (ADR-44 intrinsic) + GC.

Warm runs everywhere are **ScopeIndexer seed re-walk + Prism re-parse** dominated
— the ADR-45-locked warm path (cache covers analysis, not the per-file seed
re-parse). The real warm lever remains ADR-46 per-file incremental, unchanged
from `20260620`.

## One non-classic frame: redmine `DidYouMean::Jaro.distance` (~6 % cold self)

The single frame outside the prior baseline's breakdown is **redmine cold's #1
self frame, `DidYouMean::Jaro.distance` (5.9 % self / 6.4 % tot)**, with
`did_you_mean/jaro_winkler.rb` at 5.9 % of the per-file rollup.

Source: [`lib/rigor/plugin/base.rb:776`](../../lib/rigor/plugin/base.rb) —
`Plugin::Base.suggest` constructs a fresh `DidYouMean::SpellChecker.new(dictionary:)`
**per call** and runs `.correct` (Jaro-Winkler, O(dictionary × name)) to build
the "did you mean …?" hint on undefined-method / unresolved-constant diagnostics.

The cost is the `DidYouMean::SpellChecker#correct` (Jaro-Winkler) call that the
Rails plugins (`rigor-actionpack` / `rigor-activerecord` / `rigor-pundit` / …)
run to build the "did you mean …?" hint on each unresolved-name diagnostic.
`rigor-activerecord` and `rigor-rails-routes` route through `Plugin::Base.suggest`;
`rigor-actionpack` / `rigor-pundit` / `rigor-factorybot` build a `SpellChecker`
directly but already reuse it across a loop (so `.new` is amortised — the cost is
`#correct`, not construction).

Adjudication:
- **Not a v0.2.6 regression.** This hint path predates the ADR-75/76/78 window. It
  did not appear in the `20260620` redmine row only because that profile reported
  redmine as an aggregate (10.5 s / 22.6 M) without a frame breakdown.
- **Intrinsic per-diagnostic cost, not memo-addressable** — tested and confirmed.
  Hypothesis: result-memoise `Plugin::Base.suggest` by `(name, dictionary)` since
  the same unresolved name recurs against the same dictionary. Implemented (byte-
  identical: redmine 26 diagnostics held, `make check` + `make check-plugins`
  clean, `base_spec` 70/70) and **re-profiled: zero movement** — Jaro stayed
  6.3 % self, allocations identical (13.384 M → 13.383 M). On redmine `app/models`
  the `(name, dictionary)` pairs are almost all **distinct** (each unknown column
  on a different model has a different dictionary), so the memo never hits. The
  ~6 % is genuinely `diagnostic-count × dictionary-size` Jaro work computed once
  per distinct query — irreducible without changing what hint is produced (a
  length/first-char pre-filter before Jaro is the only lever, and DidYouMean
  already applies one internally). The speculative memo was **reverted** —
  unmeasured perf state has no place under this repo's measurement-gated rule.
- **Project-specific.** Concentrates on redmine because it emits many
  unresolved-name diagnostics over large model/column dictionaries; near-invisible
  on the low-diagnostic libs. Same family as the mastodon `inspect_runtime_string`
  NameError-suggestion finding (`20260616`), but unlike that one it is not a
  rebuild-per-call artifact — there is no cheap win here.

## Takeaway

No action required. The v0.2.6 features are profile-invisible on the corpus and
allocation-neutral-to-favorable — no new bottleneck. The ScopeIndexer-seed warm
path (regime 3, ADR-46) and the irreducible value-equality churn (regime 2) remain
the standing bottlenecks from `20260620`. The one non-classic frame (redmine
`DidYouMean::Jaro.distance`) was investigated and found intrinsic / not cheaply
reducible — recorded here so the next profiler does not re-chase it.
