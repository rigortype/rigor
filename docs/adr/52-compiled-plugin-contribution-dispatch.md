# ADR-52 — Compiled plugin contribution dispatch

Status: **Accepted — slice 1 (WD1) implemented 2026-06-10** (commits
`67a552de` + `1deecb2f`: the compiled contribution table + the six engine
call-site rewirings; gated per WD6 on byte-identical diagnostics over the
Mastodon 6-plugin and GitLab 11-plugin corpora — the first GitLab sweep
caught a real regression, a nameless `&:symbol` BlockArgumentNode raising in
the new name gate and silently nil-ing the block type, fixed + pinned by
regression specs in the second commit). Wall time is neutral at this slice,
as designed: the global gate stays inert while legacy `flow_contribution_for`
plugins are loaded, so the throughput win arrives with the WD3 migrations.
**Slice 2 (WD2 static receiver-less form) implemented 2026-06-10** (`c3550b00`
+ `cd5d5990`: `receivers:` optional, gate on `methods:` alone; migrated
`rigor-units`). The **audit's slice-2 plugin targets were wrong** — see "Audit
correction". **Slice 3 (run-time receiver-set callable) partly implemented**
(`fb5aea04`/`0f1a64b2` engine + `be4c532c` rigor-activestorage, GitLab-corpus
byte-identical); **rigor-activerecord is blocked** on the receiver-type gate
(class-side paths are AST/`self_type`-keyed, model constants type as `Dynamic` —
a migration attempt was made and reverted; see "rigor-activerecord blocker").
**Slice 4 (run-time method-name-set callable) partly implemented**
(`79dc790d` engine + `46b14280` rigor-lisp-eval / rigor-pattern examples,
end-to-end-spec + demo byte-identical). **rigor-sorbet migrated 2026-06-11**:
its `flow_contribution_for` became a `dynamic_return methods:` callable (the
static assertion vocabulary ∪ `:absurd` ∪ a new `Catalog#method_names`
enumerator) plus a `type_specifier methods: [:bind]` carrying `T.bind`'s
self-narrowing fact (the dispatcher path only consumes `return_type` from the
merge and the statement path only `post_return_facts`, so the split is
behaviour-preserving — `T.absurd`'s `exceptional: :raises` slot was already
dropped by the dispatcher's `Merger.merge(...).return_type`, the `bot` return
carries the unreachability); side effects (absurd/reveal/assert-type
recording, sigil gate) moved into the rule block; gated on the 63-example
end-to-end integration spec + byte-identical `rigor check` on the strap and
dependabot-core sorbet corpora. The migration also delivered the first big
WD3 throughput win: dependabot-core (20 sig-heavy files) 1262.6s → 33.4s
(~38×) — the ungated hook ran a catalog chain lookup (incl. a per-dispatch
receiver re-type via `scope.type_of`) on every named call. rigor-rspec (per-file) remains. Slices 5–6
(hook deletion — blocked on AR + rspec; single node-rule walk — independent)
remain.
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

- *Static method-name-only gating*: `dynamic_return methods: [...]` with no
  `receivers:` (receiver-independent rules whose name set is known at class
  definition). **Implemented 2026-06-10** (`c3550b00`); migrated `rigor-units`
  (`cd5d5990`), whose gate is the receiver *dimension* — a refinement carrier
  with no nominal class — read inside the block.
- *Run-time receiver sets*: `dynamic_return receivers: -> { model_index.keys }`
  — a callable `instance_exec`'d against the plugin and memoised per rule,
  resolved lazily the first time the rule is consulted (always after
  `#prepare`). Covers rigor-activerecord / -activestorage, whose receiver sets
  exist only after their `prepare`-time project scan. **Implemented 2026-06-10**
  (`fb5aea04`/`0f1a64b2`); migrated `rigor-activestorage` (`be4c532c`,
  GitLab-corpus byte-identical). The resolution lives in the instance
  `dynamic_return_type` path, not the `ContributionIndex` (a receiver-gated rule
  carries no `methods:` gate, so the registry sees it exactly as a static-receiver
  rule); the resolved set is a safe over-approximation of the block's own filter
  (it admits subclasses), so the block stays the precise gate. rigor-activerecord
  **cannot use this gate** — see "rigor-activerecord blocker".
