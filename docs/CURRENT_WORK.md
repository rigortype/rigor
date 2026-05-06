# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.9 released 2026-05-05.** Closes every remaining pre-`0.1.0` substrate slice — the persistent cache wired through `rigor check` (six producers + `--cache-stats` / `--clear-cache` / `--no-cache`), paired-complement `~T` Refined narrowing, `literal-string` flow tracking through interpolation / `+` / `*` / `<<` / `concat`, the `Rigor::FlowContribution` bundle struct, the public-API drift specs for `Scope` / `Environment` / `Type::Combinator` / `Reflection`, and six new built-in catalogues (Random, Struct + Data, Encoding, Regexp + MatchData, Proc + Method + UnboundMethod, Exception). See `CHANGELOG.md`'s `[0.0.9]` section and the v0.0.9 row of [`docs/MILESTONES.md`](MILESTONES.md). Per the single-digit version-component policy, the next release is **`v0.1.0`** (not `0.0.10`).

**v0.1.0 slice 1 landed on `master` (unreleased).** Plugin registration / loading shipped per [ADR-2 § "Registration, Configuration, and Caching"](adr/2-extension-api.md): `Rigor::Plugin` namespace (`Plugin.register` + `Plugin::Base` + `Plugin::Manifest` + `Plugin::Services` + `Plugin::Registry` + `Plugin::LoadError`), `Plugin::Loader` (internal, deterministic order, isolated failures), `.rigor.yml` `plugins:` extension to bare-string-or-hash entries, `Analysis::Runner#plugin_registry`, drift snapshots for the new public namespaces, and the [`docs/internal-spec/plugin.md`](internal-spec/plugin.md) normative spec.

**v0.1.0 slice 2 landed on `master` (unreleased).** Plugin trust / I/O policy shipped per [ADR-2 § "Plugin Trust and I/O Policy"](adr/2-extension-api.md): `Rigor::Plugin::TrustPolicy` (frozen value object — `trusted_gems` / `allowed_read_roots` / `network_policy` + `#allow_read?` / `#network_allowed?` / `#gem_trusted?`), `Rigor::Plugin::IoBoundary` (per-plugin analyzer-side helper — `#read_file` validates against the policy and accumulates a `:digest` `Cache::Descriptor::FileEntry`; `#open_url` always raises while `network_policy` is `:disabled`; `#cache_descriptor` flushes the read history), `Rigor::Plugin::AccessDeniedError` (`:read_outside_scope` / `:network_disabled` reasons), `.rigor.yml` `plugins_io:` section, `Analysis::Runner` `TrustPolicy` build. Documentation: [`docs/internal-spec/plugin-trust.md`](internal-spec/plugin-trust.md).

**v0.1.0 slice 3 landed on `master` (unreleased).** Plugin contribution merger shipped per [ADR-2 § "Plugin Contribution Merging"](adr/2-extension-api.md): `Rigor::FlowContribution#to_element_list` (mechanical / deterministic / round-trippable flattening into `(target, edge, kind)`-keyed `Element` rows), `Rigor::FlowContribution::Element` (frozen Data value object), `Rigor::FlowContribution::Conflict` (`:return_type_collapse` / `:exceptional_disagreement` / `:lower_tier_contradiction` reasons), `Rigor::FlowContribution::MergeResult` (eight slots + `provenances` + `conflicts`), and `Rigor::FlowContribution::Merger` (stateless module — `merge` / `tier_for`) with the ADR-2 authority tiers (`:builtin > :rbs_extended / :generated > :plugin > unknown`), deterministic intra-tier ordering, and the composition rules (return-type intersection via mutual `accepts.no?` collapse detection; edge-local fact accumulation; mutation / invalidation / role union; single-valued exceptional with disagreement; lower-tier contradiction emits Conflict while preserving higher-tier value). Documentation: [`docs/internal-spec/flow-contribution-merger.md`](internal-spec/flow-contribution-merger.md).

**v0.1.0 slice 5 landed on `master` (unreleased).** Qualified-rule text rendering shipped earlier (`ef730b2`); the remaining emission protocol per [ADR-7 § "Slice 5"](adr/7-v0.1.0-slice-decisions.md): `Plugin::Base#diagnostics_for_file(path:, scope:, root:)` per-file hook (5-A), `Analysis::Runner` auto-stamps `source_family: "plugin.<manifest.id>"` on every emitted diagnostic (5-B), and `Conflict#to_diagnostic(path:, line:, column:)` converts merger conflicts to diagnostics with `source_family: :contribution_merge` (5-C). Plugin exceptions inside the hook isolate as `:plugin_loader` `runtime-error` diagnostics. End-to-end spec coverage in `spec/rigor/analysis/runner_spec.rb` exercises the full path. The `Rule<TNode>` node-scoped surface ADR-2 § "Custom rules" mentions stays deferred to v0.1.x.

