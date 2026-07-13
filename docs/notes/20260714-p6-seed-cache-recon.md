# P6 recon — per-file seed-contribution caching (ADR-46 completion arc)

> Grounds [ADR-85](../adr/85-seed-bundles-and-lazy-def-node-handles.md) (per-file seed bundles + lazy def-node handles). See that ADR's "Divergences from the recon" section for two points this recon got wrong that surfaced during implementation (the `classes` key-list assumption and the missed `symbol_fingerprints` node-value consumer).

Measurement date 2026-07-13, `master` @ `a09b9e29` (PRs #74–#80 + ADR-84 return-memo landed).
Ruby 4.0.5, Prism 1.8.1, `RIGOR_DISABLE_YJIT=1`. Metric: `GC.stat(:total_allocated_objects)`
(allocations decide) + wall. One rigor process at a time. Instrumentation was entirely
driver-side monkeypatch in `scratchpad/perf/`; **the repo was never modified** (git status clean).

Targets: rigor `lib` (324 files, no plugins), mail `lib` (111 files, no plugins),
gitlab `app/models` (1225 files, **10 auto-loaded Rails plugins**).

---

## Headline

| run type | rigor lib | mail lib | gitlab models |
|---|---|---|---|
| **cold full miss** — pre-pass share of total allocs | 3.2% | 6.0% | 2.0% |
| **warm `--incremental`** — discovery pre-pass share of total allocs | **82.7%** | **94.0%** | **4.9%** |
| gitlab warm-incremental dominated by | — | — | plugin `#prepare` **86%** |

The discovery pre-pass is a **rounding error on a cold miss** (per-file analysis dominates) but
the **dominant cost of a warm incremental recheck on plugin-light projects**. On a Rails app it is
swamped by plugin `#prepare`, which re-runs every incremental invocation.

Marshal.load + merge-fold of cached per-file bundles beats parse+walk recompute by **36×–570× wall /
10×–48× allocs** — the ADR-54 beats-recomputation bar is cleared by a wide margin. An incremental
single-file recheck demands only **0–6 distinct files'** def-node bodies, so lazy on-demand parsing
touches almost nothing.

**Recommendation: build it, as eager-marshal (plain data) + lazy-handles (def-nodes), on the
IncrementalSnapshot host, rebuild-from-bundles-in-file-order — but scope it as an
`--incremental`-path optimization for plugin-light projects, and note that Rails apps need
plugin-`#prepare` caching first (a separate lever) before this slice moves their needle.**

---

## Q1 — Pre-pass cost split (parse vs walk), cold

`ScopeIndexer.discovered_project_index_for_paths` loop, per-phase timers (rep-2, warmed methods;
allocs are JIT-independent). Parse = `Prism.parse`; Walk = `collect_class_decls` +
`accumulate_project_index`.

| target | files | total wall | total alloc | parse wall | walk wall | walk %wall | parse alloc | walk alloc | **parse %alloc** |
|---|---|---|---|---|---|---|---|---|---|
| rigor lib | 324 | 0.28 s | 439 k | 0.069 s | 0.201 s | **74%** | 349 k | 88 k | **80%** |
| mail lib | 111 | 0.53 s | 485 k | 0.076 s | 0.452 s | **86%** | 463 k | 21 k | **96%** |
| gitlab models | 1225 | 0.58 s | 846 k | 0.133 s | 0.414 s | **76%** | 623 k | 218 k | **74%** |

Per-file (ms): rigor parse mean 0.21 / p95 0.82, walk mean 0.62 / p95 2.27, total p95 3.14;
mail parse mean 0.68 / p95 1.02, walk mean **4.07** / p95 **5.80**, total p95 6.77 (mail is the
walk-cost outlier — big monolithic files); gitlab parse mean 0.11 / p95 0.29, walk mean 0.34 /
p95 0.97, total p95 1.27 (small models).

**Two opposing facts, both load-bearing:** the WALK dominates **wall** (74–86%), but PARSE dominates
**allocs** (74–96%). A cache that skips both wins on both; a lazy scheme that re-pays parse on demand
keeps the walk win (the bulk of wall) but only keeps the parse-alloc win for *undemanded* files (Q5).

---

## Q2 — Per-file contribution isolability + merge semantics

Tables folded per file in `accumulate_project_index` (scope_indexer.rb:2110), with value shapes and
merge rule:

| table | value shape | merge rule (folding files in order) |
|---|---|---|
| `def_nodes` | `{class => {method => Prism::DefNode}}` | **later-file-wins** (`merge!`) — *live node refs* |
| `singleton_def_nodes` | `{class => {method => Prism::DefNode}}` | later-wins (`merge!`) — *live node refs* |
| `def_sources` | `{class => {method => "path:line"}}` | **first-file-wins** (`||=`) |
| `superclasses` | `{class => super_name(String)}` | later-wins (`merge!`) |
| `includes` | `{class => [module_names]}` | **accumulate** (`(a+b).uniq`) |
| `method_visibilities` | `{class => {method => :public/:private/…}}` | later-wins (nested `merge!`) |
| `methods` | `{class => {method => kind}}` (existence) | later-wins (nested `merge!`) |
| `class_sources` | `{class => Set<path>}` | **accumulate** (Set union) |
| `data_member_layouts` / `struct_member_layouts` | member-shape tables | later-wins (`merge!`) |
| `classes` (from `collect_class_decls`) | `{full_name => Singleton[full]}` | later-wins (overwrite); value is a pure fn of the key |

- (a) **Constructible in isolation**: yes — `accumulate_project_index(fresh_acc, path, root)` yields
  exactly one file's contribution.
- (b) **Mergeable in file order**: yes — that is literally today's loop.
- (c) **Removable/replaceable for a changed file (delta-update)**: **NOT sound in general.**
  `includes` / `class_sources` accumulate (a Set-union can't be un-done without knowing every other
  contributor), and `def_nodes` / `superclasses` / `methods` are later-wins (replacing file F "last"
  can wrongly override a file G that follows F in canonical order). **The sound merge is
  rebuild-from-cached-bundles-in-file-order** (fold every file's cached bundle with the existing
  semantics; changed files contribute a fresh walk, unchanged files their cached bundle).

**Empirically the order-dependence almost never bites**: duplicate `(class,method)` instance pairs
across files = **0 / 0 / 0** (rigor 3483 distinct pairs, mail 650, gitlab 7977 — zero cross-file
duplicates). Reopened classes: rigor 0, **mail 1** (one class in two files, no method conflict),
gitlab 0. Conflicting superclasses: 0 everywhere. So delta-replace would be *practically* sound, but
rebuild-from-bundles is cheap enough that there is no reason to risk it (see Q3 fold cost).

One finalize subtlety: `finalize_def_index` runs `subtract_def_methods` (drops from `methods` any
`(class,method)` that has a `def` node **anywhere**). This is a *post-merge* whole-project operation,
so cached bundles must store the **pre-finalize** `methods` table + `def_nodes` and run
`finalize_def_index` once after folding all bundles (not per file).

---

## Q3 — Bundle content, size, and the ADR-54 beats-recompute test

Per-file bundle split: **plain-data subset** (every table except def-nodes; `classes` stored as
key-list since values are reconstructable) + **def-node refs** (`def_nodes` /
`singleton_def_nodes` re-expressed as `{class => {method => [path, node_id, name]}}`).

| target | files | plain total | plain mean / p95 | def-ref total / p95 | whole blob (raw / **zlib**) | **Marshal.load ALL** | recompute parse+walk | **load ÷ recompute (wall)** |
|---|---|---|---|---|---|---|---|---|
| rigor lib | 324 | 439 KB | 1389 B / 3589 B | 272 KB / 2694 B | 639 KB / **127 KB** | **6 ms, 41 k allocs** | 290 ms, 440 k allocs | **0.022 (45× faster)** |
| mail lib | 111 | 90 KB | 832 B / 2039 B | 41 KB / 1011 B | 122 KB / **24 KB** | **1 ms, 10 k allocs** | 572 ms, 485 k allocs | **0.003 (330× faster)** |

Merge-fold cost (fold N isolated per-file tables in order + finalize), from Q2 script:
rigor **2 ms / 2.9 k allocs**, mail **~0 ms / 0.8 k allocs**, gitlab **5 ms / 10 k allocs**.

**Cache path total = Marshal.load + merge-fold vs recompute = parse+walk:**
- rigor: **8 ms / 44 k allocs** vs 290 ms / 440 k → **36× wall, 10× allocs**
- mail: **1 ms / 11 k allocs** vs 572 ms / 485 k → **570× wall, 44× allocs**

The ADR-54 bar (definitions blob was retired at 366 ms load vs 137 ms rebuild — a *loss*) is cleared
by 1.5–2.5 orders of magnitude in the *opposite* direction. The plain-data + def-ref bundle is
tiny (24–127 KB zlib for a whole project) and loads far below recompute. **The bundle earns its
bytes decisively** — but only for the merge step; def-node *bodies* still need resolution (Q5/Q6).

---

## Q4 — node_id stability

Prism 1.8.1 exposes `Prism::Node#node_id`. Verified empirically over sampled files:
- **Every DefNode has a non-nil node_id** (`node_id_nil_count = 0`).
- **Stable across repeated parses of identical bytes** (`node_id_mismatch_repeat_parse = 0`, mail 169 defs).
- **Stable across the pre-pass parse vs a fresh parse** of the same bytes (same test).
- `[start_offset, name]` is **equally stable** (`startoffset_name_mismatch = 0`).

Both keys work. **Recommend `node_id`** (a compact native Integer, unique per node in a parse, no
string building) as the primary ref, keeping `[start_offset, name]` as a cheap cross-check on
resolution (defends against a node_id assignment change between Prism minor versions — the ref is
stored under a schema/ABI-versioned blob (Q7), so a mismatch just forces a cold re-walk, never a
wrong node). The `name` is stored anyway for the resolution assertion. (`node_id_supported:false`
appeared for rigor only because that sampler's first file had no DefNode → `nil.respond_to?` — an
artifact, corrected by the standalone check: prism 1.8.1 returns ids `[6, 9]` for two defs.)

---

## Q5 — Demand statistics (parse-on-demand)

Instrumented the three ADR-46 accessor choke points; counted distinct **source files** whose
def-node was resolved (non-nil).

**Full cold run** (`check --no-cache`): distinct demanded files —
- rigor lib: **213 / 324 = 66%** (24.7 k resolutions collapse to 213 files via the return memo)
- mail lib: **43 / 111 = 39%**

**`--incremental` subset recheck** (leaf subset via `IncrementalSession#reanalyze_subset`,
no source mutation): distinct demanded files —

| subset size | rigor | mail |
|---|---|---|
| 1 (leaf) | **0** | **0** |
| 5 | 1 (0.3%) | 2 (1.8%) |
| 20 | 4 (1.2%) | 6 (5.4%) |

A single-file / small-subset incremental recheck demands **0–6 distinct files' bodies** (≤5% of the
project). A *zero-change* incremental demands **0** (analyze set empty → `analyze_files([])` returns
before any body eval). So a lazy-handle scheme parses **essentially nothing** on the incremental
path, and since PARSE dominates pre-pass allocs (Q1), lazy resolution keeps almost the entire
parse-alloc win that eager-resolve-all would forfeit. On a full cold run it would still parse
39–66% on demand — but the cold run re-walks everything anyway, so that path is not the target.

