# ADR-53 — Scope discovery-index separation + check-rule walk consolidation

Status: **Accepted — Track A complete (slices A1 + A2 landed 2026-06-10/11);
Track B slices B1–B3 landed (B1 + B2 2026-06-11, B3 2026-06-13), B4
remaining.** Archetype: deliberative. Stakes: high
(state-carrier restructure in the inference engine + traversal changes under
correctness-critical rules; every slice gates on byte-identical diagnostics).
A1 (`031f161e`): `Scope::DiscoveryIndex` extracted, readers delegated,
writers shimmed; landing it surfaced and fixed the predicted bug class twice
— both ADR-44 single-allocation body-scope constructors had silently dropped
later-added tables (`data_member_layouts` in `build_fresh_body_scope`,
`data_member_layouts` + `discovered_method_visibilities` in
`build_user_method_body_scope`). A2 (`063823e4`): the 14 per-table writers
deleted, the three seeding sites collapsed onto `with_discovery`. Gates held:
suite + steep green, self-check and Mastodon (146) / Redmine (12) corpus
diagnostics byte-identical, bench-perf wall flat. Track B B1+B2
(`6858872c`): the shadow-run equivalence harness + the two flow collectors
on one `CheckRules::RuleWalk`. Track B B3 (`b85c51c6` IvarWrite +
`4f1745aa` DeadAssignment + `963a2947` main pass): `RuleWalk` generalised
to thread the union context (`in_loop_or_block` + qualified class/module
prefix + `inside_def`) in one immutable per-node `Context`; a collector
declares `NODE_CLASSES`, optional `RULE_WALK_GATES` (the walk-owned
suppressions reproducing each legacy walk's traversal prune), and
`#visit(node, context)`, with its gather/filter logic transplanted
verbatim. The five built-in per-file walks (two flow + IvarWrite +
DeadAssignment + the main `NodeWalker.each` pass) now ride ONE traversal.
Each slice gated byte-identical (diagnostics) on the self-check tree,
plugins/examples, Mastodon `app/models`, kramdown `lib`, and haml `lib`
with `RIGOR_SHADOW_RULE_WALK=1` active and silent (it caught a real
identity-`==` mismatch on the main pass's first run, before any drift);
`rule_walk_equivalence_spec` hosts all five collectors (174 examples);
bench-perf neutral. **Remaining: Track B B4** — convergence with ADR-52
WD4's `Plugin::NodeRuleWalk` (since landed; the natural host) into one
walk per file total.

Grounding:
[`docs/notes/20260610-lib-rigor-architecture-rereview.md`](../notes/20260610-lib-rigor-architecture-rereview.md)
(Phase 4 — the two re-review findings that need a design judgment, B-4 and
A-4), with the boilerplate axis grounded in
[`…-structural-repetition-audit.md`](../notes/20260604-structural-repetition-audit.md)
(Theme B, deferred pending a traversal-equivalence harness) and the prior
performance verdict in [ADR-44](44-dispatch-allocation-churn.md).

## Context

The pre-release architecture re-review found the engine's foundation sound
(acyclic layering, immutable-Scope discipline, unified dispatch tiers) but
left two structural items that are genuine design judgments rather than
mechanical cleanups.

**(A) `Rigor::Scope` carries two different kinds of state.** Its
*flow state* — `locals`, `fact_store`, `self_type`, `ivars`/`cvars`/`globals`,
`indexed_narrowings`, `method_chain_narrowings` — is what control-flow
transitions rebind, join, and invalidate. Alongside it ride **14 discovery
tables** (`declared_types`, `class_ivars`, `class_cvars`, `program_globals`,
`discovered_classes`, `in_source_constants`, `discovered_methods`,
`discovered_def_nodes`, `discovered_def_sources`,
`discovered_method_visibilities`, `discovered_superclasses`,
`discovered_includes`, `discovered_class_sources`, `data_member_layouts`)
that are written once when `ScopeIndexer` seeds the file's scope and never
change across a flow transition. The code already treats them as ambient
context, not state: `Scope#==` / `#hash` ignore all of them
(`scope.rb:655-671`), and `#join` copies them from `self` unexamined
(`build_joined_scope`, `scope.rb:730-757`).

The cost is **not allocation** — ADR-44's object-shape benchmark showed a
frozen object with 3 or 25 ivars allocates exactly one heap object — it is
boilerplate and boundary:

- Adding one side-table costs **seven edit sites** in `scope.rb` alone
  (attr_reader, constructor kwarg, ivar assignment, `rebuild` kwarg default,
  `rebuild` pass-through, `build_joined_scope` pass-through, the `with_*`
  writer). ADR-48's `data_member_layouts` was the latest to pay it, and
  ADR-46/ADR-52 both keep adding per-run context.
- `rebuild` (`scope.rb:675-712`) is the engine's most-travelled constructor
  and now threads 24 keyword arguments, most of which no transition ever
  varies.
- The public `Scope` surface mixes "ask the flow state" with "ask the
  project" queries, which blurs exactly the boundary
  `docs/internal-spec/public-api.md` has to freeze at v1.0 (ADR-50).

**(B) `Analysis::CheckRules` walks each file five times.** The main
`Source::NodeWalker.each` pass (`check_rules.rb:167`) plus four independent
collector walks (`IvarWriteCollector` `:228`, `DeadAssignmentCollector`
`:242`, `AlwaysTruthyConditionCollector` `:255`, `UnreachableClauseCollector`
`:265`), on top of `ScopeIndexer`'s own walk and one walk per
node-rule-bearing plugin. The collectors were left separate deliberately:
their traversal contracts differ (`IvarWriteCollector` threads a
`qualified_prefix` with `BARRIER_NODES`; `DeadAssignmentCollector` scans only
`DefNode` bodies with a nested-def barrier; the two flow collectors thread an
identical `in_loop_or_block` flag), and traversal order is load-bearing for
diagnostics. Consolidation is the same risk class as the deferred
scope_indexer walker unification (structural-repetition Theme B): safe only
behind an equivalence harness.

Why now: both changes touch surfaces the ADR-50 freeze will lock (the public
`Scope` reader surface; diagnostic output stability), so the cheap window is
pre-v1.0 — and ADR-52's engine-owned plugin walk (WD4) creates the natural
convergence point for (B).

## Decision

Adopt both, as separately gated tracks under one shared discipline: **no
behavioural change is ever accepted on faith — every slice gates on
byte-identical diagnostics, and the walk consolidation additionally requires
a shadow-run equivalence harness before any collector merges.**

### Track A — extract `Scope::DiscoveryIndex`

**Criterion (membership):** a `Scope` field moves into the index **iff no
flow transition ever produces a scope whose value for that field differs
from its seed** — it is written only at index/seed time. The litmus is
already in the code: `Scope#==` ignores it and `#join` copies it from `self`
unexamined. All 14 tables above pass; `source_path` does not move (it is
per-file identity, not a discovery product, and plugins read it directly);
`environment` and all flow state stay.

**Shape:** one immutable, frozen value object (`Rigor::Scope::DiscoveryIndex`)
holding the 14 tables, built by `ScopeIndexer` at seed time; `Scope` holds a
single `@discovery` reference (25 ivars → 11; `rebuild` 24 kwargs → 11).
Frozen and deep-shareable, so it is Ractor-shareable for the ADR-15 worker
path like ADR-52's compiled table.

**Public-surface preservation:** every existing keyed reader
(`user_def_for`, `top_level_def_for`, `user_def_site_for`, `superclass_of`,
`includes_of`, `discovered_method?`, `discovered_method_visibility`,
`data_member_layout`, `class_ivars_for`, `class_cvars_for`, …) stays on
`Scope` as a delegate — engine call sites and plugins see no change. The
ADR-46 `DependencyRecorder` instrumentation lives in those accessors
(`scope.rb:350`, `:444`, `:465`, `:483`); it moves with the delegates and
**must remain the single choke point** — relocating storage must not open a
second uninstrumented read path. The per-table `with_discovered_*` writers
(seed-time only, never plugin-facing in practice) collapse into a single
`with_discovery(index)`; they survive as shims during migration and are
deleted at the end of the track (deliberate pre-1.0 cleanup, same posture as
ADR-52 WD3).

**Relationship to ADR-44:** ADR-44 evaluated this regrouping as an
*allocation* lever and correctly downgraded it (size, not count). This ADR
re-adopts it on the *boundary/boilerplate* criterion; the smaller `Scope`
slot and shorter kwarg list are a bonus, not the motivation. Performance is
claimed **neutral**, verified by `make bench-perf` — any regression blocks
the slice.

### Track B — single engine-owned check-rule walk

**Criterion:** a separate per-file AST walk is justified **only by traversal
semantics the shared walk cannot reproduce**. A consolidated `RuleWalk`
threads the union context the four collectors need — qualified class prefix
(IvarWrite), enclosing-def with nested-def barrier (DeadAssignment),
`in_loop_or_block` (the two flow collectors) — and dispatches
`node class → [collector hooks]`, the ADR-52 WD4 model applied to built-in
rules. End state: per file, one `ScopeIndexer` walk + one rule walk
(built-ins **and**, after ADR-52 WD4, plugin node_rules) — down from 6 + N.

**Hard precondition — the equivalence harness:** a shadow-run mode that
executes legacy collectors and the merged walk side by side over the
self-check tree + the Mastodon/GitLab corpora and asserts identical collected
results (and byte-identical diagnostics downstream). No harness, no merge.
The harness is the shared asset the deferred Theme B (scope_indexer walker
unification) was waiting for; building it here unblocks that later work but
Theme B itself stays out of scope.

**Order of attack:** merge the two flow collectors first (their traversal
contracts are already identical — lowest risk, proves the harness), then
fold in IvarWrite/DeadAssignment, then the main `NodeWalker.each` pass, then
(jointly with or after ADR-52 WD4) the plugin walk.

## Working decisions

- **WD1 — index lives under `Scope`, not `Environment`.** `Environment` is
  run-global and shared across files; the discovery tables are per-file-seed
  (per-file `ScopeIndexer` output merged with the cross-file pre-pass).
  Parking them on `Environment` would force per-file mutation of a
  run-global object or per-file `Environment` clones — both worse than the
  status quo.
- **WD2 — delegation, not relocation, for readers.** Callers (engine +
  plugins) keep calling `scope.user_def_for(...)`. A future v1.0 lock list
  may expose `Scope#discovery` directly; that is `public-api.md`'s call, not
  this ADR's.
- **WD3 — `Scope#==`/`hash` semantics unchanged.** They already ignore the
  discovery tables; the extraction makes that textual instead of accidental.
  Asserting index identity in `==` would be a behaviour change and is not
  taken.
- **WD4 — collectors keep their per-collector logic; only traversal merges.**
  The merge unifies *walking*, not *deciding* — each collector's gather/filter
  logic transplants verbatim as hooks. Any logic change is out of scope.
- **WD5 — staging.** A1: introduce `DiscoveryIndex` + delegates + shims.
  A2: collapse seeding to `with_discovery`, delete shims. B1: harness.
  B2: merge the two flow collectors. B3: IvarWrite + DeadAssignment + main
  pass. B4: converge with ADR-52 WD4's plugin walk. A and B are independent;
  within each track the order is binding.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Mutable `Scope` with phase-switched tables | Rejected | ADR-44 already rejected mutable/pooled scopes: re-entrancy → silent narrowing corruption → false positives. |
| Discovery tables on `Environment` | Rejected | Wrong lifetime (run-global vs per-file-seed); see WD1. |
| Folding the rule collectors into `ScopeIndexer`'s walk (one walk total) | Rejected | Collectors read the *completed* `scope_index`; collecting during indexing couples diagnostics to indexing order and widens the blast radius for no additional walk saved beyond Track B's end state. |
| Renaming `Analysis::FactStore` → `Inference::` (the namespace twist the re-review noted) | Deferred | Cosmetic; no behavioural or boundary payoff. Revisit only if a v1.0 namespace audit forces it. |
| Full generic-visitor rewrite of `scope_indexer.rb` (Theme B) | Deferred | Unchanged from the structural-repetition audit: highest-risk traversal surface. Track B's harness is its enabling asset; the rewrite itself stays demand-gated. |
| Asserting discovery-index identity in `Scope#==` | Rejected | Behaviour change with FP-adjacent reach (scope-equality short-circuits); see WD3. |

## Consequences

Positive:

- A new side-table becomes a **one-site** addition (a `DiscoveryIndex`
  field) instead of seven, removing the recurring tax ADR-46/48/52-class
  work keeps paying.
- `Scope` reads as what the internal spec says it is — flow state + an
  ambient discovery reference — which is the boundary `public-api.md` must
  freeze at v1.0.
- Per-file walks drop from 6 + N to 2 once Track B and ADR-52 WD4 both land.
- The equivalence harness becomes reusable infrastructure for any future
  traversal change (Theme B, future collector additions).

Negative / risks:

- One extra delegation hop per discovery read on hot paths
  (`user_def_for` is consulted per dispatch fallback) — expected lost in
  noise, but `make bench-perf` gates it, not intuition.
- Migration churn in every seeding site (`ScopeIndexer`, `Runner`
  pre-passes, `WorkerSession`) — mechanical but wide; the shim stage exists
  to keep it bisectable.
- The harness is real up-front cost paid before any user-visible win in
  Track B; accepted because the alternative (merging on inspection alone)
  is exactly the FP-discipline violation this repo rejects.

## Verification

Every slice: full `make verify` (test / lint / check / check-plugins) +
byte-identical `rigor check` diagnostics over the self-check tree and the
Mastodon (6-plugin) / GitLab (11-plugin) survey corpora (cwd=target +
project `.rigor.yml`, per the profiling-methodology note) + `make bench-perf`
within tolerance. Track B slices additionally run the shadow-run harness
over the same corpora. Acceptance for the ADR as a whole: shims deleted,
walks at 2 per file (with ADR-52 WD4), zero diagnostic drift anywhere.

## Relationship to other ADRs

- **[ADR-44](44-dispatch-allocation-churn.md)** — measured the regrouping's
  allocation-neutrality and downgraded it as a perf lever; this ADR
  re-adopts it on the boundary criterion. The mutable-scope rejection
  carries over verbatim.
- **[ADR-46](46-incremental-dependency-graph.md)** — the
  `DependencyRecorder` choke point lives in the accessors Track A delegates;
  preserving its single-path property is a Track A guardrail.
- **[ADR-48](48-data-struct-value-folding.md)** — `data_member_layouts` is
  the worked example of the seven-site tax Track A removes.
- **[ADR-52](52-compiled-plugin-contribution-dispatch.md)** — sibling
  restructuring: same compile-once / gate-by-held-key philosophy; Track B's
  end state merges with its WD4 single plugin walk.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — sets the
  timing: both tracks touch v1.0-freeze surfaces, so they land pre-freeze or
  wait for a major.
- **`docs/internal-spec/inference-engine.md`** — binds the `Scope` contract;
  when Track A lands, the spec gains the `DiscoveryIndex` description in the
  same change (spec binds, ADR records why).
