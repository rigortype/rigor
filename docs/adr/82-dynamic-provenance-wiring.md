# ADR-82 — `Dynamic[T]` provenance wiring: breaking the catch-all on real apps

Status: **WD1+WD2+WD3+WD6+WD7+WD8 implemented 2026-07-06; WD9 (external-gem constant ownership) implemented 2026-07-11.** [ADR-75](75-dynamic-provenance.md) added the `Dynamic[T]`
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
a `Dynamic` receiver recorded *nothing* on its result and lost the upstream cause.
So the evidenced next lever, **WD6 — chain-origin inheritance** (a dispatch on a
`Dynamic` receiver inheriting the receiver's origin onto its result, so provenance
survives a method chain), **then landed too** — perf-neutral, and it more than
halves the residual null bucket (2,550→1,356). But it buys provenance
*completeness*, not tractability *actionability*: most propagated causes are
`unsupported_syntax` because the chain roots record it, so the next lever after
WD6 is enriching those roots (see the WD6 working decision). WD1 is retained: it
is correct, precision-additive, perf-neutral, and the binding-propagation half of
the lookup WD6 shares.

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

- **WD6 — chain-origin inheritance. (Implemented 2026-07-06.)** The WD1
  measurement showed the dominant catch-all receivers are intermediate call/chain
  expressions, not bare variable reads: `a.b.c` and `x.foo[…]` lose provenance
  because `.b` / `.foo` dispatched on a `Dynamic` receiver returned `dynamic_top`
  and recorded *nothing* on its call node (the existing "the result inherits the
  dynamic origin" comment at `call_type_for` was aspirational — never wired). WD6
  wires it: a dispatch on a `Dynamic` receiver records the receiver's effective
  origin (`Inference::OriginLookup.origin_for` — the same `dynamic_origins` +
  WD1-binding lookup `ProtectionScanner` uses, now shared) onto the call it
  produces, so a specific cause survives a chain. Side-channel only (the result
  type is untouched); measured perf-neutral (+0.03% `lib` allocations vs master).
  **Outcome:** it substantially reduces the *causeless* (null) bucket — Mastodon
  app+lib null 2,550→**1,356** (−1,194, roughly 4× WD1's move; combined with WD1
  the baseline 2,921 null is more than halved). But most propagated causes are
  `unsupported_syntax`, because the chain *roots* record it: an implicit-self
  memoized reader, a `params[:x]` index, a metaprogrammed accessor. So WD6 buys
  **provenance completeness** (far fewer "no idea" holes) more than **tractability
  actionability** (`unsupported_syntax` and null both route to `engine_gap`). The
  actionability lever it exposes next is **enriching the roots** — make the
  implicit-self resolution path record `inferred_return_untyped` like WD2's
  explicit-receiver tiers, and give framework index reads (`params[:x]`,
  `session[:x]`) a framework cause — which WD6 then propagates through the chains
  for free. WD7 lands the first and highest-value slice of that root-enrichment.

- **WD7 — root-cause enrichment for untyped parameters, plus an accurate per-site
  cause metric. (Implemented 2026-07-06.)** Two coupled changes, prompted by
  discovering that the WD1/WD6 measurements were read off a *lossy* aggregation.

  - **The accurate metric (and a correction).** `coverage --protection` grouped
    holes by method and reported each group's *dominant* cause, and
    `tractability_summary` weighted that dominant cause by the group's full count.
    That massively undercounts a mixed group's minority causes — including the
    causeless (null) sites, which vanish entirely from a group that has any
    origin'd site. The new per-site `cause_site_counts` (exact tally, `"none"`
    included; `tractability_summary` now derives from it) reveals the true state,
    and it **corrects the WD1/WD6 numbers in this ADR**: those slices' "null
    2,921→1,356" was the dominant-cause artifact — the *accurate* causeless count
    on Mastodon app+lib after WD1+WD2+WD3+WD6 is **10,390 of 21,119 (49%)**, with
    10,126 `unsupported_syntax` and only ~600 in the actionable buckets. WD1/WD6
    still did real work (chains and bindings that *were* labeled now stay
    labeled), but their magnitude was overstated by the lossy metric; provenance
    completeness after them is ~51%, not the ~94% the old metric implied.

  - **The enrichment.** The largest actionable slice of that 49% causeless bucket
    is undeclared method parameters: `def f(x); x.foo` binds `x` to `untyped`, and
    a bare param receiver had no cause. `build_method_entry_scope` now seeds an
    untyped param's `local_origins` to `inferred_return_untyped` (an untyped param
    is the archetypal [ADR-67](67-parameter-type-inference.md) gap — no call-site
    type flows in), so WD1's lookup labels `x.foo` and WD6 carries it through
    `x.foo.bar`. Seed-time only (not a hot read path), precision-additive,
    perf-neutral (+0.15% `lib` allocations). **Outcome:** Mastodon causeless
    10,390→**7,305** (−3,085) and `inferred_return_untyped` 351→**3,460** (+3,109),
    ratio unchanged — a genuine *actionability* gain (3,100 holes now route to
    ADR-67) on top of WD6's completeness. The remaining 7,305 causeless is
    dominated by unbound instance-variable reads (the [ADR-58](58-ivar-field-typing.md)
    ivar-field gap) and `dynamic_top`-returning node kinds (yield / super / block);
    the ivar slice is WD8.