**Verdict: lazy-handles strictly dominates eager-marshal-and-resolve on the incremental path.**

---

## Q6 — Where a lazy handle resolves (consumers of `discovered_def_nodes`)

Two consumer classes, from a full lib/rigor sweep:

**(A) Need a live `Prism::DefNode` value — the ONLY resolution sites (3):**
- `Scope#user_def_for` (scope.rb:370)
- `Scope#singleton_def_for` (scope.rb:383)
- `Scope#top_level_def_for` (scope.rb:412)

These are the ADR-46 dependency-recording choke points and the ONLY places a node body is handed
out (→ `ExpressionTyper#infer_user_method_return`). A `(path, node_id)` handle resolves here through
a per-run parse memo without changing the accessor contract (callers still receive a real DefNode).

**(B) Read only table STRUCTURE (class-name / method-name keys) — no node deref, work directly on the
refs table:**
- `known_user_class?` (expression_typer.rb:1438: `discovered_def_nodes.key?(name)`)
- `method_definers_index` / `build_method_definers_index` (expression_typer.rb:1523/1528: iterate class
  names + method-name keys)
- `check_rules.rb:2339` (`discovered_def_nodes.key?(name)`)
- `parameter_inference_collector.rb:346` (reads the table for param inference — keys)
- the run-scoped memo stores `class_graph_buckets` / `override_gate_buckets` /
  `method_definers_index` (expression_typer.rb:1353/1476/1523) key on the **table OBJECT identity**,
  not node values — a new merged refs-table per run lands in a fresh bucket automatically.