**v0.1.0 slice 6 landed on `master` (unreleased).** Plugin-side cache producers per [ADR-7 § "Slice 6"](adr/7-v0.1.0-slice-decisions.md): class-level `Plugin::Base.producer` DSL (6-A); `Plugin::Base#cache_for(producer_id, params:)` callable that returns a `Cache::Store#fetch_or_compute` round-trip with the descriptor auto-assembled from the plugin's `PluginEntry` template (id, version, SHA-256(canonical config)) plus the `IoBoundary`'s accumulated `:digest` `FileEntry` rows plus the user-supplied params (6-B); producer ids auto-prefixed `plugin.<manifest.id>.` so plugin caches stay sandboxed from built-in `rbs.*` producers and from each other (6-C). The v0.0.9 carry-over per-method Reflection cache re-attempt is descoped to a separate v0.1.x ticket per ADR-7 § "Slice 6-D". Spec at [`docs/internal-spec/plugin-cache-producers.md`](internal-spec/plugin-cache-producers.md). **Working state: 1878 RSpec examples / 0 failures, RuboCop 197 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics.**

**v0.1.0 slice 4 (substrate / 4a) landed on `master` (unreleased).** Per [ADR-7 § "Slice 4-A"](adr/7-v0.1.0-slice-decisions.md): canonical `Rigor::FlowContribution::Fact` value object (`target_kind` / `target_name` / `type` / `negative` + `#target` merge-key accessor); `PredicateEffect#to_fact` and `AssertEffect#to_fact` translation methods; `RbsExtended.read_flow_contribution` now populates slot payloads with Facts instead of the parser-side typed Effect carriers, with the assert-effect condition routing the slot (closing a v0.0.9 imperfection). Public-API drift snapshot pins the Fact surface. Spec at [`docs/internal-spec/flow-contribution-merger.md`](internal-spec/flow-contribution-merger.md).

**v0.1.0 slice 4b (consumer migration) landed on `master` (unreleased).** Per [ADR-7 § "Slice 4-A/4-B"](adr/7-v0.1.0-slice-decisions.md), three of the eight consumer call sites now route flow-contribution narrowing through `RbsExtended.read_flow_contribution` + `Rigor::FlowContribution::Merger.merge`:

- **4b-1 (`4806047`)** — `Inference::Narrowing` predicate / assert-if pair collapses into a single `analyse_rbs_extended_contribution` consuming the merged `truthy_facts` / `falsey_facts` slots.
- **4b-2 (`fae6d31`)** — `Inference::StatementEvaluator#apply_rbs_extended_assertions` consumes the merged `post_return_facts` slot. `Narrowing.narrow_for_fact` lifted to the public surface so both paths share the canonical narrowing rule.
- **4b-3** — `MethodDispatcher::RbsDispatch.translate_return_type` reads the `return_type` slot via the merger so future plugin / `:rbs_extended` bundles compose at this call site through `MergeResult#conflicts` rather than racing.

The remaining five `Rigor::RbsExtended::*` consumer call sites are param-override readers (`method_parameter_binder.rb`, `analysis/check_rules.rb`, `method_dispatcher/overload_selector.rb`) which ADR-7 4-A explicitly excludes from `read_flow_contribution` — they refine the call's signature contract rather than its flow facts and stay on `param_type_override_map`. Slice 4b is therefore complete to the ADR's contract. **Working state: 1860 RSpec examples / 0 failures, RuboCop 196 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics.**

**v0.1.0 in progress on `master`.** Theme: **first plugin contract.** ADR-2 § "Extension API" fixes the design surface; v0.1.0's job is the implementation. The substrate landed in v0.0.3 → v0.0.9 — type vocabulary, inference engine, cache layer, FlowContribution bundle, public-API drift pins, RBS::Extended directive plumbing — leaves the contract surface as a finite assembly job:

- **Plugin registration / loading** — manifest discovery, dependency-injected analyzer services (Reflection, type factories, configuration readers), deterministic ordering. ADR-2 § "Registration, Configuration, and Caching".
- **Plugin contribution merger** — consumes `FlowContribution` bundles per ADR-2 § "Plugin Contribution Merging". Built-in narrowing rules and `RbsExtended` directives convert into bundles at the boundary so the merger is the single point of integration.
- **Plugin diagnostic provenance** — `plugin.<id>.<rule>` identifier publishing already shipped in v0.0.8 via `Diagnostic#source_family`; v0.1.0 wires plugin-emitted diagnostics through the same channel.
- **Plugin-side cache producers** — gated on the plugin API. Plugins register `producer_id`s and ride the v0.0.9 `Store#fetch_or_compute(serialize:, deserialize:)` surface, with `PluginEntry` rows in the descriptor schema for invalidation.
- **Plugin trust / I/O policy** — ADR-2 § "Plugin Trust and I/O Policy"; trusted-gem model, network disabled by default during analysis, file reads scoped to project + dependency metadata.

The public surface the plugin contract attaches to is pinned by `spec/rigor/public_api_drift_spec.rb` (Scope / Environment / Type::Combinator / Reflection) and documented in [`docs/internal-spec/public-api.md`](internal-spec/public-api.md). Pre-v0.1.0 design docs live at [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md).

### Historical: v0.0.8 → v0.0.9 cluster (released 2026-05-05)

**v0.0.8 released.** Cache infrastructure (`Descriptor`, `Store`), the first cached producer (`RbsConstantTable`), CLI observability flags (`--cache-stats` / `--clear-cache`), and `Diagnostic#source_family` provenance landed.

The v0.0.9 cluster, in commit order:

- 9378df2 — **A1**: `Analysis::Runner.cache_store` + `rigor check --no-cache`.
- ee021a2 — **A2**: `RbsLoader#constant_type` routes through `RbsConstantTable`; `Environment.for_project(cache_store:)` plumbs the Store down.
- 1407225 — **A3**: `Cache::Store#stats` + `--cache-stats` runtime breakdown.
- e764565 — **A4**: `Reflection.constant_type_for` confirmed cached end-to-end.
- c48f05f — **B**: `Rigor::FlowContribution` bundle struct (8 slots + `Provenance`).
- 8a94e7a — **C**: `Rigor::Cache::RbsKnownClassNames` + `RbsDescriptor` shared builder.
- 41aec51 — **D**: `RbsExtended.read_flow_contribution` rolls directives into a bundle.
- 3ae65e2 — **E**: paired-complement registry; `lowercase ↔ not_lowercase` pair.
- 908eb08 — **F**: `literal-string` carrier + interpolation flow tracking.
- 8951c1d — **C1**: `Store#fetch_or_compute(serialize:, deserialize:)` callable surface.
- 9b50e2b — **B (cache producer)**: `Rigor::Cache::RbsClassAncestorTable`.
- c601f40 — **A (cache producer)**: `Rigor::Cache::RbsClassTypeParamNames`.
- d662d4a — **E follow-up**: `uppercase ↔ not_uppercase` and `numeric ↔ not_numeric` pairs.
- 5600efc — **F follow-up**: `LiteralStringFolding` tier — literal-string through `String#+` / `String#*`.
- 8f7c32c — **C2**: `Rigor::Cache::RbsEnvironment` + `RBS::Location` Marshal patch — caches the full env, biggest cold-start win.

Working state at release: 1728 RSpec examples / 0 failures, RuboCop 167 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics.

### Notable carry-overs (deferred past v0.0.9, queued for v0.1.0+)

- ~~**More cached producers under `Rigor::Reflection`**~~ — landed (unreleased on `master`). `Rigor::Cache::RbsInstanceDefinitions` / `Rigor::Cache::RbsSingletonDefinitions` per-class producers wired through `RbsLoader#instance_definition` / `#singleton_definition`. Root cause of the v0.0.9 regression diagnosed: `cache/store.rb` and `cache/rbs_descriptor.rb` were missing `require_relative "descriptor"` and the resulting `NameError` was silently swallowed by `RbsLoader`'s fail-soft `rescue StandardError` blocks, leaving the cache effectively dead in CLI flow. Fix landed; cache hits now register correctly through `--cache-stats`.
- **Wire `FlowContribution` bundles through internal narrowing.** Built-in narrowing rules and `PredicateEffect`-style facts could round-trip through the bundle; the conversion sites stay analyzer-internal until v0.1.0's plugin contribution merger requires them.
- **Decimal / octal / hex `int-string` complement pairs.** Complement domains are too vague to warrant separate carriers in practice; the Difference fallback stays.