- **WD8 — root-cause enrichment for unbound instance-variable reads. (Implemented
  2026-07-06.)** The second root-enrichment slice, and the largest remaining one
  after WD7's parameters. An `@x` read whose field the engine does not track
  (`scope.ivar(name)` is nil — the ivar is assigned in another method, or never
  seen) returned `dynamic_top` with no cause, so `@x.foo` on it was causeless.
  `ExpressionTyper#type_of_instance_variable_read` now records
  `inferred_return_untyped` on the unbound read (an untyped field is the
  archetypal [ADR-58](58-ivar-field-typing.md) gap), and WD6 carries it through
  `@x.foo.bar`. Unlike WD7's parameters this cannot be seeded at method entry (the
  read site is where "unbound" is known), so it records at read time — but only on
  the already-`dynamic_top` branch, precision-additive, and measured perf-neutral
  (+0.03% `lib` allocations, same shape as WD6). **Outcome:** Mastodon causeless
  7,305→**5,405** (−1,900) and `inferred_return_untyped` 3,460→**5,399** (+1,939),
  ratio unchanged. Cumulative across WD7+WD8 the causeless bucket fell from a true
  10,390 (49%) to 5,405 (26%) and the actionable `inferred_return_untyped` bucket
  grew 351→5,399 (15×). The residual causeless is now `dynamic_top`-returning node
  kinds (yield / super / block / embedded var) and class-/global-variable reads —
  mostly genuinely unmodeled, so the arc's actionability lever is largely spent;
  remaining `unsupported_syntax` (10,063, still 48%) is chains rooted at unresolved
  calls, the honest engine-gap floor.

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

