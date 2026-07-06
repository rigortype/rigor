# ADR-82 — `Dynamic[T]` provenance wiring: breaking the catch-all on real apps

Status: **WD1+WD2+WD3 implemented 2026-07-06.** [ADR-75](75-dynamic-provenance.md) added the `Dynamic[T]`
provenance side-channel and surfaced it through `coverage --protection`
tractability labels, but a field measurement on Mastodon shows the labels are
**uninformative on a real Rails app**: 84% of unprotected dispatch sites carry
the catch-all `unsupported_syntax` (→ `engine_gap`) cause and another 14% carry
no cause at all, while the two *user-actionable* causes the label exists to
surface — `framework_dsl_boundary` (→ enable a plugin) and
`external_gem_without_rbs` (→ add RBS) — fire on **zero** sites. This ADR wires
the provenance recording and lookup so the catch-all breaks into the actionable
buckets a user (or agent) can act on. It is precision-additive throughout — no
type, diagnostic, or severity changes, per ADR-75's side-channel contract.

**WD5 measurement outcome (2026-07-06):** WD2+WD3 landed the cheap recording
slices — a new `inferred_return_untyped` cause recorded at the discovered-method
and user-class-fallback tiers. On Mastodon app+lib they re-bucket **211 sites**
(unsupported_syntax 17,727→17,565, null 2,921→2,872) out of 21,119 unprotected —
~1%, protection ratio unchanged (precision-additive confirmed). Spot-adjudicated:
the moved sites are `<user-method>.foo` chains where the receiver is a resolved
memoized/attribute method whose return the engine cannot infer (`parsed_uri.path`
with `def parsed_uri`, `media_attachment_file.path`), correctly attributed. The
small size **confirms the G1 diagnosis**: the dominant 84% has local/ivar-read
receivers whose origin the call-node record does not reach, so **WD1 (lookup
propagation) is required, not demand-gated** — the measurement resolves WD5's
open question in favour of building WD1.

**WD1 outcome (2026-07-06) — implemented, perf-neutral, and honestly modest.**
WD1 propagates a local / ivar binding's origin to a later bare `x` / `@x`
receiver read (`Scope#local_origins` / `#ivar_origins` side-tables, set at
assignment, consulted by `ProtectionScanner` when the receiver's own node has no
origin). It is perf-neutral — Mastodon `lib` allocations move +0.1% (27.54M vs
master's 27.51M; the `make bench-perf` gate fails only because its committed
baseline, 19.77M / 16.6s wall, is stale — master itself fails it at the same
27.5M / 7.2s). But the coverage payoff is **smaller than the "primary lever"
framing predicted**: on Mastodon app+lib it moves ~**322 sites out of the null
(no-cause) bucket** (null 2,872→2,550), ratio unchanged. The reason, found by
adjudicating the residual: the dominant catch-all receivers are **not** bare
local/ivar reads (those are the small null bucket WD1 addresses) but
**intermediate-expression / chain receivers** — `signed_request_account.uri[…]`
(the `[]` receiver is a call chain), `account_id_param.present?` (the receiver is
a method call), `Status.tagged_with(tag.id)`. A chain link's `.foo` dispatched on
a `Dynamic` receiver records the *generic* `unsupported_syntax` on its result and
loses the upstream cause. So the evidenced **next** lever is **WD6 — chain-origin
inheritance**: a dispatch on a `Dynamic` receiver inherits the receiver's origin
onto its result, so provenance survives a method chain. It touches the hottest
path (every call dispatch) and needs its own measured, FP-analyzed slice, so it
is deliberately deferred rather than tacked on here. WD1 is retained: it is
correct, precision-additive, perf-neutral, reduces the null bucket, and is the
binding-propagation half of the foundation WD6 builds on.

Grounding: the [2026-07-06 Mastodon coverage/provenance note](../notes/20260706-mastodon-coverage-provenance-and-siggen-rbs-validity.md)
§2 (measurement + the two engine gaps G1/G2) and the
[2026-07-04 Rails onboarding note](../notes/20260704-rails-coverage-onboarding-carrier-trap.md)
§O5, which first named the catch-all mislabel as a lever but left it unimplemented
while that session's work went to the coverage-scope fixes (plugin-aware +
discovery-seed).