## Where the Work Resumes

### v0.1.1 — deepen the literal-string narrowing surface (planned)

Headline slice: **regex pattern → refinement-name recogniser** per `docs/MILESTONES.md` § "v0.1.1 — Planned". Extends the `Inference::Narrowing.analyse_match_write` path that v0.1.0 added (which narrows named-capture targets from `String | nil` to `String` in the truthy branch of `if /(?<x>...)/ =~ str`) so common anchored regex shapes — `/\A\d+\z/`, `/\A[a-z]+\z/`, `/\A\h+\z/`, etc. — additionally narrow each capture to the matching imported refinement carrier (`decimal-int-string`, `lowercase-string`, `hex-int-string`, …). Adjacent slices: `numeric-string`-aware folding through `Integer(s)` / `s.to_i`, and the `self`-narrowing in `predicate-if-*` carry-over.

### v0.1.0 — first plugin contract

ADR-2 § "Extension API" fixes the design surface; v0.1.0's job is the implementation. The substrate landed in v0.0.3 → v0.0.9 — type vocabulary, inference engine, cache layer, FlowContribution bundle, public-API drift pins, RBS::Extended directive plumbing — leaves the contract surface as a finite assembly job. Recommended slice order, narrow-to-broad:

1. **Plugin registration / loading** — ✅ landed (unreleased on `master`). `Rigor::Plugin` namespace (Base / Manifest / Services / Registry / Loader / LoadError) per ADR-2 § "Registration, Configuration, and Caching". `.rigor.yml` `plugins:` accepts bare-gem-name strings or `{ gem:, id:, config: }` hashes. `Analysis::Runner` builds a service container, calls `Plugin::Loader.load`, and exposes the `Plugin::Registry` via `Runner#plugin_registry`. Loader failures isolate as `:plugin_loader` diagnostics. Public namespaces drift-pinned at `spec/rigor/public_api_drift_spec.rb`. Spec at [`docs/internal-spec/plugin.md`](internal-spec/plugin.md). Plugins are inert until later slices wire protocol hooks.
2. **Plugin trust / I/O policy** — ✅ landed (unreleased on `master`). `Rigor::Plugin::TrustPolicy` + `Rigor::Plugin::IoBoundary` + `Rigor::Plugin::AccessDeniedError` + `.rigor.yml` `plugins_io:` section. ADR-2 § "Plugin Trust and I/O Policy" trade-off honoured (declarative policy over forced isolation). Public namespaces drift-pinned. Spec at [`docs/internal-spec/plugin-trust.md`](internal-spec/plugin-trust.md).
3. **Plugin contribution merger** — ✅ landed (unreleased on `master`). `Rigor::FlowContribution::Merger` + `Element` flattening + `MergeResult` + `Conflict`. Authority tiers and composition rules per ADR-2. Public namespaces drift-pinned. Spec at [`docs/internal-spec/flow-contribution-merger.md`](internal-spec/flow-contribution-merger.md).
4. **FlowContribution wiring through internal narrowing.** ✅ landed (unreleased on `master`). Slice 4a (substrate — `Fact` value object + carrier translations) and slice 4b (three consumer call sites — `analyse_rbs_extended_contribution`, post-return assertion, return-type override — through `Merger.merge`). The remaining `Rigor::RbsExtended::*` consumers are param-override readers explicitly excluded from `read_flow_contribution` per ADR-7 4-A. Working decisions pinned by [ADR-7 § "Slice 4"](adr/7-v0.1.0-slice-decisions.md).
5. **Plugin diagnostic emission protocol.** ✅ landed (unreleased on `master`). Qualified-rule text rendering (`ef730b2`) + `Plugin::Base#diagnostics_for_file` per-file hook + `Analysis::Runner` auto-stamps `source_family: "plugin.<id>"` + `Conflict#to_diagnostic` per [ADR-7 § "Slice 5"](adr/7-v0.1.0-slice-decisions.md). Plugin exceptions in the hook isolate as `:plugin_loader` `runtime-error` diagnostics. The `Rule<TNode>` node-scoped surface ADR-2 § "Custom rules" mentions stays deferred to v0.1.x.
6. **Plugin-side cache producers.** ✅ landed (unreleased on `master`). `Plugin::Base.producer` DSL + `Plugin::Base#cache_for` callable + auto-prefixed `plugin.<manifest.id>.` ids + auto-assembled `Cache::Descriptor` (PluginEntry + IoBoundary + params) per [ADR-7 § "Slice 6"](adr/7-v0.1.0-slice-decisions.md). The v0.0.9 per-method Reflection cache re-attempt is descoped to a separate v0.1.x ticket (6-D).