- **WD9 — label an unresolved constant owned by an RBS-less locked gem.
  (Implemented 2026-07-11.)** Closes the `external_gem_without_rbs = 0` half of
  G2 (WD4 defers the `framework_dsl_boundary` half to per-plugin follow-ups).
  The context's framing — record the cause "when a dispatch's receiver class is
  owned by an RBS-less gem" — is mechanically impossible: a no-RBS gem's
  receiver never carries the class name, because the constant read itself
  (`Faraday`) fails resolution and widens to `Dynamic[top]` with the generic
  `unsupported_syntax` cause; by dispatch time the name is gone (the two
  dispatcher tiers that do record this cause require ADR-10 / `pre_eval:`
  opt-ins — exactly why the bucket measured zero). The honest recording site is
  the **constant-resolution miss** (`ExpressionTyper#unresolved_constant_fallback`),
  and WD6 chain inheritance carries the cause through `Faraday.new.get(...)`
  for free. Ownership is established by *reading, never guessing*: each
  `:missing`-classified locked gem's conventional entry file (`lib/<name>.rb`,
  dash → directory variant) is parsed with Prism and its top-level declarations
  indexed under their root constant name
  (`Environment::MissingGemConstantIndex`, built lazily on the first unresolved
  constant; no gem code runs — the ADR-72 posture). A camelize-the-gem-name
  heuristic is deliberately rejected (breaks on `activesupport` →
  `ActiveSupport`; the guessing the honesty criterion forbids). Everything
  **fails open** — uninstalled gem, absent/unparseable entry file, deeper-file
  declaration, project typo all keep the generic cause; the failure mode is a
  missing label, never a wrong one. **Gem-directory resolution is load-bearing**:
  rigor runs under its OWN bundle (`BUNDLE_GEMFILE=<rigor>/Gemfile`), so
  `Gem::Specification` sees rigor's gems, not the target's — the primary
  resolver is the target's bundle install tree
  (`<bundle>/ruby/*/gems/<name>-<version>/`, the `BundleSigDiscovery` layout),
  with `Gem::Specification` only a fallback for a no-bundle project (sound
  because a gem's top-level namespace constant is version-stable). Coverage
  tracks the target's install layout: a `vendor/bundle` project (auto-detected)
  gets the full external-gem population; a default-gem-home project (rbenv/mise,
  no `--path`) needs `bundler.bundle_path:` — the existing ADR-27 opt-in, not new
  engine work: auto-detecting the target's gem home would run its toolchain
  (ADR-27 forbids) or guess every version manager's layout. Confirmed
  ([2026-07-11 install-boundary note](../notes/20260711-external-gem-install-boundary.md)):
  installing Redmine's full bundle to `vendor/bundle` and re-running on unchanged
  engine code yields **279** external-gem sites (`Rails`→railties, loofah, i18n),
  all adjudicated correct — the survey apps' floor was that their gems were never
  installed, not an engine gap. Measured (identical denominators): Mastodon
  `app/models` 47 and
  GitLab `lib` 124 sites `unsupported_syntax` → `external_gem_without_rbs` (the
  shared-gem floor — `i18n`/`rack`/`activesupport`; sampled sites root at
  `I18n`, whose RBS exists in `gem_rbs_collection`, so `add_rbs` is genuinely
  actionable), other buckets byte-stable, diagnostics byte-identical (Redmine),
  `make bench-perf` green.

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

- `coverage --protection` provenance is measured accurately (WD7's per-site
  `cause_site_counts`) and materially more complete *and* actionable on real Rails
  apps: WD2+WD3 split `inferred_return_untyped` out of the catch-all, WD1 + WD6
  propagate a cause to bare-variable and chained receivers, and WD7/WD8 route
  untyped parameters (ADR-67) and unbound ivar fields (ADR-58) to inference. On
  Mastodon app+lib the causeless bucket fell from a true 10,390 (49%) to 5,405
  (26%) and the actionable `inferred_return_untyped` bucket grew 351→5,399 (15×),
  ratio unchanged throughout. The residual causeless is `dynamic_top`-returning
  node kinds (yield / super / block) and class-/global-variable reads — mostly
  genuinely unmodeled, so the actionability lever is largely spent; the remaining
  `unsupported_syntax` (48%) is chains rooted at unresolved calls, the honest
  engine-gap floor.
- Provenance is measured **per-site**, never per-method-group-dominant. The
  `add_a_type_here` list still shows a per-group dominant cause for the ranked "add
  a type here" view, but `cause_site_counts` and `tractability_summary` are exact
  site tallies — the earlier group-dominant `tractability_summary` was a real
  undercount of mixed groups (WD7).
- No change to types, diagnostics, severity, or the diagnostic corpus (additive
  side-channel). The gate is re-bucketing measurement + attribution
  adjudication, not a zero-delta corpus run.
- WD3 extends the ADR-75 cause set by one symbol; `DynamicOrigin::CAUSES` and
  `TRACTABILITY` grow accordingly. The new cause id, and WD7's `cause_site_counts`
  JSON field, are public `--format json` vocabulary and freeze at v1.0 under
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1.
- WD1 adds two flow-varying `Scope` side-tables, WD6 one `record_dynamic_origin`
  per Dynamic-receiver dispatch, WD7 one `with_local_origin` per untyped param at
  method entry, WD8 one `record_dynamic_origin` per unbound ivar read; all measured
  perf-neutral (WD1 +0.1%, WD6 +0.03%, WD7 +0.15%, WD8 +0.03% `lib` allocations vs
  master). Note the committed `bench/baseline.json` is stale (19.77M allocations /
  16.6s wall vs today's ~27.5M / ~7–9s — master fails the gate too), so
  `make bench-perf` needs a re-baselined commit to be meaningful again; that
  recalibration is out of scope here but flagged as a follow-up.