## Context

`coverage --protection` ([ADR-63](63-type-protection-coverage.md)) ranks the
"add a type here" holes and — since [ADR-75](75-dynamic-provenance.md) — tags
each with a *tractability*: `add_rbs`, `enable_plugin`, or `engine_gap`. The
intent is to route attention: a hole a hand-written RBS closes is not a hole
the user should wait on the engine for. On Mastodon `app`+`lib` (Rigor v0.2.7,
30,822 dispatch sites, 21,119 unprotected) the distribution is:

| tractability (cause) | sites | share |
| --- | --- | --- |
| `engine_gap` (`unsupported_syntax`) | 17,727 | 84.0% |
| (no cause recorded / null) | 2,921 | 13.8% |
| `add_rbs` (`explicit_untyped`) | 471 | 2.2% |
| `enable_plugin` (`framework_dsl_boundary`) | 0 | 0% |
| `add_rbs` (`external_gem_without_rbs`) | 0 | 0% |

The receivers driving the holes are ordinary Rails idioms — `Tag.find_normalized(...).id`
(a custom ActiveRecord finder returning `untyped`), `current_user&.account&.unavailable?`
(a Devise helper), `params[:limit].present?` (ActionController). These *should*
route to "enable a plugin" or "add RBS"; instead they all land in the
catch-all. Reading the engine, the mislabel has two independent causes:

- **G1 — the lookup is receiver-node-local.** `ProtectionScanner#scan` reads
  provenance at the dispatch's **immediate receiver node**
  (`protection_scanner.rb:49`, `scope.dynamic_origins[node.receiver]`), but
  `MethodDispatcher` records the specific causes at the **call node that produced
  the Dynamic value** (`method_dispatcher.rb:113/141/166/178`). For `tag.id`, the
  receiver node is the local read `tag`, not the `Tag.find_normalized(...)` call
  that made it dynamic. Local- and ivar-read receivers therefore find no record
  (→ null) or fall through `ExpressionTyper#fallback_for`'s generic
  `UNSUPPORTED_SYNTAX` (`expression_typer.rb:911`). The recorded cause only
  reaches the scanner when the receiver *is itself* the producing call — a
  chained `a.b.c` where `.c`'s receiver is the call `a.b`.

- **G2 — the specific causes are recorded under conditions that rarely hold on
  a hole.** `FRAMEWORK_DSL_BOUNDARY` is recorded only when a plugin's
  `dynamic_return` returns `Dynamic` (`method_dispatcher.rb:112`) — but plugins
  overwhelmingly return *concrete* types, and a concrete receiver is *protected*,
  not a hole. `EXTERNAL_GEM_WITHOUT_RBS` depends on ADR-10 dependency-source
  inference / `pre_eval:`, both opt-in and off in a stock Rails config. And the
  two tiers that resolve a *user* method to `Dynamic` because the engine cannot
  infer its return — `try_discovered_method` (`method_dispatcher.rb:246`) and
  `try_user_class_fallback` (`:210`) — record **no** cause at all.

Neither gap is a labeling nicety: without them, ADR-75's tractability signal —
the whole reason the labels exist — does not survive contact with a real app.

## Decision

Wire provenance so that a Dynamic receiver at a dispatch site resolves to the
**most specific cause of the value it holds**, and record a cause at every tier
that manufactures a `Dynamic`. Provenance remains a side-channel: it never
participates in subtyping, consistency, normalization, or erasure, fires no
diagnostic, and never feeds severity (ADR-75 WD3, unchanged). The criterion for
every change here is **honesty of attribution** — a cause is recorded/propagated
only where it is a sound description of why the value is dynamic; when in doubt
the value keeps the generic cause rather than a guessed specific one (a wrong
"enable a plugin" hint wastes the user's time, the failure mode ADR-75 exists to
avoid).