**Return-memo interaction (ADR-84 WD2) — the load-bearing constraint.** The return memo
(`return_memo_bucket`, expression_typer.rb:1934) keys on the run-generation token, then on the
resolved **def_node's object identity** (RETURN_MEMO_KEY doc, 1633–1637). Therefore handle
resolution **MUST yield ONE stable node object per `(path, node_id)` per run** (a memoized per-run
parse: parse the demanded file once, retain its AST, resolve node_id → the same object on every
call). Re-parsing per call would mint a fresh identity each time → every memo lookup misses →
fragmentation. Today a callee already has **≤2 node identities per run** (the project-index parse +
the defining file's own analysis parse); a lazy per-run parse memo preserves that bound (and reduces
the cross-file arm to 1 identity), so it *improves* memo coherence rather than harming it. The memo
store keys (class B above) are unaffected — they never see node values.

---

## Q7 — Persistence host

| option | fs-ops on 11 k files | eviction | schema/ABI story | fit for rebuild-from-all-bundles |
|---|---|---|---|---|
| **Ride `Cache::IncrementalSnapshot`** (single zlib-Marshal blob, fingerprint-gated) | **1 read + 1 write** | whole blob (already lifecycle-managed, dropped on fingerprint miss) | `SCHEMA` const (currently 5) bump; the #57 ABI is folded into the fingerprint via `engine:#{VERSION}` | **best** — the merge needs *every* bundle, one Marshal.load serves all |
| New per-file `Cache::Store` producer family (one entry per file, keyed by digest) | **~N reads** (11 k stat+open+inflate) | ADR-54 `evict!` + 256 MB cap apply per entry | `PAYLOAD_ABI_VERSION = Rigor::VERSION` + `Descriptor` schema | **poor** — the rebuild loads ALL unchanged bundles, so N fs-ops every run; syscall overhead likely rivals re-walking |
| One sharded blob per run-config (dedicated artifact) | 1 read + 1 write | bespoke | bespoke | good, but duplicates the snapshot's fingerprint + lifecycle machinery |

