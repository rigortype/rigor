# Public API Stability Boundary

Status: **Pre-v0.1.0 surface declaration.** Lists the namespaces
the v0.1.0 plugin contract will be designed against and pins them
in place via the [public-API drift spec](../../spec/rigor/public_api_drift_spec.rb).
Until v0.1.0 ships, the surface is allowed to evolve commit-by-commit;
the drift spec catches accidental signature changes so changes are
deliberate and reviewable.

## Why this boundary exists

ADR-2 commits Rigor to a plugin architecture that lets gem authors
contribute capability roles, dynamic-return facts, type-specifying
plugins, and `RBS::Extended` directives. Plugin authors will write
against a small set of read-side surfaces:

- **`Rigor::Scope`** — the per-node analysis state (locals, ivars,
  facts, environment).
- **`Rigor::Type`** + **`Rigor::Type::Combinator`** — the type-object
  layout and factory entry points.
- **`Rigor::Environment`** — the project-level RBS / class-registry
  / cache-store handle.
- **`Rigor::Reflection`** — the unified read-side facade over the
  three reflection sources (ClassRegistry + RbsLoader + Scope's
  discovered facts).
- **`Rigor::FlowContribution`** — the bundle plugins return (the
  v0.1.0 contribution merger consumes bundles directly).
- **`Rigor::Analysis::Diagnostic`** — the diagnostic shape plugins
  emit (with `source_family` provenance).

This document declares which methods on those namespaces are
**public** (plugin authors may rely on them) versus **internal**
(may change without notice). The v0.0.9 cluster grew per-namespace
drift snapshots so future signature changes show up as test
failures, not silent breakage.

## What is currently locked

The drift spec at
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
pins instance and singleton method sets for:

- `Rigor::Scope` — instance methods + the `Scope.empty(environment:)`
  factory.
- `Rigor::Environment` — instance methods + `Environment.default` /
  `Environment.for_project(root:, libraries:, signature_paths:, cache_store:)`.
- `Rigor::Type::Combinator` — every factory the inference engine
  reaches for (`top`, `bot`, `untyped`, `nominal_of`, `singleton_of`,
  `constant_of`, `integer_range`, `positive_int`, `non_empty_string`,
  `lowercase_string`, `literal_string`, `union`, `intersection`,
  `difference`, `refined`, `key_of`, `value_of`, `indexed_access`, …).
- `Rigor::Reflection` — every `class_known?`, `class_ordering`,
  `class_type_param_names`, `constant_type_for`, `discovered_class?`,
  `discovered_method?`, `instance_definition`, `instance_method_definition`,
  `nominal_for_name`, `rbs_class_known?`, `singleton_definition`,
  `singleton_for_name`, `singleton_method_definition`.
- `Rigor::Plugin` — `register`, `registered`, `registered_for`,
  `unregister!` (test helper). v0.1.0 slice 1.
- `Rigor::Plugin::Base` — class-level `manifest(**fields)`,
  instance-level `services` / `config` / `manifest`, the override
  hook `#init(services)`. v0.1.0 slice 1.
- `Rigor::Plugin::Manifest` — `id`, `version`, `description`,
  `protocols`, `config_schema`, `validate_config(config)`.
- `Rigor::Plugin::Services` — `reflection`, `type`, `configuration`,
  `cache_store`, `trust_policy`, `io_boundary_for(plugin_id)`.
- `Rigor::Plugin::Registry` — `plugins`, `ids`, `find(id)`,
  `load_errors`, `empty?`, `any_load_errors?`.
- `Rigor::Plugin::TrustPolicy` — `trusted_gems`,
  `allowed_read_roots`, `network_policy`, `allow_read?(path)`,
  `network_allowed?`, `gem_trusted?(name)`, `to_h`. v0.1.0 slice 2.
- `Rigor::Plugin::IoBoundary` — `policy`, `plugin_id`,
  `read_file(path)`, `open_url(url)`, `cache_descriptor`. v0.1.0
  slice 2.

Any signature change on these methods has to update the matching
`PublicApiDriftSnapshots::*` constant in the same commit.

## What is intentionally NOT yet locked