Because provenance is additive metadata, correctness cannot be gauged by the
diagnostic corpus (it is byte-identical by construction). The gate is instead
the **re-bucketing measurement** on Mastodon/Redmine: each slice must move a
meaningful share out of the catch-all *and* each moved bucket must be
hand-adjudicated as correctly attributed (spot-check the receivers). A slice
that re-labels without improving attribution accuracy is not landed.

### Working decisions

- **WD1 — propagate a binding's origin to a bare receiver read. (Implemented
  2026-07-06.)** Resolve the receiver's cause transitively rather than reading
  only its own node: a local-variable-read receiver follows to the origin of the
  value last bound to it, an instance-variable-read receiver to its field's
  assignment origin; a call-node receiver keeps today's direct lookup. Mechanism:
  flow-threaded `Scope#local_origins` / `#ivar_origins` name→cause side-tables,
  set at assignment (`Scope#with_local_origin`, called from
  `StatementEvaluator#eval_local_write` / `#eval_ivar_write` when the rhs is a
  `Dynamic` with a recorded origin) and consulted by `ProtectionScanner`
  (`#propagated_origin`) when the receiver's own node carries no cause. The tables
  obey the ADR-53 litmus in reverse — they *do* vary with flow (a rebind drops the
  name, `with_local` clears it copy-on-write) so they live on `Scope`, but they
  are excluded from `==` / `hash` (advisory, never varies a flow decision) and
  reset per method body (a fresh entry scope drops them, so name keys never
  collide across bodies). Zero-alloc in the common case (empty tables share the
  frozen `EMPTY_ORIGINS`; `drop_origin` allocates only when the rebound name
  actually carries an origin), so the ADR-44 per-dispatch budget holds — measured
  perf-neutral (see the WD1 outcome above). The payoff is modest (the bare-read
  receivers are the small null bucket); the bigger lever is WD6.

- **WD6 — chain-origin inheritance (the evidenced next lever; not implemented).**
  The WD1 measurement showed the dominant catch-all receivers are intermediate
  call/chain expressions, not bare variable reads: `a.b.c` and `x.foo[…]` lose
  provenance because `.b` / `.foo` dispatched on a `Dynamic` receiver records the
  generic `unsupported_syntax` on its result. WD6 makes a dispatch on a `Dynamic`
  receiver *inherit* the receiver's origin onto its result, so a specific cause
  survives a chain. It is where most of the 84% lives, but it touches the hottest
  path (every call dispatch) and carries FP/perf risk on the shared origin table,
  so it is deferred to its own measured, adjudicated, `bench-perf`-gated slice
  rather than rushed here — the same discipline WD2+WD3 followed before WD1.

- **WD2 — record a cause at the two unlabeled user-method tiers. (Implemented
  2026-07-06.)** `try_discovered_method` and `try_user_class_fallback` now record
  `INFERRED_RETURN_UNTYPED` on their call node when they return `Dynamic`
  (`method_dispatcher.rb`). These are "the engine resolved the call to a known
  user/ancestor method but cannot infer its return" — distinct from an unmodeled
  syntax fallback. A one-line `record_dynamic_origin` per tier, side-channel-only,
  giving the chained-receiver holes an honest cause even before WD1 lands.

- **WD3 — a new cause `inferred_return_untyped` with `engine_gap` tractability,
  routed to parameter/ivar inference. (Implemented 2026-07-06.)** The WD2 tiers
  are not `unsupported_syntax` (the call resolved) nor `explicit_untyped` (no
  authored RBS said `untyped`); they are an *inference* gap whose real lever is
  [ADR-67](67-parameter-type-inference.md) (call-site param inference sharpens
  the body's return) / [ADR-58](58-ivar-field-typing.md). The distinct cause lets
  `coverage --protection` say "the engine can't infer this return yet" instead of
  "unsupported syntax", more honest and pointing at the right roadmap item. Added
  to `DynamicOrigin::CAUSES` / `TRACTABILITY`; the CLI reads tractability centrally
  so no renderer change was needed. Extends ADR-75's cause set (not yet frozen;
  the ADR-50 v1.0 vocabulary freeze is future), the extension is the point.
  (Applying it to the `ExpressionTyper` user-method-inference fallthrough as well
  is a follow-up; the two dispatcher tiers are where the measured 211 sites came
  from.)