- *Run-time method-name sets*: the method-name analogue of the above — a
  `methods:` callable resolved after `#prepare`, memoised, symmetric with the
  receiver-set callable. **Implemented 2026-06-11** (`79dc790d`); migrated the
  `rigor-lisp-eval` and `rigor-pattern` examples (`46b14280`, their end-to-end
  specs + demos byte-identical). A callable method set cannot be compiled into
  the registry name gate (unknown at registry-build time), so the plugin is
  consulted on every dispatch and the name filter runs in the instance
  `dynamic_return_type` path — the block still fires only for a listed name, so
  diagnostics are unchanged. **This is the form rigor-sorbet uses** (its catalog
  keys arbitrary `def` method names harvested at run time; see "Audit
  correction") — **migrated 2026-06-11** via a new `Catalog#method_names`
  enumerator + the `type_specifier` split for `T.bind`'s self-narrowing fact.
  Per-file name sets (rigor-rspec's lets, per-file dynamic) are the
  file-scoped specialisation, still remaining.

### rigor-activerecord blocker (2026-06-10)

A first attempt to migrate rigor-activerecord onto the run-time receiver-set
callable was **made and reverted** — it regressed AR's most common case, caught
by the plugin's own end-to-end specs before any corpus run.

Root cause: the `dynamic_return` receiver gate keys on the call's
**`receiver_type`** (the engine extracts a class name from a `Nominal` /
`Singleton` carrier). But AR's two class-side paths do not read the receiver
type — `class_call_return_type` reads the **AST** (`constant_receiver_name`),
and `implicit_self_class_call_return_type` reads **`scope.self_type`**. For a
project model that is not in RBS — i.e. nearly every real model — the constant
`User` types as **`Dynamic[top]`**, not `Singleton[User]` (verified: `User.find(1)`
dispatches with `receiver_type = Dynamic`, `class_name = nil`). So the gate
declines `User.find`, `u` never narrows to `Nominal[User]`, and the whole
instance chain (`u.name → String`) collapses. The old `flow_contribution_for`
never saw `receiver_type`; it read the AST, so it worked regardless of how the
constant typed.

This is a real limit of the receiver-type gate, not an AR bug. AR's
instance/relation paths (`user.posts`, `relation.scope`) *would* gate fine
(those receivers are real `Nominal[...]`), but a partial migration that leaves
the hook for the class-side paths defeats the purpose (slice 5 wants the hook
*gone*). So AR stays on `flow_contribution_for` until one of:

- **(A)** the engine types a discovered in-source class constant as
  `Singleton[Class]` (broad, high-risk dispatch change — its own ADR);
- **(B)** a new gate form that keys on the **AST receiver constant name** (a set
  the engine already holds at the call node) and/or **implicit-self in a class
  body**, rather than the receiver *type* — the honest successor form for
  AST-keyed plugins. This is the slice-4+ design question AR raises.

The exact-membership-Set refinement of the callable gate (O(1) for large model
sets, vs the ancestor-walk `any?`) was prototyped alongside this attempt and
reverted with it — it is only worth landing together with a working AR
migration, since activestorage's set is small enough that the ancestor-walk
cost is negligible.

### Audit correction (2026-06-10)

The grounding audit's slice-2 plugin table was wrong on both counts, discovered
when implementing the migration:

- **rigor-activesupport-core-ext ships no `flow_contribution_for` at all** — it
  is a pure RBS-bundle plugin (`signature_paths:` only, zero analyzer code). It
  is not a migration target; the audit's grep matched a comment that says so.
- **rigor-sorbet does not fit a static name gate.** Its `flow_contribution_for`
  has three paths: the `T.*` assertions (static names), `T.absurd` (one name),
  **and a catalog lookup that fires on any `def` method carrying an ingested
  sig** — a run-time name set, not a static one. So sorbet belongs to the
  *run-time method-name set* form (slice 3+), not the static slice-2 form.

Net effect: **no production plugin fit the static slice-2 gate**; the static
form's first real consumer is the `rigor-units` example. The four production
plugins (activerecord, activestorage, rspec, sorbet) all need a run-time
(receiver- or method-) set, consolidating them into the slice-3 callable work.
The slice list below is renumbered accordingly.

**WD3 — Migrate the remaining legacy plugins, then remove the hook.** The four
production users all need a run-time set (per "Audit correction"): activerecord
+ activestorage (run-time receiver sets), sorbet (run-time method-name set, its
catalog keys), rspec (per-file name set). The two `examples/` users still on the
hook (lisp-eval, pattern, both config-gated on a single method name) migrate
alongside. Each migration gates on byte-identical diagnostics over its
integration spec plus the relevant OSS corpus. After the last migration,
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

1. **DONE** (`67a552de` + `1deecb2f`) — WD1 table + engine call-site rewiring
   (no contract change).
2. **DONE** (`c3550b00` + `cd5d5990`) — WD2 static method-name-only
   `dynamic_return` (receiver-less) + migrate the `rigor-units` example (the
   only consumer that fits the static gate; see "Audit correction").
3. **PARTLY DONE** — WD2 run-time receiver-set callable (`fb5aea04`/`0f1a64b2`)
   + migrate rigor-activestorage (`be4c532c`, GitLab-corpus byte-identical).
   **rigor-activerecord is BLOCKED** on the receiver-type gate (its class-side
   paths are AST/`self_type`-keyed, and project model constants type as
   `Dynamic`) — see "rigor-activerecord blocker"; it needs a new gate form
   (engine Singleton-typing of discovered classes, or an AST-constant /
   implicit-self gate) before it can leave the hook.
4. **PARTLY DONE** — WD2 run-time method-name-set callable (`79dc790d`) +
   migrate the config-gated `rigor-lisp-eval` and `rigor-pattern` examples
   (`46b14280`, end-to-end-spec + demo byte-identical) + **rigor-sorbet
   (2026-06-11)** — `dynamic_return methods:` callable over
   `SORBET_ASSERTIONS ∪ :absurd ∪ Catalog#method_names`, `type_specifier`
   for `T.bind`'s fact, side effects relocated into the rule block;
   strap + dependabot-core corpora byte-identical. Remaining: rigor-rspec
   (per-file name set) and AR's AST-keyed gate form (design open — see
   "rigor-activerecord blocker").
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
