# Corpus-wide cold/warm re-profile — next-bottleneck analysis (2026-06-20)

Re-profiled **all 28 configured `rigor-survey` projects** cold (`--no-cache`) and
warm (cache hit), each in a fresh process with its own `.rigor.dist.yml` /
`.rigor.yml` config and plugins auto-loaded via cwd discovery (Rails plugins on
mastodon/redmine, rigor-sorbet on dependabot/mangrove/strap, the rest pure
inference). Follow-up to `20260616` (the `constant_for_name` memo + RailsI18n
locale-alloc fixes have landed; this is the post-fix picture).

## Method

`Rigor::CLI.start(["check", …])` driven in-process, wrapped in **wall-mode**
StackProf. Wall-mode does not instrument allocations, so
`GC.stat(:total_allocated_objects)` stays the clean deterministic metric while the
profiler still attributes CPU/wall to frames. Wall time itself is machine-noise
(running heavy projects back-to-back throttled mastodon 24.8 s → 28.7 s on a rerun);
**only the allocation delta and the held diagnostic counts adjudicate a hypothesis.**

## Corpus shape

| project | cold s | cold allocs | diag | warm s | warm allocs | speedup | alloc↓ |
|---|--:|--:|--:|--:|--:|--:|--:|
| mastodon | 24.8 | 52.6 M | 2088 | 1.16 | 3.3 M | 21× | 16× |
| redmine | 10.5 | 22.6 M | 721 | 0.78 | 2.5 M | 13× | 9× |
| **mail** | **4.5** | **20.6 M** | 26 | **1.13** | **6.6 M** | **4×** | **3×** |
| textbringer | 3.6 | 8.4 M | 47 | 0.35 | 0.9 M | 10× | 10× |
| herb | 2.75 | 8.3 M | 11 | 0.27 | 0.6 M | 10× | 15× |
| kramdown | 1.72 | 4.2 M | 68 | 0.27 | 0.6 M | 6× | 7× |
| liquid | 1.54 | 4.5 M | 5 | 0.27 | 0.4 M | 6× | 11× |
| … tiny libs | 0.5–0.9 | 1.5–2.9 M | — | 0.18–0.25 | 0.2–0.4 M | 3–4× | 7–8× |

