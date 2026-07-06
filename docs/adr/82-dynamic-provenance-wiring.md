# ADR-82 — `Dynamic[T]` provenance wiring: breaking the catch-all on real apps

Status: **WD2+WD3 implemented 2026-07-06; WD1 required (measurement-confirmed),
not yet implemented.** [ADR-75](75-dynamic-provenance.md) added the `Dynamic[T]`
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

- **WD1 — propagate provenance across the receiver-node lookup (the primary
  lever).** Resolve the receiver's cause transitively rather than reading only
  its own node: for a local-variable-read receiver, follow to the origin of the
  node that last bound it; for an instance-variable-read receiver, follow to the
  field's assignment origin; a call-node receiver keeps today's direct lookup
  (already correct for chains). Mechanism: a `binding → origin-node` association
  maintained alongside the local/ivar bindings, consulted by
  `ProtectionScanner` (and any future consumer) when the receiver's own node
  carries no cause. **Design constraints (why this is the hard, deferred slice):**
  the association must obey the ADR-53 discovery-index litmus in reverse — it
  *does* vary with flow (a rebind changes the origin), so it lives on `Scope`
  proper, must be copied/joined correctly across branches, and must not
  regress the per-dispatch allocation budget (ADR-44). Landing this without a
  perf regression or a stale-origin bug is the bulk of the work and gates the
  ADR's acceptance.

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
  predicted, so the gate resolves to: **WD1 (lookup propagation) is required, not
  demand-gated.** WD2+WD3 served their purpose as a cheap confirmation of the G1
  diagnosis; WD1's design (the flow-varying `Scope` `binding → origin-node`
  association) is now the next work item, gated on `make bench-perf` and the
  discovery/self-check gates.

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

- `coverage --protection` tractability becomes actionable on real Rails apps:
  the catch-all breaks into `inferred_return_untyped` (→ ADR-58/67 roadmap),
  `explicit_untyped`/`external_gem_without_rbs` (→ add RBS), leaving a smaller,
  honest `unsupported_syntax` residue.
- No change to types, diagnostics, severity, or the diagnostic corpus (additive
  side-channel). The gate is re-bucketing measurement + attribution
  adjudication, not a zero-delta corpus run.
- WD3 extends the ADR-75 cause set by one symbol; `DynamicOrigin::CAUSES` and
  `TRACTABILITY` grow accordingly. The new cause id is public `--format json`
  vocabulary and freezes at v1.0 under [ADR-50](50-release-engineering-and-stability-strategy.md)
  WD1.
- WD1, if required, adds a flow-varying `Scope` side-association; its perf and
  join-correctness are the acceptance risk and must clear `make bench-perf` and
  the discovery/self-check gates.