**Recommendation: extend `Cache::IncrementalSnapshot`.** Add a `seed_bundles` field to `Payload`
(`{path => Marshal-able per-file bundle}`) and bump `SCHEMA`. It is already (i) the `--incremental`
host, (ii) loaded unconditionally when the fingerprint matches (one fs read — exactly the
merge-everything access pattern), (iii) keyed by a fingerprint that already digests engine version +
config + roots + gems + project RBS, so the #57 ABI marker and cache-invalidation come for free, and
(iv) zlib-Marshal at the same 13–16% compression the whole-blob measurement showed (127 KB / 24 KB).
The per-file `Cache::Store` family is the wrong host precisely because the sound merge needs *all*
bundles — turning one Marshal.load into ~N fs-ops, the ADR-54 anti-pattern. For a general
(non-`--incremental`) ADR-45 cached MISS to also benefit, a *sibling* single blob keyed on the same
env descriptor could be added later, but that path's win is small (Q8) so it is not the priority.

---

## Q8 — Is the slice worth it?

Absolute pre-pass numbers vs the run they sit in:

| scenario | total allocs | discovery pre-pass | **pre-pass share** | slice ceiling |
|---|---|---|---|---|
| (b) mail **cold full miss** | 8.13 M | 485 k | **6.0%** | ~0% (nothing cached on a cold run); ~6% on a later cached-MISS |
| rigor **cold full miss** | 13.96 M | 440 k | 3.2% | same character |
| gitlab **cold full miss** | 42.94 M | 846 k | 2.0% | same character |
| (c) rigor **`--verify-incremental`** | 35.29 M | ~2–3×440 k | **~3–4%** | small (verify runs a FULL baseline + subset) |
| (a) gitlab **single-edit incremental** (badge.rb) | 24.12 M | 811 k | **3.4%** (measured) | small — plugin `#prepare` 86%, env-build 4.9% |
| gitlab **zero-change incremental** | 16.6 M | 811 k | 4.9% | env not built (analyze set empty) |
| **rigor single-edit warm incremental** | 0.53 M | 436 k | **82.7%** | **large** |
| **mail single-edit warm incremental** | 0.52 M | 485 k | **94.0%** | **large** |

