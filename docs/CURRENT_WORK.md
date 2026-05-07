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

**v0.1.0 ready for release on `master` (unreleased).** All six v0.1.0 slices have landed (status entries above) plus the v0.1.0-polish work that builds on them:

- **Six worked plugin examples** under [`examples/`](../examples/README.md) — `rigor-deprecations` (smallest config-driven plugin), `rigor-lisp-eval` (literal AST typing), `rigor-statesman` (two-pass DSL analysis), `rigor-pattern` (engine collaboration via `Scope#type_of` + literal-string carrier), `rigor-units` (local-variable flow tracking), `rigor-routes` (slice 2 + slice 6 — `IoBoundary` + cache producer). Each gem ships `lib/`, runnable `demo/`, README, and an end-to-end integration spec under [`spec/integration/examples/`](../spec/integration/examples/). Total 67 integration examples.
- **Nine-chapter end-user handbook** under [`docs/handbook/`](handbook/README.md) — getting started, everyday types, narrowing, tuples / hash shapes, methods / blocks, classes, RBS / `RBS::Extended`, understanding errors, plugins. Modeled on the TypeScript handbook v2 in volume of information; adapted to Rigor's idioms.
- **Two precision improvements landed during the polish.** `Inference::Narrowing.analyse_match_write` narrows named-capture targets from `String | nil` to `String` in the truthy branch of `if /(?<x>...)/ =~ str` (commit `7571616`); `;`-prefixed block-locals (`do |i; x|`) now bind to `Constant[nil]` at block entry to shadow outer locals per Ruby semantics (commit `bdfa85e`).
- **`docs/MILESTONES.md` § "v0.1.1 — Planned"** scoped — headline slice is the regex pattern → refinement-name recogniser that extends `analyse_match_write`. Adjacent slices: `numeric-string`-aware folding through `Integer(s)` / `s.to_i`; `self`-narrowing in `predicate-if-*` (carry-over from v0.1.0 deferred).

The public surface the plugin contract attaches to is pinned by `spec/rigor/public_api_drift_spec.rb` (Scope / Environment / Type::Combinator / Reflection / Plugin::*) and documented in [`docs/internal-spec/public-api.md`](internal-spec/public-api.md). Pre-v0.1.0 design docs at [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) and [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md). Per the no-autonomous-version-bump rule in [`AGENTS.md`](../AGENTS.md), `Rigor::VERSION` / `CHANGELOG.md` released-version sections / `Gemfile.lock` await an explicit user request to cut `0.1.0`.

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

### Rails ecosystem plugins (parallel running track)

The Rails plugin family — `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`, plus `rigor-activerecord` extensions — is being authored in parallel with v0.1.x core work. The full plan is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Tier 1 plugins (current API, no analyser-side change required) are unblocked and authoring can start immediately. Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) blocks on [ADR-9 — Cross-plugin API](adr/9-cross-plugin-api.md), which proposes `Plugin::FactStore` + `Plugin::Base#prepare(services)` + `manifest(consumes:)`. ADR-9 is queued for v0.1.x; the slicing (six independently shippable slices) is in the ADR.

### v0.1.1 — multi-track release (next)

Per [`docs/MILESTONES.md`](MILESTONES.md) § "v0.1.1 — Planned", v0.1.1 ships four tracks in parallel:

**Track 1 — Literal-string / refinement narrowing depth.** Headline slice: regex pattern → refinement-name recogniser extending `Inference::Narrowing.analyse_match_write`. Plus `numeric-string` propagation through `Integer(s)` / `s.to_i`; `self`-narrowing in `predicate-if-*`; additional `String#start_with?` / `#end_with?` / `#include?` predicate narrowing; `literal-string` propagation through more methods (`Integer#to_s(base)`, `Numeric#to_s`, `String#center` / `#ljust` / `#rjust`, etc.).