- **WD4 — record `framework_dsl_boundary` for framework *reader* objects even
  when concrete-typed is out of scope; the gap is elsewhere.** G2's observation
  that plugins return concrete types is *correct behaviour* — those sites are
  protected. The framework-DSL holes that remain are values that cross a DSL
  boundary and stay dynamic (a `method_missing` accessor, a macro-generated
  attribute). Recording `framework_dsl_boundary` there is a plugin-side concern
  (the plugin knows it emitted a dynamic boundary) and is deferred to per-plugin
  follow-up, not wired generically here — guessing "framework boundary" for any
  unresolved receiver would violate the honesty criterion.

- **WD5 — the measurement gate. (Resolved 2026-07-06.)** WD2+WD3 landed first
  (cheap, no scope change) and were measured on Mastodon app+lib: they re-bucket
  **211 sites (~1%)** into `inferred_return_untyped`, all correctly attributed
  chained-receiver holes, leaving the 84% catch-all essentially intact. The
  residual is dominated by local/ivar-read receivers exactly as the §2 sample
  predicted, so the gate resolved WD1 in. **WD1 then landed and was itself
  measured** (the gate applies to every slice): it is perf-neutral but moves only
  ~322 sites (the null bucket), because the §2 sample over-weighted bare-variable
  receivers — adjudicating the residual shows the dominant catch-all is
  intermediate call/chain expressions, redirecting the next lever to WD6. Each
  slice measuring the *next* one is the intended loop; WD1's measurement is what
  turned "primary lever" into "foundation for WD6."

## Rejected alternatives

- **Attach provenance to the `Type::Dynamic` carrier so it rides with the value
  automatically.** Rejected by ADR-75 WD1 and unchanged here: `Dynamic` uses
  `value_fields :static_facet` value-equality so two `Dynamic[String]` dedup in
  unions and the cache; an origin field forks the lattice by origin. WD1's
  side-association is the sanctioned propagation path.
- **Re-derive provenance at report time from the receiver expression's shape.**
  Rejected — the wrong layer (ADR-75 WD3): the engine already knows the cause at
  introduction; reconstructing it from the AST at report time re-implements
  dispatch and drifts.
- **Collapse `unsupported_syntax` and null into one "unknown" bucket and stop
  pretending.** Rejected — that concedes the tractability signal instead of
  fixing it; the receivers *do* have knowable causes (WD1/WD2/WD3), the engine
  just isn't recording/propagating them.
- **Make provenance fire a diagnostic ("this receiver is untyped").** Rejected —
  violates FP-discipline and ADR-75's no-severity contract; provenance routes
  attention on the coverage surface, it does not gate.

## Consequences

- `coverage --protection` tractability is more honest on real Rails apps: WD2+WD3
  split `inferred_return_untyped` (→ ADR-58/67 roadmap) out of the catch-all, and
  WD1 moves bare-variable receivers out of the no-cause bucket. The bulk of the
  84% `unsupported_syntax` residue awaits WD6 (chain-origin inheritance) — the
  measured, evidenced next lever.
- No change to types, diagnostics, severity, or the diagnostic corpus (additive
  side-channel). The gate is re-bucketing measurement + attribution
  adjudication, not a zero-delta corpus run.
- WD3 extends the ADR-75 cause set by one symbol; `DynamicOrigin::CAUSES` and
  `TRACTABILITY` grow accordingly. The new cause id is public `--format json`
  vocabulary and freezes at v1.0 under [ADR-50](50-release-engineering-and-stability-strategy.md)
  WD1.
- WD1 adds two flow-varying `Scope` side-tables (`local_origins` / `ivar_origins`);
  measured perf-neutral (+0.1% `lib` allocations vs master). Note the committed
  `bench/baseline.json` is stale (19.77M allocations / 16.6s wall vs today's
  ~27.5M / ~7.2s — master fails the gate too), so `make bench-perf` needs a
  re-baselined commit to be meaningful again; that recalibration is out of scope
  here but flagged as a follow-up.