The public surface the plugin contract attaches to is pinned by `spec/rigor/public_api_drift_spec.rb` (Scope / Environment / Type::Combinator / Reflection) and documented in [`docs/internal-spec/public-api.md`](internal-spec/public-api.md). When a v0.1.0 slice extends or modifies any pinned namespace, update the drift spec in the same commit.

### Parallel-safe entry points

Slices that do not depend on (1) and can be tackled by a parallel implementer or interleaved between plugin slices:

- **Per-method Reflection caches** (post-mortem first, then re-attempt) — see Notable carry-overs above. Independent of plugin loading.
- **`literal-string` propagation through structured constructors** — `Array#join`, `String#format` over literal-bearing operands. Self-contained dispatcher tier work; no FlowContribution dependency.
- **C-body classifier wider transitive mutator scan** — `references/`-scoped tooling work. Guards against the `Array#to_a` regression that gated the v0.0.5 fix.
- **`Data.define` override-aware initializer dispatch** — block-body `def initialize(...)` as the canonical sig for `Const.new`. Today the auto-generated kw shape wins.

### Open Items deferred past v0.1.0

These remain explicitly out of scope until the plugin contract is stable; they should not block v0.1.0 release:

- **LSP / long-running-daemon cache mode.** Requires concurrent multi-process safety beyond the per-file `flock` model.
- **LRU eviction / size cap.** Cache stays unbounded; users run `--clear-cache` if needed.
- **Cross-machine cache sharing.**
- **ObjectSpace catalog import** — needs a singleton-module dispatch path the catalog tier does not yet provide.
- **URI / Kernel catalog imports** — fall outside the standard import skill's premise (pure-Ruby stdlib gem; methods scattered across 20+ C files with no single Init function). Both need hand-rolled or custom-scaffold approaches.
- **Pathname / URI delegation rules** — wider refactor (Pathname facade routing through File projections).
- **`self`-narrowing in `predicate-if-*`** — no `self`-narrowing surface in the engine yet. (Promoted to v0.1.1 candidate per `docs/MILESTONES.md` § "v0.1.1 — Planned".)
- **`rigor:v1:conforms-to` directive** — needs a real structural-conformance checker.
- **`Trinary` return-type contract on type-carrier predicate methods** — needs a new CheckRules rule family (`return-type-mismatch`); deferred until the inference surface is sturdy enough to avoid false-positive churn.
- **New CheckRules rule families** beyond the v0.0.3 `always-raises` line (type-incompatible writes, return-type mismatch, unreachable branches).

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 narrows the gap, but per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` still absorb false positives the narrow regex misses. Long-term: the classifier should track the helpers transitively without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix).

3. **`numeric.yml` `unknown` entries.** After v0.0.9, only `Integer#ceildiv` remains `unknown` (prelude body delegates to user-overridable `#div`, classified as `composed`). `Numeric#clone` was resolved by adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` (commit a7d9265). The remaining entry is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

## Reading Order for a Returning Implementer

1. `git log --oneline master ^v0.0.8` — every v0.0.9 slice in commit order (the cache wiring + FlowContribution + paired-complement + literal-string + six built-in catalog imports + public-API surface declaration).
2. `CHANGELOG.md` `[0.0.9]` section — user-visible summary, structured by Cache layer / Type vocabulary / Pre-v0.1.0 substrate / Internal.
3. [`docs/MILESTONES.md`](MILESTONES.md) — v0.0.9 row for shipped scope, v0.1.0 row for the plugin-contract commitment envelope.
4. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the design surface v0.1.0 implements. Read end-to-end; the registration / contribution-merging / trust sections are normative for the v0.1.0 slice plan above.
5. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
6. [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md) — what the v0.0.x substrate already provides for the plugin contract and what each v0.1.0 slice still has to build.
7. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.
8. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule plugin-authored signatures will follow.

After those, the implementation surface for v0.1.0 is locatable from grep over `lib/rigor/flow_contribution*.rb`, `lib/rigor/cache/`, `lib/rigor/reflection*.rb`, `lib/rigor/rbs_extended/`, and `lib/rigor/analysis/`.
