# Public API Stability Boundary

Status: **Active — the enumerated surface is under the `v0.2.0` evaluation
trial** ([`docs/compatibility.md`](../compatibility.md) § the three stages:
committed-to-as-a-trial from `v0.2.0`, binding at `v1.0.0`).
Lists the namespaces the plugin contract is designed against and pins
them in place via the [public-API drift spec](../../spec/rigor/public_api_drift_spec.rb).
The v0.1.0 plugin contract shipped and the `0.1.x` preview line extended
the surface (cross-plugin facts, `signature_paths:`, `open_receivers:`,
`protocol_contracts:`, `source_rbs_synthesizer:`); `v0.2.0` was the first
line to pledge minor-non-break on it for external `rigor-*` gems. (The
`rigor <command>` CLI itself — including newer subcommands like `mcp`,
`triage`, `baseline`, `plugin`, `skill` — stays internal plumbing per
the exclusion list below; its user-facing contract lives in
`docs/manual/`.) The drift spec catches accidental signature changes so
every change stays deliberate and reviewable.

This document is the **plugin-author view** of the pinned namespaces.
The project-wide compatibility commitment — the full public surface
(CLI, `.rigor.yml` keys, diagnostic vocabulary, baseline + cache
formats, `RBS::Extended` grammar) and the trial-then-freeze trajectory
it binds on — lives in [`docs/compatibility.md`](../compatibility.md)
(the [ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
WD1 surface document); this file is the namespace-level detail under
that umbrella.

## Why this boundary exists

ADR-2 commits Rigor to a plugin architecture that lets gem authors
contribute capability roles, dynamic-return facts, type-specifying
plugins, and `RBS::Extended` directives. Plugin authors will write
against a small set of read-side surfaces:

- **`Rigor::Plugin::_Scope`** — what a hook may call on the per-node
  analysis state it receives. A structural interface, not the engine's
  `Rigor::Scope` class.
- **`Rigor::Type`** + **`Rigor::Type::Combinator`** — the type-object
  layout and factory entry points.
- **`Rigor::Plugin::_Environment`**, **`_Services`**, **`_FactStore`**
  and **`_Configuration`** — the interfaces for the project-level RBS
  handle a scope exposes and for the services container `init` /
  `prepare` receive.
- **`Rigor::Reflection`** — the unified read-side facade over the
  three reflection sources (ClassRegistry + RbsLoader + Scope's
  discovered facts).
- **`Rigor::FlowContribution`** — the bundle plugins return (the
  v0.1.0 contribution merger consumes bundles directly).
- **`Rigor::Analysis::Diagnostic`** — the diagnostic shape plugins
  emit (with `source_family` provenance). The `Diagnostic.from_node`
  / `.from_location` constructors (and the `Plugin::Base#diagnostic`
  wrapper) internalise the 1-based `line` / `start_column + 1`
  positioning convention (ADR-37).

This document declares which methods on those namespaces are
**public** (plugin authors may rely on them) versus **internal**
(may change without notice).

**The criterion** ([ADR-128](../adr/128-plugin-hook-surface-interfaces.md)):
a method is public plugin API **if and only if** it is declared on
`Rigor::Plugin::Base`, on a plugin-facing interface
(`sig/rigor/plugin/interfaces.rbs`), or in a namespace this document lists
as public. Being reachable at runtime does not make a method public, and
neither does a drift pin. The concrete engine classes behind the interfaces
(`Rigor::Scope`, `Rigor::Environment`, `Rigor::Plugin::Services`,
`Rigor::Plugin::FactStore`, `Rigor::Configuration`) are internal
([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) WD1): a
plugin that calls past the interface works today and may break in any
release. A method enters an interface only when a plugin needs it and its
contract can be stated without naming an engine-internal type or hiding an
uncertainty direction; otherwise Rigor adds a facade on a public namespace
(`Reflection.project_method_defined` is the first).

The interface member lists:

- `_Scope` — `type_of`, `self_type`, `local`, `source_path`, `with_local`, and a non-nil
  `environment`.
- `_Environment` — `nominal_for_name`, `rbs_module?`.
- `_Services` — `fact_store`, `configuration`, `reflection` and `type`.
  The last two are the public `Rigor::Reflection` and
  `Rigor::Type::Combinator` modules themselves, not narrower interfaces,
  because a plugin reaches both by constant as well.
- `_FactStore` — `publish`, `read`.
- `_Configuration` — `paths`.

Every hook position in `Plugin::Base` is typed against these, concrete
`Prism` node classes, `Rigor::Type::t` and core types. A hook's `scope` is
non-nil: the engine calls every scope-taking hook with a `Scope`.

The v0.0.9 cluster grew per-namespace
drift snapshots so future signature changes show up as test
failures, not silent breakage.

## What is currently locked

The drift spec at
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
pins instance and singleton method sets for:

- The member lists of the plugin-facing interfaces above (the
  `PLUGIN_INTERFACE_MEMBERS` snapshot, read from the RBS).
- `Rigor::Scope` and `Rigor::Environment` — instance methods + the
  `Scope.empty(environment:)` factory and `Environment.default` /
  `Environment.for_project(root:, libraries:, signature_paths:, cache_store:)`.
  **These two snapshots are internal change detectors, not promises**: they
  make a signature change on an engine class deliberate and reviewable, and
  no plugin may rely on a member only they pin.
- `Rigor::Type::Combinator` — every factory the inference engine
  reaches for (`top`, `bot`, `untyped`, `nominal_of`, `singleton_of`,
  `constant_of`, `integer_range`, `positive_int`, `non_empty_string`,
  `lowercase_string`, `literal_string`, `union`, `intersection`,
  `difference`, `refined`, `key_of`, `value_of`, `indexed_access`, …).
- `Rigor::Reflection` — every `class_declarations_in`, `class_known?`,
  `class_ordering`, `class_type_param_names`, `constant_type_for`,
  `ancestry_reaches`, `discovered_class?`, `discovered_method?`, `external_method_defined`, `instance_definition`,
  `instance_method_definition`, `nominal_for_name`, `project_method_defined`,
  `rbs_class_known?`, `singleton_definition`, `singleton_for_name`, `singleton_method_definition`.
  `project_method_defined(class_name, method_name, kind:, source:, scope:)`
  (ADR-128 WD1) is the ancestor question plugins used to ask through two
  `Scope` walks: it answers a `Rigor::Trinary`, and `maybe` exactly where
  the walk's ancestor budget ran out before it found a definer. See
  [`reflection.md`](reflection.md) § "Source-side discoveries".
  `external_method_defined(class_name, method_name, kind:, scope:)` asks the
  same question of RBS through the project's ancestry, and
  `ancestry_reaches(class_name, ancestor_names, kind:, scope:)` asks whether
  that ancestry reaches a named class; both answer a `Trinary`.
  `class_declarations_in(root) { |declared_call| … }` (#2708) is the per-file
  declaration walk: the classes a parsed file declares as
  `Rigor::Reflection::ClassDeclaration` values (`name`, `nesting`, `node`),
  and, when given a block, each call the walk visits as
  `Rigor::Reflection::DeclaredCall` values (`node`, `owner`: the class or
  module the call sits in). It is the entry point `rigor-alba` and `rigor-typelizer` use
  in place of `Rigor::Inference::DeclarationWalk`, which stays internal.
- `Rigor::Trinary` — the value `Reflection.project_method_defined` returns:
  `yes?` / `no?` / `maybe?`, `and`, `or`, `negate`, `value`, `==` and the
  `Trinary.yes` / `.no` / `.maybe` / `.from_symbol` constructors.
- `Rigor::Plugin` — `register`, `registered`, `registered_for`,
  `unregister!` (test helper). v0.1.0 slice 1.
- `Rigor::Plugin::Base` — the class-level `manifest(**fields)`,
  `producer`, `node_rule`, `node_file_context`, and FFI recognition
  (`ffi_binding_recognizer`, `ffi_binding_recognizers`) DSLs;
  instance-level `services` / `config` / `manifest`, the override
  hooks `#init` / `#prepare` / `#diagnostics_for_file` /
  `#template_units_for_file` / `#template_units_pass_started` (#1047),
  the engine-owned-walk dispatcher
  `#node_rule_diagnostics`, the `#diagnostic(node, …)` builder, and
  the run-scoped disclosure channel `#disclose_once(key, message:,
  severity:, rule:)` / `#run_disclosure_records` (#1051), and its
  positioned sibling `#emit_once(key, diagnostics)` (#1060).
  v0.1.0 slice 1 + ADR-37 + ADR-30 (#727) + #392 + #1051 + #1060.
- `Rigor::Plugin::Manifest` — `id`, `version`, `description`,
  `protocol_contracts`, `config_schema`, `validate_config(config)`,
  `template_globs`.
- `Rigor::Plugin::TemplateUnit` — the #392 template-unit carrier:
  `logical_name`, `path`, `ruby_source`, `line_map`, `self_type`,
  `locals`, `ivar_seeds`, `transform_id`, `suppressed_rules` (#393),
  plus `unit_key`, `digest(fallback_transform_id = nil)`,
  `template_line(ruby_line)` and the value-object trio (`==` / `eql?`
  / `hash` / `to_h`). Spec'd in
  [`macro-substrate.md`](macro-substrate.md) § Template units.
- `Rigor::Plugin::Services` — `reflection`, `type`, `configuration`,
  `fact_store`, `cache_store`, `trust_policy`, `io_boundary_for(plugin_id)`. Of these only
  the `_Services` members (`fact_store`, `configuration`, `reflection`,
  `type`) are plugin API; the rest are pinned as an internal change detector
  because no bundled plugin calls them through `services`.
- `Rigor::Plugin::Registry` — `plugins`, `ids`, `find(id)`,
  `load_errors`, `empty?`, `any_load_errors?`.
- `Rigor::Plugin::TrustPolicy` — `trusted_gems`,
  `allowed_read_roots`, `network_policy`, `allow_read?(path)`,
  `network_allowed?`, `gem_trusted?(name)`, `to_h`. v0.1.0 slice 2.
- `Rigor::Plugin::IoBoundary` — `policy`, `plugin_id`,
  `read_file(path)`, `open_url(url)`, `cache_descriptor`. v0.1.0
  slice 2.
- `Rigor::Source::Literals` — the argument-literal extraction grid
  `symbol`, `symbol_name`, `symbol_or_string`, `symbol_or_string_name`,
  `symbol_arguments`, `symbol_arg`. The one deliberately-public member
  of the otherwise-internal `Rigor::Source::*` namespace (see below):
  the shared DSL-walker helper plugin authors are pointed at
  (boilerplate-reduction plan § 0a). v0.1.x.

Any signature change on these methods has to update the matching
`PublicApiDriftSnapshots::*` constant in the same commit.

**The boundary gate.** The drift spec pins what Rigor promises; it cannot see
what plugins actually call. A spec-only `TracePoint` recorder
(`spec/support/plugin_boundary.rb`, ADR-128 WD4) runs over the bundled
plugins' integration specs (`make test-integration-plugins`), records every
method a frame under `plugins/` or `examples/` calls on an interface's
backing class or on a module under `Rigor::Inference`, and fails the run on
any that is neither declared by the interface, nor part of the
`Object` / `Kernel` / `BasicObject` protocol, nor a row of its allow-list.
Its coverage is whatever those specs exercise, and it covers bundled plugins
only. Calls made in forked pool workers are not recorded.

## What is intentionally NOT yet locked

- **`Rigor::FlowContribution`** — the bundle struct shipped in
  v0.0.9 (`c48f05f`); slice 3 added `#to_element_list` and pinned
  the bundle shape via the public-API drift spec. Plugin authors
  should consume bundles via the public reader / `to_h` form and
  avoid pinning the per-slot value shapes (`PredicateEffect`,
  `AssertEffect`, …) directly — v0.1.0 ratified the bundle, not those.
- **`Rigor::FlowContribution::Element` / `MergeResult` / `Conflict` /
  `Merger`** — slice 3 surface; pinned by the drift spec. The
  flattening + merge policy is normative per
  [`flow-contribution-merger.md`](flow-contribution-merger.md).
- **`Rigor::Analysis::Diagnostic`** — `source_family` and
  `qualified_rule` were added in v0.0.8 (`ed9ae0a`); the per-rule
  identifiers themselves remain out of the pinned surface and freeze
  as public vocabulary at `v1.0.0` (ADR-50), which is why
  `Rigor::Analysis::Diagnostic` stays out of the drift spec.
- **`Rigor::Cache::*`** — the producer-facing
  `Store#fetch_or_compute(producer_id:, params:, descriptor:,
  serialize:, deserialize:)` API is the most stable layer, and the
  one plugin-side cache producers ride
  ([plugin-cache-producers.md](plugin-cache-producers.md)). The
  descriptor schema is fixed by ADR-6 and the slice-taxonomy design
  doc; plugin authors should add `PluginEntry` rows rather than new
  slot kinds.
- **`Rigor::RbsExtended`** directive parsers — public reader
  methods (`read_predicate_effects`, `read_assert_effects`,
  `read_return_type_override`, `read_param_type_overrides`,
  `read_flow_contribution`) are stable shapes today; the per-effect
  Data carriers (`PredicateEffect`, `AssertEffect`,
  `ParamOverride`) are unpinned for the same reason as
  `FlowContribution`'s per-slot shapes.
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
  evolves. The declaration walk (`Rigor::Inference::DeclarationWalk`) is
  among them; a plugin asks `Rigor::Reflection.class_declarations_in` instead.
- Any method of `Rigor::Scope`, `Rigor::Environment`, `Rigor::Plugin::Services`,
  `Rigor::Plugin::FactStore` or `Rigor::Configuration` that its interface
  above does not declare, and `Rigor::Plugin::TypeNodeResolver`'s
  `NameScope` (a later ADR-128 slice decides its interface).
- `Rigor::Analysis::FactStore`, `Analysis::Result`,
  `Analysis::CheckRules`, `Analysis::Runner`. The diagnostic
  catalogue and the rule definitions are not a plugin extension
  surface — plugins emit diagnostics via the v0.1.0 plugin
  protocol, not by adding rows to `CheckRules`.
- `Rigor::AST::*` virtual nodes. The synthetic AST nodes the
  engine uses internally are not a stable plugin surface.
- Any `Rigor::Source::*` (**except `Rigor::Source::Literals`**, locked
  above), `Rigor::CLI::*`, `Rigor::Configuration` helper. These are
  CLI / loader plumbing. `Source::Literals` is the one carve-out: it is
  drift-pinned and the recommended plugin-author argument extractor.

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