**Track 2 — Cross-plugin API + plugin return-type contributions.** Implementation of [ADR-9](adr/9-cross-plugin-api.md) slices 1 → 5: `Plugin::FactStore` value object, `Plugin::Services#fact_store`, `Plugin::Base#prepare(services)`, `manifest(produces:/consumes:)`, topological sort + missing-producer detection in `Plugin::Loader`. Unblocks Tier 2 Rails plugins. Plus plugin return-type contributions slice 1 (`Plugin::Base#flow_contribution_for(call_node:, scope:)` hook + dispatcher integration ahead of `RbsDispatch`) — moves the seven existing examples from "info diagnostic only" to "narrowed return type" incrementally.

**Track 3 — Plugin authoring DX.** Plugin spec helper module ✅ **landed (`ce64bb6`)**; future items: demo cache directory handling, examples RuboCop relaxation.

**Track 4 — Maintenance.** Three `lib/` sig drifts (`Trinary#negate`, `IntegerRange#lower`, `IntegerRange#upper`); `node_locator_spec.rb:82` `String#index + 1` cleanup; `numeric.yml` `Integer#ceildiv` `unknown` entry.

### v0.1.0 — first plugin contract (all slices landed; release pending)

ADR-2 § "Extension API" fixed the design surface. The substrate landed in v0.0.3 → v0.0.9 (type vocabulary, inference engine, cache layer, FlowContribution bundle, public-API drift pins, `RBS::Extended` directive plumbing) reduced v0.1.0 to a finite assembly job. All six slices closed:

1. **Plugin registration / loading** — ✅ `Rigor::Plugin` namespace (Base / Manifest / Services / Registry / Loader / LoadError). Spec [`docs/internal-spec/plugin.md`](internal-spec/plugin.md).
2. **Plugin trust / I/O policy** — ✅ `Plugin::TrustPolicy` + `Plugin::IoBoundary` + `Plugin::AccessDeniedError` + `.rigor.yml` `plugins_io:` section. Spec [`docs/internal-spec/plugin-trust.md`](internal-spec/plugin-trust.md).
3. **Plugin contribution merger** — ✅ `FlowContribution::Merger` + `Element` flattening + `MergeResult` + `Conflict`. Spec [`docs/internal-spec/flow-contribution-merger.md`](internal-spec/flow-contribution-merger.md).
4. **FlowContribution wiring through internal narrowing** — ✅ Slice 4a (substrate — `Fact` value object + carrier translations) + slice 4b (three consumer call sites — `analyse_rbs_extended_contribution`, post-return assertion, return-type override — routed through `Merger.merge`). Working decisions pinned by [ADR-7 § "Slice 4"](adr/7-v0.1.0-slice-decisions.md).
5. **Plugin diagnostic emission protocol** — ✅ `Plugin::Base#diagnostics_for_file` per-file hook + `Analysis::Runner` auto-stamps `source_family: "plugin.<id>"` + `Conflict#to_diagnostic`. Plugin exceptions isolate as `:plugin_loader` diagnostics.
6. **Plugin-side cache producers** — ✅ `Plugin::Base.producer` DSL + `Plugin::Base#cache_for` callable + auto-prefixed `plugin.<manifest.id>.` ids + auto-assembled `Cache::Descriptor`. Spec [`docs/internal-spec/plugin-cache-producers.md`](internal-spec/plugin-cache-producers.md).

Plus the v0.1.0-polish work documented in the Status section above (six worked plugin examples, the nine-chapter end-user handbook, the named-capture narrowing fix, the `;`-prefixed block-local nil shadow fix). Per the no-autonomous-version-bump rule in [`AGENTS.md`](../AGENTS.md), the version bump (`Rigor::VERSION` → `0.1.0`, `CHANGELOG.md` `[Unreleased]` → `[0.1.0] - YYYY-MM-DD`, `Gemfile.lock` regenerated) waits for explicit user authorisation.

### Parallel-safe entry points

Items that can be tackled in parallel with v0.1.1 work:

- **Per-method Reflection caches** (post-mortem first, then re-attempt) — see Notable carry-overs above. Independent of v0.1.x narrowing work.
- **`literal-string` propagation through structured constructors** — `Array#join`, `String#format` over literal-bearing operands. Self-contained dispatcher tier work; no FlowContribution dependency.
- **C-body classifier wider transitive mutator scan** — `references/`-scoped tooling work. Guards against the `Array#to_a` regression that gated the v0.0.5 fix.
- **`Data.define` override-aware initializer dispatch** — block-body `def initialize(...)` as the canonical sig for `Const.new`. Today the auto-generated kw shape wins.

### Open Items deferred past v0.1.x

Out of scope until the plugin contract has live downstream consumers and a reason to extend the surface:

- **LSP / long-running-daemon cache mode.** Requires concurrent multi-process safety beyond the per-file `flock` model.
- **LRU eviction / size cap.** Cache stays unbounded; users run `--clear-cache` if needed.
- **Cross-machine cache sharing.**
- **ObjectSpace catalog import** — needs a singleton-module dispatch path the catalog tier does not yet provide.
- **URI / Kernel catalog imports** — fall outside the standard import skill's premise (pure-Ruby stdlib gem; methods scattered across 20+ C files with no single Init function). Both need hand-rolled or custom-scaffold approaches.
- **Pathname / URI delegation rules** — wider refactor (Pathname facade routing through File projections).
- **`rigor:v1:conforms-to` directive** — needs a real structural-conformance checker.
- **`Trinary` return-type contract on type-carrier predicate methods** — needs a new CheckRules rule family (`return-type-mismatch`); deferred until the inference surface is sturdy enough to avoid false-positive churn.
- **New CheckRules rule families** beyond the v0.0.3 `always-raises` and v0.1.0 `def.return-type-mismatch` lines (type-incompatible writes, unreachable branches).
- **Plugin return-type contributions.** Plugins emit diagnostics today; the `FlowContribution`-based contribution surface that lets them replace the analyzer's inferred return type for a call site is queued for a v0.1.x slice once the example plugins have stabilised against the merger surface. Sketched in each example's "Future direction" section.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 narrows the gap, but per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` still absorb false positives the narrow regex misses. Long-term: the classifier should track the helpers transitively without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix).

3. **`numeric.yml` `unknown` entries.** After v0.0.9, only `Integer#ceildiv` remains `unknown` (prelude body delegates to user-overridable `#div`, classified as `composed`). `Numeric#clone` was resolved by adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` (commit a7d9265). The remaining entry is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

## Reading Order for a Returning Implementer

The default goal is "ship v0.1.0, then start v0.1.1." Read in this order:

1. `CHANGELOG.md` `[Unreleased]` section — every v0.1.0 slice + polish item that has landed since `v0.0.9` was tagged. The user-visible summary the release will publish.
2. [`docs/MILESTONES.md`](MILESTONES.md) — `v0.1.0` row (six slices closed, polish work landed) and `v0.1.1 — Planned` (the regex-pattern recogniser is the headline).
3. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the binding design for the plugin contract that v0.1.0 ships.
4. [`docs/adr/7-v0.1.0-slice-decisions.md`](adr/7-v0.1.0-slice-decisions.md) — slice-by-slice working decisions for slices 4 / 5 / 6 (the trickier half of v0.1.0).
5. [`examples/README.md`](../examples/README.md) — plugin-authoring landing page; comparison table over the six worked examples + recommended reading order.
6. [`docs/handbook/`](handbook/README.md) — end-user view of the type model. Skim Chapter 7 (RBS / `RBS::Extended`) and Chapter 8 (Understanding errors) for what user-facing diagnostics now look like.
7. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. Cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
8. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes still bind the type-object public surface plugins consume.
9. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule plugin-authored signatures follow.

After those, the implementation surface for v0.1.x is locatable from grep over `lib/rigor/inference/narrowing.rb`, `lib/rigor/flow_contribution*.rb`, `lib/rigor/plugin/`, `lib/rigor/cache/`, `lib/rigor/rbs_extended/`, and `lib/rigor/analysis/`.
