# ADR-52 — Compiled plugin contribution dispatch

Status: **Proposed, 2026-06-10.** Slice plan below; nothing implemented yet.
Archetype: deliberative. Stakes: mid-high (touches the plugin contract and the
engine's hottest path; precision-neutral by construction — the acceptance gate
is byte-identical diagnostics).

Grounding: [plugin-architecture structural audit
(2026-06-10)](../notes/20260610-plugin-architecture-perf-audit.md), building on
the [Mastodon](../notes/20260604-mastodon-allocation-profile.md) /
[GitLab](../notes/20260604-gitlab-plugin-contribution-allocation.md) allocation
profiles and the ADR-44 landings.

## Context

Per-call plugin consultation is the engine's top plugin-related cost on
plugin-heavy projects (GitLab: `collect_plugin_contributions` was 40.7 %
inclusive allocation before the ADR-44-era fixes). The fixes so far —
`Registry::ContributionIndex` structural pruning, memoised rule snapshots, lazy
accumulation — all share one shape: *make asking every plugin cheaper*. The
audit shows the remaining cost is structural and cannot be fixed by more of the
same:

1. **The legacy `flow_contribution_for` hook is ungated.** Its five remaining
   users are the most-deployed plugins (rigor-activerecord, -activestorage,
   -activesupport-core-ext, -rspec, -sorbet). Each runs on **every call node,
   twice** (`MethodDispatcher#collect_plugin_contributions`,
   `method_dispatcher.rb` ~L695, and `StatementEvaluator`'s
   `apply_plugin_assertions` path, `statement_evaluator.rb` ~L1407). Their gate
   conditions live inside opaque plugin code, so the engine cannot index them.
   The blocker is DSL vocabulary: `dynamic_return` (ADR-37 slice 2) only
   accepts a *static class-name Array*, and these five gate on run-time
   receiver sets (AR's `model_index`), bare method-name sets (sorbet's `T.*`),
   or per-file name sets (rspec's lets).
2. **No cross-plugin method-name index.** `type_specifiers` are purely
   method-name-gated yet matched by per-plugin, per-rule linear `include?`;
   `dynamic_return_type` re-runs receiver ancestry matching per rule per
   dispatch. The overwhelmingly common case — no plugin cares about this call —
   costs O(plugins × rules) to discover.
3. **Frozen-registry queries recompute per call.** `Registry#open_receiver?`
   (per undefined-method candidate), `#additional_initializers` (per def, ×2
   sites in `ScopeIndexer`), `#contracts_for_path` (per def, full fnmatch
   sweep), and `MethodDispatcher#plugin_owns_receiver?` (per fallback dispatch,
   plugins × owns_receivers × `class_ordering`) all `flat_map` over a registry
   that is frozen at construction.
4. **Node rules walk the AST once per plugin** (`Plugin::Base#node_rule_diagnostics`),
   and `MacroBlockSelfType` linearly scans plugins × `block_as_methods` per
   block call site.

Pre-release context: ADR-50 freezes the public plugin surface at v1.0, not
before. Removing the legacy hook now is a sanctioned BC break; after v1.0 it
becomes expensive. That timing asymmetry is why this lands as one coherent
restructuring rather than further spot fixes.

## Decision

Adopt the **compiled-dispatch criterion** for every plugin consultation the
engine performs per call site, per def, per file, or per node:

> A plugin consultation MUST be gated by a key the engine already holds at the
> consultation site — method-name `Symbol`, receiver class name, file path, or
> `Prism::Node` class — looked up in a structure compiled once per run at
> registry build. Plugin code executes only on candidate hits. A plugin
> capability that cannot declare such a key is a **DSL vocabulary gap to fix in
> the contract**, not a license for an ungated hook.

Concretely: extend `ContributionIndex` into a compiled **contribution table**
(WD1), grow the declarative DSL until the five legacy users can state their
gates (WD2), migrate them and **remove** `flow_contribution_for` (WD3), and
fold the per-plugin AST walks into one engine-owned walk (WD4). The comparator
is PHPStan's extension registry (class-keyed
`DynamicMethodReturnTypeExtension`); Rigor needs the richer key set because its
plugins also gate on bare names and per-file state.