Under the task's three literal scenarios (a/b/c), the ceiling is **<10% on all three** — a measured
"marginal" for those. The value lives in the scenario they don't enumerate: a **plugin-light warm
incremental single-edit**, where the discovery pre-pass is **83–94%** of the run and the slice removes
almost all of it (down to ~44 k / 11 k allocs of load+fold + 0–6 on-demand parses).

Why the split: only `--incremental` skips per-file analysis of unchanged files (ADR-46); a plain
cached MISS re-analyzes everything, so the pre-pass is a 2–6% sliver there. And on a Rails app the
`--incremental` recheck is dominated not by the discovery pre-pass but by **plugin `#prepare`**
(gitlab: 10 auto-loaded Rails plugins, `#prepare` = **14.2 M / 86%** of the 16.6 M warm-incremental
run; discovery pre-pass 811 k = 4.9%; synthetic-scan 0.67 M; snapshot I/O 0.38 M). `#prepare` re-runs
on every incremental invocation (`ProjectPrePasses#run` → `plugin_prepare_diagnostics`, fresh runner
per recheck). **So on Rails the discovery slice is contingent on plugin-`#prepare` caching landing
first** — if `#prepare` were cached, gitlab's warm incremental would fall to ~2.4 M and the discovery
pre-pass would jump from 5% to ~34%, at which point this slice becomes worthwhile there too.

**Bottom line:** worth building, with eyes open about *where* it pays. It is an `--incremental`-path
optimization that removes 80–94% of the warm-incremental cost on plugin-light projects (libraries,
plugin-free apps — the mail / rigor-lib class) and is FP-free / precision-neutral (pure caching of a
deterministic pre-pass). For the Rails audience it is a ~5% move until plugin-`#prepare` caching is
also done; sequence that lever first if Rails incremental latency is the goal.

---

## Design recommendation (for the ADR)

1. **Mechanism: eager-marshal (plain data) + lazy-handles (def-nodes).** Cache each file's
   pre-finalize plain-data tables *and* its def-node tables re-expressed as `(path, node_id, name)`
   handles. On a miss, re-walk only changed files; load cached bundles for the rest; **rebuild the
   merged index by folding all bundles in canonical file order** then `finalize_def_index` once
   (Q2 — delta-replace is unsound for the accumulate/later-wins tables; fold is 2–5 ms so there is
   no reason to). The structure-only consumers (Q6 class B) read the merged refs table directly.
2. **Def-node resolution: lazy, at the 3 accessors (Q6 class A), through a per-run parse memo** that
   parses a demanded file once, retains its AST for the run, and resolves `node_id` → **one stable
   node object** (required by the ADR-84 return memo). Only 0–6 files are demanded on an incremental
   recheck (Q5), so this parses almost nothing.
3. **Host: extend `Cache::IncrementalSnapshot`** with a `seed_bundles` payload field + `SCHEMA` bump
   (Q7). One fs read, fingerprint already covers ABI/config/gems/RBS.
4. **Scope: an `--incremental`-path optimization.** Gate the win by measuring on plugin-light
   projects (mail, rigor-lib: expect −80–94% warm-incremental allocs). Flag in the ADR that the
   Rails incremental bottleneck is plugin `#prepare` (86%), a separate cache lever this slice does
   not touch — the discovery slice only reaches ~34% relevance on Rails *after* that lands.
5. **Correctness gate:** the existing `--verify-incremental` byte-identical cross-check already
   backstops the merge; add a spec that a resolved handle's node satisfies
   `node.name == stored_name` (Q4 cross-check) and that memo keys stay stable (one node identity per
   `(path, node_id)` per run).