- **`Rigor::FlowContribution`** — the bundle struct shipped in
  v0.0.9 (`c48f05f`); slice 3 added `#to_element_list` and pinned
  the bundle shape via the public-API drift spec. Plugin authors
  should consume bundles via the public reader / `to_h` form and
  avoid pinning the per-slot value shapes (`PredicateEffect`,
  `AssertEffect`, …) directly until v0.1.0 ratifies them.
- **`Rigor::FlowContribution::Element` / `MergeResult` / `Conflict` /
  `Merger`** — slice 3 surface; pinned by the drift spec. The
  flattening + merge policy is normative per
  [`flow-contribution-merger.md`](flow-contribution-merger.md).
- **`Rigor::Analysis::Diagnostic`** — `source_family` and
  `qualified_rule` were added in v0.0.8 (`ed9ae0a`) but the
  per-rule diagnostic identifiers are still in flux as the v0.1.0
  plugin observability story finalises.
- **`Rigor::Cache::*`** — the producer-facing
  `Store#fetch_or_compute(producer_id:, params:, descriptor:,
  serialize:, deserialize:)` API is the most stable layer and the
  one plugin-side cache producers will ride. The descriptor schema
  is fixed by ADR-6 and the slice-taxonomy design doc; plugin
  authors should add `PluginEntry` rows rather than new slot kinds.
- **`Rigor::RbsExtended`** directive parsers — public reader
  methods (`read_predicate_effects`, `read_assert_effects`,
  `read_return_type_override`, `read_param_type_overrides`,
  `read_flow_contribution`) are stable shapes today; the per-effect
  Data carriers (`PredicateEffect`, `AssertEffect`,
  `ParamOverride`) are subject to the same v0.1.0 refinement as
  `FlowContribution`.
- **`Rigor::Plugin::*`** — registration / loading surface landed
  in v0.1.0 slice 1. The instance-level `Rigor::Plugin::Base#init`
  hook is stable today; protocol hooks added by slices 3–6 may
  refine the public method set on `Base`. Plugin authors should
  pin their gem to a specific Rigor version while v0.1.0 is in
  development.

## Internal surfaces (NOT public)

Plugin authors must NOT rely on:

- `Rigor::Inference::*` modules (ScopeIndexer, ExpressionTyper,
  StatementEvaluator, MethodDispatcher, MethodParameterBinder,
  ClosureEscapeAnalyzer, CoverageScanner). These are the engine's
  internal mechanism; their shapes change as the inference surface
  evolves.
- `Rigor::Analysis::FactStore`, `Analysis::Result`,
  `Analysis::CheckRules`, `Analysis::Runner`. The diagnostic
  catalogue and the rule definitions are not a plugin extension
  surface — plugins emit diagnostics via the v0.1.0 plugin
  protocol, not by adding rows to `CheckRules`.
- `Rigor::AST::*` virtual nodes. The synthetic AST nodes the
  engine uses internally are not a stable plugin surface.
- Any `Rigor::Source::*`, `Rigor::CLI::*`, `Rigor::Configuration`
  helper. These are CLI / loader plumbing.

## Promotion path

When a v0.1.0 plugin contract requires a currently-internal surface
to become public:

1. The relevant ADR is amended (ADR-2 for the plugin extension
   protocol, ADR-3/4 for type-object / inference engine details).
2. The class is added to
   [`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
   with a snapshot of its method set. From that commit forward,
   accidental signature changes break the drift spec.
3. This document grows a "Promoted in v0.1.0" entry for the new
   namespace.

## Reading order for a plugin author

1. [`docs/adr/2-extension-api.md`](../adr/2-extension-api.md) — the
   plugin contract (capability roles, contribution merging,
   diagnostic provenance, registration, configuration, caching,
   trust / I/O).
2. [`docs/internal-spec/internal-type-api.md`](internal-type-api.md)
   — type-object public contract every `Rigor::Type::*` carrier
   satisfies.
3. [`docs/internal-spec/inference-engine.md`](inference-engine.md)
   — `Rigor::Scope#type_of` purity, fact-store / effect model,
   environment-loading boundaries.
4. [`docs/internal-spec/reflection.md`](reflection.md) — the
   `Rigor::Reflection` read-side facade.
5. [`docs/internal-spec/flow-contribution.md`](flow-contribution.md)
   — the `Rigor::FlowContribution` bundle.
6. [`docs/internal-spec/cache.md`](cache.md) — the cache layer's
   public read shape; plugin-side cache producers ride this API.