## Working decisions

**WD1 — Compile a per-run contribution table at registry build.** Extend
`Registry::ContributionIndex` (`lib/rigor/plugin/registry.rb` ~L17) into a
frozen table holding: a method-name inverted index
`Hash[Symbol → [(plugin, rule)]]` for all `type_specifiers` and for
`methods:`-gated `dynamic_returns`; a residual receiver-gated bucket for
`methods:`-less `dynamic_returns`; a verb-keyed `Hash` for
`block_as_methods` (consumed by `MacroBlockSelfType`, currently
`macro_block_self_type.rb` ~L55); `open_receivers` as a `Set`;
`additional_initializers` / `owns_receivers` as frozen unions with a per-run
`(class_name, constraint) → bool` ancestry memo (sound — the class graph is
fixed per run); `contracts_for_path` memoised per path; and a
`diagnostics_for_file`-override bit per plugin (same `Method#owner` trick as
`flow_overridden?`) so the runner skips default-`[]` implementations. Engine
call sites (`method_dispatcher.rb` ~L695, `statement_evaluator.rb` ~L1439,
`check_rules.rb` ~L605, `scope_indexer.rb` ~L446/507,
`method_parameter_binder.rb` ~L234, `runner.rb` ~L1699) switch to table
lookups. No DSL change; diagnostics identical by construction.

**WD2 — Three DSL vocabulary additions** (def-forms open to adjustment at
implementation, per the ADR-50 precedent):

- *Run-time receiver sets*: `dynamic_return receivers: -> { model_index.keys }`
  — a callable evaluated **once per run after `#prepare`**, result frozen into
  the table. Covers rigor-activerecord / -activestorage, whose receiver sets
  exist only after their `prepare`-time project scan.
- *Method-name-only gating*: `dynamic_return methods: [...]` with no
  `receivers:` (receiver-independent rules). Covers rigor-sorbet (`T.let`,
  `T.cast`, `T.must`, `T.absurd`, …) and rigor-activesupport-core-ext.
- *Per-file name sets*: a declared per-file gate
  (`dynamic_return file_methods: ->(path) { ... }`-shaped) evaluated once per
  analysed file and merged into a per-file name gate. Covers rigor-rspec's
  lets, which are per-file dynamic.

**WD3 — Migrate the five legacy plugins, then remove the hook.** Migration
order = cheapest gate first: sorbet + activesupport-core-ext (name sets) →
activerecord + activestorage (run-time receiver sets) → rspec (per-file).
Each migration gates on byte-identical diagnostics over its integration spec
plus the relevant OSS corpus. After the last migration,
`flow_contribution_for` is **deleted** (base method, both collectors, the
`ContributionIndex` flow path) — not kept as a shim. Pre-1.0 removal is the
point (see Context); third-party authors (ADR-31) get a CHANGELOG migration
note mapping each legacy idiom to its WD2 form.

**WD4 — One AST walk per file for node rules.** The runner merges every
plugin's `node_rules` into a `node_type → [(plugin, rule)]` table and owns a
single `NodeWalker.each_with_ancestors` pass per file, allocating one
`NodeContext` per node (today: one per matching rule,
`plugin/base.rb` ~L419-427). Per-plugin `node_file_context` builders still run
once per (plugin, file); rule blocks still `instance_exec` on their own plugin.
Diagnostic order changes from plugin-major to node-major — the runner sorts
per-file plugin diagnostics before emission (they are already
location-sorted downstream), keeping output stable.