Warm floor ≈ 0.18–0.20 s, of which **55 % is loading Rigor's own code**
(`Kernel#require_relative`/`require`). The cache works well everywhere except
**mail**, the clear outlier: densest allocations per file (20.6 M / 196 files) and
the *worst* warm behaviour (6.6 M warm allocs — higher than mastodon's 3.3 M, and
only a 3× alloc reduction vs. the corpus's 7–16×).

## Four regimes

1. **Tiny libs** (rgl, erubi, oj, …): cold is **startup-bound** — code `require`
   18–55 % + RBS-env build (`RBS::Parser._parse_signature`, RBS hashing, `IO.read`)
   + GC ~11 %. Inference is a few percent. Irreducible without AOT; RBS env build is
   cache-mitigated on warm.
2. **Value / AST-builder libs** (kramdown): **type-equality churn** — see below.
3. **Discovery-dense libs** (mail): **ScopeIndexer seed pass** dominates — see below.
4. **Rails apps** (mastodon, redmine): a *flat* inference-dispatch profile
   (`expression_typer` + `method_dispatcher` + `statement_evaluator` + `rbs_dispatch`
   ≈ 25 % source-attributed), GC ~7 %, per-dispatch `CallContext.new` / `Data#initialize`
   ~2.5 % (ADR-44 adjudicated intrinsic), plugin `resolved_dynamic_return_methods`
   ~1.8 %, `StructFoldSafety` ~4 %. No single dominant frame.

## Next bottleneck: ScopeIndexer's 13-walk seed pass

`lib/rigor/inference/scope_indexer.rb#index` (L61) performs **13 independent,
root-anchored, full-AST descents** per file — each `node.compact_child_nodes.each
{ recurse }`:

`walk_class_ivars` (L253) · `walk_class_cvars` (L1268) · `walk_constant_writes`
(L1354) · `walk_methods` (L1417) · `walk_def_nodes` (L1621) ·
`walk_singleton_def_nodes` (L1692) · `walk_class_superclasses` (L1827) ·
`walk_data_member_layouts` (L1868) · `walk_struct_member_layouts` (L1917) ·
`walk_class_includes` (L1991) · `walk_method_visibilities` (L2050) ·
`collect_class_decls` (L2310 **and** L2428 — twice) — plus `collect_class_alias_map`
(L2177) and `collect_class_method_defs`.

This is mail's cold ~11 % and, critically, its **warm ~50 %+**: the run-result cache
(ADR-45) covers the *analysis*, but the project-scope **seed is re-parsed and
re-walked on every run** regardless of cache state (confirmed — Prism.parse +
ScopeIndexer walks are the entirety of mail's warm profile). The walks share the
same traversal skeleton (descend classes/modules, track `qualified_prefix`, handle
singleton classes) and differ only in what they collect per node — i.e. exactly the
shape **ADR-53 Track B** already consolidated for `CheckRules`' five per-file walks
into one engine-owned descent.

**Recommendation:** consolidate the 13 descents into one shared visitor that
dispatches to all collectors. It cuts both the cold seed cost and the dominant warm
cost, and is the natural predecessor to ADR-46 incremental (cache the per-file seed
contribution keyed by the digest the cache already computes — the real warm fix).
Gate it with ADR-53 Track B's mandatory shadow-run equivalence harness (byte-identical
diagnostics).

**Update (2026-06-20, same day — first slice landed):** the most-mergeable pair was
consolidated. `walk_methods` and `walk_def_nodes` had byte-identical class / module /
singleton descents (both stop at `DefNode`), so a single `walk_methods_and_def_nodes`
now produces both the discovered-methods existence table and the instance def-node
table; the cross-file pre-pass had additionally walked the def-node tree *twice*
(`merge_discovered_defs` + `record_class_sources`), now threaded once. Cold
`--no-cache` allocations: `mail` 20.6M → 18.9M (**−8.0%**), kramdown −1.3%, redmine
−1.1%, mastodon −0.7%. The **warm** benefit is larger, as predicted — the seed pass is
a bigger fraction of a cache-hit run: `mail` warm allocations dropped 6.60M → 5.36M
(**−18.8%**), wall ~1.13 s → ~0.93 s. Diagnostics byte-identical across the survey
corpus, `make verify` green. The remaining descents (the rvalue-typing ivar/cvar/global/constant
walks have a `seeded_scope` data dependency; the visibility and `module_function`
walks thread statement-order state) are left as separate, gated follow-ups — they do
not share a clean traversal skeleton with the def family.

## Two red herrings eliminated by measurement

kramdown's profile *looked* like the headline: `Combinator.union` cumulative **20 %**,
`Combinator.unique_members` **18 %**, `Tuple#==` / `Array#==` / `Constant#==` ~15 %
self. Two cheap fixes were prototyped and **measured**, then reverted:

1. **`unique_members` O(n²) `==`-scan → `types.uniq`** (hash-based): **byte-identical**
   (kramdown 68 / liquid 5 / mastodon 2088 / redmine 721 diagnostics all held) but
   **alloc-neutral** (4,188,064 vs 4,189,658). The 18 % is *not* quadratic blow-up —
   it is high-frequency calls with small `n`; the cost is the inherent structural
   comparison, which `.uniq` still performs (via `eql?`) plus a `hash` call. Safe but
   not faster. (All carriers *do* carry consistent `eql?`+`hash`: ValueSemantics
   codegens both and aliases `eql?`→`==`; `Constant`/`Top`/`Bot` hand-write a
   consistent trio; the `def hash` greps on `hash_shape`/`difference` were
   `hash_erasure`/`hash_canonical_name` name-matches, not overrides — so `.uniq` is
   *correct*, just perf-neutral.)
2. **`equal?` identity fast-path** on the ValueSemantics-generated `==` and
   `Constant#==`: also byte-identical, also **alloc-neutral**. The comparisons are
   between *distinct* structurally-equal objects, not identity-equal ones, so the
   short-circuit rarely fires.

Conclusion: type-equality cost is **irreducible by cheap local means**. The only
lever is global type-carrier hash-consing / interning (so structurally-equal carriers
*are* the same object and `equal?` hits) — a large architectural change with uncertain
payoff and real FP/identity risk. **Not recommended** as the next step.

## Non-targets (recorded so they aren't re-litigated)

- **Tiny-lib `require` startup** (warm floor 55 %): irreducible without AOT/bundling.
- **RBS core-env build** (cold, tiny+small libs): upstream-`rbs` territory;
  cache-mitigated on warm.
- **Per-dispatch `CallContext.new` / `Data#initialize`** (Rails ~2.5 %): ADR-44
  already adjudicated intrinsic (mutable/pooled scope rejected on re-entrancy/FP).
- **Plugin `resolved_dynamic_return_methods`** (Rails ~1.8 %): a possible memo, but
  small and Rails-only.