**WD5 — The dispatcher/statement double consultation needs no cache.** Both
collectors stay, but after WD1–WD3 each becomes a hash probe that almost
always misses. A per-call-node contribution *result* cache was considered and
rejected: results depend on the scope at consultation time (narrowing state),
so node-keyed caching risks stale types — an FP-shaped failure mode
(cf. the ADR-44 pooled-Scope rejection and the ADR-45 pre-analysis-fingerprint
lesson). Gate-level indexing is scope-independent and achieves the same
saving.

**WD6 — Verification protocol per slice.** (a) `make verify` +
`make check-plugins`; (b) **byte-identical diagnostics** on Mastodon
`app/models` (6 plugins) and the GitLab configured subset (11 plugins), run
cwd=target with the project's own `.rigor.yml` (the profiling notes'
methodology — cwd=rigor breaks plugin relative-path discovery); (c) stackprof
`:object` + GC-stat deltas recorded in a follow-up `docs/notes/` entry;
(d) `make bench-perf` stays within the ADR-50 tolerance band.

## Implementation slices

1. WD1 table + engine call-site rewiring (no contract change).
2. WD2 name-set vocabulary + migrate rigor-sorbet, rigor-activesupport-core-ext.
3. WD2 run-time receiver sets + migrate rigor-activerecord, rigor-activestorage.
4. WD2 per-file gate + migrate rigor-rspec.
5. Delete `flow_contribution_for`; update ADR-2/ADR-37 status lines, the
   plugin-author skill, `examples/` walkthroughs, CHANGELOG migration note.
6. WD4 single-walk node rules (independent of 2–5; may land any time after 1).

## Rejected / deferred alternatives

| Alternative | Reason rejected |
| --- | --- |
| Keep `flow_contribution_for` with documented internal-gating conventions | Unenforceable and unindexable — the engine cannot prove an opaque hook irrelevant to a call; the cost class survives. |
| Keep the hook as a permanent third-party escape valve | Defeats the criterion for exactly the plugins most likely to be hot; removal is cheap pre-1.0 and expensive after the ADR-50 freeze. |
| Per-call-node contribution result cache | Scope-sensitive results → stale-type / FP risk (WD5). |
| Mutable pooled collectors / scopes | Already rejected on re-entrancy → FP grounds (ADR-44). |
| PHPStan-style class-keyed-only registry | Insufficient vocabulary: Rigor's plugins also gate on bare method names (sorbet) and per-file state (rspec). |
| More ADR-44-style spot fixes, no contract change | Each new plugin re-introduces linear per-call cost; the audit shows the remaining cost is in the contract, not the implementation. |

## Consequences

- **Positive.** The no-plugin-cares fast path becomes O(1) per consultation
  site; registry queries stop allocating; node-rule cost stops scaling with
  plugin count. The plugin contract becomes declarative-only — ADR-37 reaches
  its stated end-state ("the engine owns the traversal, the plugin owns the
  check") for the per-call surface too. The compiled table is frozen and
  Ractor-shareable, shrinking ADR-15 Phase 4's per-worker rebuild.
- **Negative / carried risk.** DSL vocabulary grows by three forms (spec +
  docs + `rigor-plugin-author` skill updates); five production plugins churn;
  per-file gates add one plugin callback per analysed file; behavioural drift
  during migration is the real risk and is held by WD6's byte-identical gate.
  Removing the hook breaks unmigrated third-party plugins — accepted
  deliberately while pre-release.

## Relationship to other ADRs

- **ADR-2 / ADR-37** — completes the interface-segregation arc; ADR-2's
  "Flow Contribution Bundle" per-call hook is superseded (the
  `FlowContribution` carrier itself remains the merger's interchange type).
- **ADR-44 / ADR-45** — siblings: ADR-44 cut the cost of asking; this removes
  the asking. The WD5 rejection reuses their soundness lessons.
- **ADR-15** — the frozen table is Ractor-shareable input for the Phase 4 pool.
- **ADR-50** — contract change lands before the v0.2.0 rehearsal pledge; the
  WD2 forms become part of the enumerated public surface frozen at v1.0.
