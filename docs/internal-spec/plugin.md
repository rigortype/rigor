# Plugin Registration / Loading (slice 1)

Status: **v0.1.0 slice 1 normative.** Pins the public surface plugin
authors interact with for *registering* a plugin, declaring its
*manifest*, and being *loaded* by `Analysis::Runner`. The
contribution protocols (dynamic-return, type-specifying, dynamic
reflection) attach in subsequent v0.1.0 slices and are not defined
here.

The binding design surface is [ADR-2](../adr/2-extension-api.md);
the v0.1.0 readiness map is at
[`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md).
When this spec disagrees with ADR-2, the ADR binds.

## Public namespaces (drift-pinned)

Every namespace below is locked by
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb).
Signature changes update the matching `PublicApiDriftSnapshots::*`
constant in the same commit.

### `Rigor::Plugin`

Module-level entry for plugin registration.

| Method | Purpose |
| --- | --- |
| `Rigor::Plugin.register(plugin_class)` | Plugin gem calls this at load time to advertise its `Rigor::Plugin::Base` subclass. |
| `Rigor::Plugin.registered_for(id)` | Loader-side lookup by manifest id. |
| `Rigor::Plugin.registered` | Frozen `{ id => class }` snapshot. |
| `Rigor::Plugin.unregister!(id = nil)` | Test-only reset. The plugin contract does not require gem authors to call this. |

The registry is process-global and mutex-guarded. Registering the
same class twice is a no-op; registering a different class under
the same id raises `Rigor::Plugin::LoadError` so two plugins
cannot silently shadow each other.

### `Rigor::Plugin::Base`

Base class every plugin subclasses.

```ruby
class MyPlugin < Rigor::Plugin::Base
  manifest(
    id: "my-plugin",
    version: "0.1.0",
    description: "...",
    protocols: [],
    config_schema: { "flag" => :boolean }
  )

  def init(services)
    @reflection = services.reflection
  end
end
```

Class-level `manifest(**fields)` declares the manifest once at
class definition time; the same method without arguments returns
the cached `Manifest`. Instance-level `manifest` delegates to the
class.

`#initialize(services:, config: {})` stores the injected services
and a frozen copy of the user's config. `#init(services)` is the
override hook plugins use to wire up state from the service
container; the default implementation is a no-op.

`#diagnostics_for_file(path:, scope:, root:)` (slice 5) is the
**whole-file** diagnostic hook. The default returns an empty array.
Plugin authors MAY override it to walk `root` (the parsed
`Prism::Node`) themselves and return an array of
`Rigor::Analysis::Diagnostic` rows, but the preferred surface for
node-scoped checks is `node_rule` (below), which lets the engine own
the walk. `#diagnostics_for_file` is reserved for genuinely
file-scoped diagnostics — a single load-error row, or a check that
needs the whole parsed file at once. The runner re-stamps every
returned diagnostic with `source_family: "plugin.<manifest.id>"` per
ADR-7 § "Slice 5-B" so plugin authors cannot accidentally publish
under another plugin's id. Plugin exceptions inside the hook isolate
as a `:plugin_loader` `runtime-error` diagnostic rather than crashing
`rigor check`.

#### Node-scoped rules — `node_rule` / `#node_rule_diagnostics` (ADR-37)

`node_rule(node_type) { |node, scope, path, file_context, context| … }`
is a class-level DSL (the `producer`-style shape) declaring a
node-scoped diagnostic rule. The engine walks each analysed file's AST
**once** and dispatches every node where `node.is_a?(node_type)` to the
rule, so the plugin author writes the check and never the traversal —
this is what lets a plugin drop the hand-rolled `def walk` /
`compact_child_nodes.each` recursion. The block runs through
`instance_exec` (so `self` is the plugin instance — `config`,
`services`, `services.fact_store`, `diagnostic` are all in scope),
receives `(node, scope, path, file_context, context)`, and returns an
`Array<Rigor::Analysis::Diagnostic>` (empty to fire nothing).
`node_type` MUST be a `Prism::Node` subclass. Multiple rules per type
run in declaration order. The engine invokes them through the
instance method `#node_rule_diagnostics(path:, scope:, root:)`, which
the runner calls alongside `#diagnostics_for_file` under the same
`plugin.<id>` stamping and per-plugin exception isolation; a plugin
that declares no rules pays zero cost.

The **fifth** block argument, `context` (ADR-37 Slice 1d), is a
`Rigor::Plugin::NodeContext` carrying the node's lexical ancestor chain
— the `ContextInfo` ADR-2 promised. It exposes `#ancestors` (the full
chain, outermost first, excluding the node) plus the conveniences
`#enclosing_def`, `#enclosing_module`, and `#enclosing_block(name)`. A
rule reads it when the check depends on *where* the node sits: the
enclosing controller a `before_action` / `render` belongs to
(`rigor-actionpack` re-derives the namespace-qualified controller name
from `context.ancestors`), the `describe <Model>` a matcher is under
(`rigor-shoulda-matchers`), or the action a lazy `t('.key')` expands
against (`rigor-rails-i18n`). Blocks that take fewer parameters simply
ignore the trailing arguments (back-compat).

`node_file_context { |root, scope| … }` supports two-pass
(collect-then-validate) plugins. It runs once per file (via
`instance_exec`) before any node rule fires, and its return value is
threaded to every rule as the **fourth** block argument (existing
three-parameter blocks ignore it). A *same-file* collect — gathering
declared names before validating references to them — belongs here,
because the engine's single forward walk cannot complete the collect
before a reference is reached. A *cross-file* collect belongs in
`#prepare` + `services.fact_store` instead; a node rule reads the
published fact directly and needs no per-file context.

#### Positioning a diagnostic — `#diagnostic` (ADR-37 author helper)

`#diagnostic(node, path:, message:, severity: :error, rule: nil,
location: nil)` builds a `Rigor::Analysis::Diagnostic` positioned at
`node`, internalising the 1-based `line` / `start_column + 1`
convention every plugin otherwise re-derives by hand. Pass `location:`
(a Prism location) to point at a sub-location — typically
`node.message_loc`, so a matcher / method-name diagnostic points at
the name rather than the receiver-spanning whole call; a `nil`
`location:` falls back to `node.location`. Authors MUST NOT set
`source_family` (the runner stamps it). The underlying constructors
`Rigor::Analysis::Diagnostic.from_node(node, …)` and
`.from_location(location, …)` are public for core rules and other
producers.

`Rigor::Plugin::Base.suggest(name, candidates)` (boilerplate-reduction
plan § 0c) is the shared "did you mean …?" helper: it returns the closest
of `candidates` to `name` via `DidYouMean::SpellChecker` (the engine
Ruby's own `NoMethodError` hints use), or `nil`. It is a **class** method
so it is callable from both a plugin instance and an `Analyzer` module
function, and replaces the hand-rolled Levenshtein copies plugins used to
carry. It only affects suggestion *text* on an already-emitted
diagnostic, never whether one fires.

`#prepare(services)` (ADR-9) is the project-wide pre-pass hook,
invoked once before per-file analysis begins. Plugins that publish
cross-plugin facts (`manifest(produces:)`) override it to walk the
project and call `services.fact_store.publish(...)`; the loader's
topological ordering guarantees a producer's `prepare` runs before
any consumer's. The default is a no-op.

#### Extracting argument literals — `Source::Literals` (boilerplate plan § 0a)

`Rigor::Source::Literals` is the shared answer to "is this Prism
argument node a literal `:sym` / `"str"`, and if so what does it
name?" — the question nearly every DSL walker asks (`state :draft`,
`has_one_attached :avatar`, `validate_presence_of(:name)`). It is the
recommended extractor over a hand-rolled `node.unescaped.to_sym if
SymbolNode || StringNode`, pinned in the public-API drift spec
(`SOURCE_LITERALS_SINGLETON`) and exempt from the
"`Rigor::Source::*` is internal" rule in
[`public-api.md`](public-api.md). The methods are `module_function`s,
so each is callable as `Rigor::Source::Literals.symbol(node)`.

The single-node surface is a grid over two axes — which node kinds are
accepted, and what the caller wants back — each returning `nil` for any
other node (including `nil`):

| accepts | → `Symbol` | → `String` |
| --- | --- | --- |
| `:sym` only | `.symbol(node)` | `.symbol_name(node)` |
| `:sym` or `"str"` | `.symbol_or_string(node)` | `.symbol_or_string_name(node)` |

The `SymbolNode`-only forms exist so a DSL that distinguishes `state
:draft` from `state "draft"` keeps that distinction instead of
silently widening. `#unescaped` (not `#value`) is used so an
interpolation-free `"foo"` / `:foo` round-trips to `:foo` / `"foo"`
consistently for both node kinds.

Two call-argument helpers sit on top of the grid:

- `.symbol_arguments(call_node)` → `Array[Symbol]` — every literal
  Symbol/String positional argument in source order; non-literal
  arguments are dropped; `[]` when the call has no argument list.
- `.symbol_arg(call_node, index)` → `Symbol?` — the literal at
  positional `index`, or `nil` when the call has no argument list, the
  index is out of range, or that argument is not a literal
  Symbol/String.

#### Return-type and narrowing contributions — `dynamic_return` / `type_specifier` (ADR-37 Slice 2)

`flow_contribution_for` was consulted at exactly two engine sites, each
reading exactly one slot of the returned bundle: `MethodDispatcher`
reads `.return_type` (the per-call-site return type) and
`StatementEvaluator` reads `.post_return_facts` (assertion-edge
narrowing). ADR-37 Slice 2 splits those two consumption sites into two
narrow, declaratively-gated class DSLs — the `producer`-style shape, so
the block carries logic and runs through `instance_exec`:

- `dynamic_return(receivers:) { |call_node, scope| Type | nil }` — the
  per-call-site **return type**, gated on the receiver's class. The
  engine calls the block only when the call's receiver type's class
  equals or inherits from a declared `receivers:` entry (matched via
  `Environment#class_ordering`); first non-`nil` wins. The engine
  invokes it through `#dynamic_return_type(call_node:, scope:,
  receiver_type:)`. `rigor-mangrove` (unwrap → carried `type_args[0]`)
  is the worked consumer.
- `type_specifier(methods:) { |call_node, scope| facts | nil }` —
  **post-return narrowing facts**, gated on `call_node.name` being in
  the declared `methods:`. The engine invokes it through
  `#type_specifier_facts(call_node:, scope:)`. `rigor-minitest`
  (assertion narrowing) and `rigor-rspec`'s matcher narrowing are the
  worked consumers.

`receivers:` / `methods:` are the greppable, indexable gates the
`rigor plugins --capabilities` catalogue (ADR-37 § "Machine-readable
capability catalogue") enumerates.

`#flow_contribution_for(call_node:, scope:)` (ADR-9 / ADR-2) is the
original fat return-type contribution hook, consulted at the same two
sites **alongside** the narrow DSLs. It returns a
`Rigor::FlowContribution` (carrying a precise `return_type` and/or
narrowing facts), or `nil` to decline (the default). It is **the
deprecated escape valve**, retained for the two contribution shapes the
narrow DSLs deliberately do not express — a method-gated return type
(`rigor-rspec`'s `let` / `subject` binding; `rigor-sorbet`'s
sig-driven returns) and a dynamic per-project receiver set
(`rigor-activestorage`'s `Attached::One` / `::Many` on discovered model
classes). New plugins should prefer `dynamic_return` / `type_specifier`;
`flow_contribution_for` is the documented last resort (the role
PHPStan's `ExpressionTypeResolverExtension` plays).

#### Machine-readable capability catalogue — `rigor plugins --capabilities` (ADR-37 Slice 3)

`rigor plugins --capabilities` emits the per-plugin extension-protocol
gates an agent enumerates to learn what each plugin does. Only
**loaded** plugins appear (a plugin that failed to load contributes no
capabilities). With `--format json` the output is:

```json
{
  "configuration": "<path to .rigor.yml, or null>",
  "capabilities": [
    {
      "id": "<plugin id>",
      "gem": "<gem name>",
      "version": "<plugin version>",
      "node_rule_types": ["<Prism node class name>", "..."],
      "dynamic_return_receivers": ["<receiver class name>", "..."],
      "type_specifier_methods": ["<method name>", "..."],
      "produces": ["<fact id>", "..."],
      "consumes": ["<plugin_id/fact_name>", "..."]
    }
  ]
}
```

The five capability arrays are exactly the declarative gates of the
narrow protocols above: `node_rule_types` from each `node_rule` node
type, `dynamic_return_receivers` from `dynamic_return(receivers:)`,
`type_specifier_methods` from `type_specifier(methods:)`, and
`produces` / `consumes` from the ADR-9 manifest fields. An array is
empty when the plugin declares nothing for that surface; the text view
omits empty surfaces entirely. This is the contract that keeps the
gates greppable and indexable without loading plugin code.

### Target-library invocation — `Plugin::Inflector` / `Plugin::Isolation` / `Plugin::Box` (ADR-39)

[ADR-39](../adr/39-plugin-target-library-invocation.md) lets a plugin
**invoke the pure, allow-listed methods of the library it targets**
directly (the Ruby analogue of a PHPStan extension calling into the real
framework), rather than reimplementing them — a reimplementation that
diverges from the library's real behaviour is a wrong fact, i.e. a false
positive. The rule is bounded by the same harness the engine's
constant-folding tier uses: an explicit pure-method allow-list,
Rigor-derived inputs, a checked data result, and **decline (never
approximate)** when the library is unreachable. It does **not** relax
ADR-2's prohibition on executing the analyzed *application's* own code —
the target library is a trusted, declared dependency, distinct from the
project's source.

- `Rigor::Plugin::Inflector` — the worked consumer + the shared
  inflection helper for the Rails-family plugins. `underscore` /
  `camelize` / `singularize` / `pluralize` / `classify` / `tableize`
  delegate to the real `ActiveSupport::Inflector`; it carries **no
  approximation** (raises when the gem is unreachable, so the caller
  declines to silence). `rigor-rails-routes` / `rigor-activerecord` /
  `rigor-actionpack` / `rigor-actionmailer` / `rigor-factorybot` use it.
- `Rigor::Plugin::Isolation` — the **selectable isolation strategy** for
  the invocation, chosen by `RIGOR_PLUGIN_ISOLATION` (the `exe/rigor`
  launcher maps `.rigor.yml`'s `plugins_isolation:` onto it). One
  `call(feature:, receiver:, method:, args:)` interface over three
  backends, **`process` the default**:
  - `process` (default) — a single forked **persistent worker** (forked
    once and reused, not per call) loads + calls the library and returns
    data over a Marshal pipe; a worker crash (even `SIGSEGV`) is
    contained — the parent declines and respawns. Falls back to `none`
    where `fork` is unavailable.
  - `none` — load into the main space and call directly (no isolation;
    the fork-less fallback + explicit opt-out).
  - `ruby_box` — call inside a `Ruby::Box` (`Rigor::Plugin::Box`;
    `exe/rigor` re-execs under `RUBY_BOX=1`). Isolates monkey-patches +
    versions in-process. Experimental; gated on an upstream `Ruby::Box`
    VM bug.
- `Rigor::Plugin::Box` — the `Ruby::Box` wrapper backing the `ruby_box`
  strategy (`enabled?` / `require_feature` / `eval`).

A plugin that needs a target-library fact calls
`Plugin::Inflector` (or, for a new library, `Isolation.call` with its own
allow-list); it never `require`s the target into the main space directly
when isolation matters. The production dependency on the target gem
belongs on the plugin's own gemspec.

### `Rigor::Plugin::Manifest`

Frozen value object describing one plugin's identity. Fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `id` | `String` matching `/\A[a-z][a-z0-9._-]*\z/` | Stable identifier; used as the `PluginEntry#id` and the `plugin.<id>.<rule>` diagnostic prefix. |
| `version` | non-empty `String` | Plugin version; lands in `PluginEntry#version` for cache invalidation. |
| `description` | `String?` | Human-readable summary. |
| `protocols` | `Array<Symbol>` | Protocol names this plugin implements. |
| `config_schema` | `{ String => Symbol \| { kind:, default: } }` | Accepted config keys mapped to a value **kind** (`:string`, `:boolean`, `:integer`, `:array`, `:hash`, `:any`), optionally carrying a declared **default** (ADR-40; see _Declared config defaults_ below). |

The following **extension fields** were added across the `0.1.x`
cycle. All are optional and additive to the pre-1.0 plugin contract;
a plugin declaring none of them is a plain per-file analyzer:

| Field | Type | Purpose |
| --- | --- | --- |
| `produces` | `Array<Symbol>` | Cross-plugin facts this plugin publishes (ADR-9). |
| `consumes` | `Array<Consumption>` | Cross-plugin facts this plugin reads (`{ plugin_id:, name:, optional: }`); drives the loader's topological ordering (ADR-9). |
| `signature_paths` | `Array<String>` | RBS signature directories the plugin contributes, relative to the plugin gem root; resolved by `Loader` and merged into the environment (ADR-25). |
| `owns_receivers` | `Array<String>` | Receiver class names this plugin owns for dispatch routing. |
| `open_receivers` | `Array<String>` | Receiver class names exempted from `call.undefined-method` (their method surface is unbounded — e.g. `ActiveRecord::Relation`) (ADR-26). |
| `type_node_resolvers` | `Array` | `Plugin::TypeNodeResolver` entries contributing custom RBS type-name resolution (ADR-13). |
| `protocol_contracts` | `Array<ProtocolContract>` | Path-scoped behavioural contracts (`path_glob` + `method_name` + param/return types + severity); provide-and-check (ADR-28). |
| `source_rbs_synthesizer` | `#call(path) -> String?` | A callable that synthesises RBS from a project source file at env-build time (e.g. rbs-inline ingestion) (ADR-32). |
| `block_as_methods`, `heredoc_templates`, `trait_registries`, `external_files` | `Array<Plugin::Macro::*>` | The four ADR-16 macro / DSL expansion substrate tiers (A / C / B / D). Value-object shapes spec'd in [`macro-substrate.md`](macro-substrate.md). |
| `nested_class_templates` | `Array<Plugin::Macro::NestedClassTemplate>` | Nested-subclass emission from an enum-shaped block DSL (`variant <Const>, <Type>`); the macro-substrate tier that mints classes, not just methods (ADR-36). Spec'd in [`macro-substrate.md`](macro-substrate.md). |
| `hkt_registrations`, `hkt_definitions` | `Array` | Lightweight-HKT type-function registrations (ADR-20). |
| `additional_initializers` | `Array<AdditionalInitializer>` | `{ receiver_constraint:, methods: }` pairs declaring which non-`initialize` `def`-form methods on a class (and its subclasses) also establish ivar state, feeding `ScopeIndexer`'s read-before-write nil soundness gate (ADR-38). |

`#validate_config(config)` returns an array of error strings; the
loader converts a non-empty result into a `LoadError`. Each extension
field carries its own validation in `Manifest#initialize`.

#### Declared config defaults — `config_schema` `{ kind:, default: }` (ADR-40)

A `config_schema` value MAY be either the original **bare kind**
(`Symbol`/`String` — `"flag" => :boolean`) **or** a `Hash` carrying
`kind:` (required) and an optional `default:`:

```ruby
config_schema: {
  "dsl_method"   => :string,                                  # bare kind, no default
  "state_method" => { kind: :string, default: "state" },      # kind + declared default
  "events"       => { kind: :array,  default: [] }
}
```

The two forms are a pure superset of one grammar; the engine MUST
honour the following contract:

- **Kind map is unchanged in shape.** `Manifest#config_schema` MUST
  remain `{ String => Symbol }` (the kind only), so `#validate_config`,
  `#to_h`, `#==`, and `#hash` are unaffected by which form a key used.
  A `{ kind:, default: }` entry contributes its `kind:` to this map
  exactly as a bare kind would.
- **`Manifest#config_defaults`** MUST expose a frozen
  `{ String => value }` map holding **only** the keys that declared a
  `default:`. It is a public reader (pinned in the public-API drift
  spec + RBS sig). Keys with no declared default do not appear.
- **A declared `default:` MUST be validated against its `kind:` at
  manifest-construction time** (the same `value_matches?` check
  `#validate_config` applies to user values). A wrong-typed default
  (`default: 5` under `kind: :string`) MUST raise an `ArgumentError`
  at load, not fail silently at use.
- **`Plugin::Base#config` merges defaults under the user config**:
  `#initialize` stores `manifest.config_defaults.merge(user_config)`
  (frozen) as `#config`, so **the user config wins** on any key it
  sets. A plugin therefore reads `config.fetch("state_method")` (or
  `config["state_method"]`) and gets the declared default with no
  `DEFAULT_*` constant and no second `fetch` argument; coercions the
  plugin still wants (`.to_sym`, `Array(...)`) stay at the read site. A
  class declared with no manifest (test doubles) keeps the raw config
  unchanged.

This form is config ergonomics only: it changes no rule and no type,
so it cannot introduce a diagnostic. It is also cache-safe — a default
is part of the plugin's *code* (its `version`), which the
`Cache::Descriptor::PluginEntry` key already captures; `config_defaults`
participates in `Manifest#to_h`/`#==`/`#hash` but never in a cache key.

### `Rigor::Plugin::TypeNodeResolver` (ADR-13)

Base class for a plugin-supplied resolver of custom **named / generic
type vocabulary** appearing in an RBS::Extended `%a{rigor:v1:…}` payload
— the surface that lets a plugin teach Rigor a TypeScript-utility-style
type function (`Pick[T, K]`, `Omit[T, K]`) the RBS grammar has no built-in
for. Resolvers are registered through the manifest `type_node_resolvers:`
slot (an `Array` of instances).

A subclass overrides one method:

```
#resolve(node, scope) -> Rigor::Type::Base | nil
```

- `node` is a parser-emitted `Rigor::TypeNode::Identifier` or
  `Rigor::TypeNode::Generic` — the named- or generic-type head the chain
  is asking about.
- `scope` is the companion `Rigor::TypeNode::NameScope` (carrying the
  resolver chain, the class context, and the type-alias table) the
  RBS::Extended directive parser threads down.
- The method MUST return a `Rigor::Type::Base` when the node matches the
  vocabulary this resolver covers, or **`nil` to fall through** to the
  next resolver (and finally to the built-in / RBS fallback). The base
  implementation returns `nil`, so an unimplemented subclass is a safe
  no-op.

The engine aggregates every loaded plugin's resolvers — in
**plugin-registration order** (`Registry#type_node_resolvers` flat-maps
across plugins) — into a single `Rigor::TypeNode::ResolverChain`, which
consults them in order and returns the **first non-`nil`** answer. The
chain is composed once per `Analysis::Runner.run`; when no plugin
contributes a resolver the engine short-circuits (no `NameScope` is
built) so the parser behaves bit-for-bit like the resolver-less default.
Resolvers SHOULD be stateless and re-entrant — the chain MAY consult a
resolver multiple times for the same node. The worked consumer is
`rigor-typescript-utility-types` (`Pick` / `Omit`).

### `Rigor::Plugin::Services`

Frozen DI container handed to every plugin's `#initialize`,
`#init`, and `#prepare`:

| Service | Type |
| --- | --- |
| `reflection` | `Rigor::Reflection` (module). |
| `type` | `Rigor::Type::Combinator` (module). |
| `configuration` | `Rigor::Configuration` (read-only project config). |
| `cache_store` | `Rigor::Cache::Store` or `nil` (slice 6 wires plugin-side cache producers through this). |
| `trust_policy` | `Rigor::Plugin::TrustPolicy` (slice 2; see [`plugin-trust.md`](plugin-trust.md)). |
| `fact_store` | `Rigor::Plugin::FactStore` (ADR-9 / v0.1.1) — the per-run cross-plugin fact store; `#prepare` publishes to it, `#diagnostics_for_file` / `#flow_contribution_for` read from it. |

A logger service will join this list when the diagnostics
formatter grows a progress channel.

### `Rigor::Plugin::Registry`

Read-only snapshot of plugins loaded for a single
`Analysis::Runner.run`. Returned by `Rigor::Plugin::Loader.load`
and exposed as `Analysis::Runner#plugin_registry`.

| Method | Returns |
| --- | --- |
| `#plugins` | Loaded `Rigor::Plugin::Base` instances in deterministic order. |
| `#ids` | `Array<String>` of manifest ids, parallel to `#plugins`. |
| `#find(id)` | Lookup by id; `nil` when absent. |
| `#load_errors` | `Array<Rigor::Plugin::LoadError>` collected during loading. |
| `#empty?` / `#any_load_errors?` | Predicates. |

`Registry::EMPTY` is the singleton frozen empty registry the
runner uses before plugins load.

### `Rigor::Plugin::LoadError`

Public exception raised inside the loader when a plugin entry
cannot be resolved. Carries `plugin_ref` (the offending gem name
or plugin id) and `cause_class` (the underlying exception class,
when applicable). The runner converts each one into a
`Rigor::Analysis::Diagnostic` with `source_family: :plugin_loader`
and `rule: "load-error"`.

## Internal surfaces (NOT public)

- `Rigor::Plugin::Loader` — the loader is internal infrastructure.
  Plugin authors should not subclass or depend on its private
  helpers; the public entry point is `Loader.load(configuration:,
  services:, requirer:)`.

## `.rigor.yml` plugin entries

The configuration's `plugins:` field accepts both shorthand and
explicit forms:

```yaml
plugins:
  - rigor-rails                         # bare gem name
  - gem: rigor-rspec
    id: rspec                           # only required when the gem registers > 1 plugin
    config:
      include_specs: true
```

`Configuration` normalises every entry to one of those two shapes
and exposes them via `Configuration#plugins`.

## Load order

The loader processes `.rigor.yml` `plugins:` entries in the order
the user wrote them. For an entry that resolves to multiple
registered plugin classes (one gem registering > 1 plugin), the
explicit `id:` field disambiguates; without it the loader emits a
`LoadError` rather than guessing. Duplicate ids across entries are
an error, not a silent dedupe.

## Failure isolation (per ADR-2 § "Plugin Trust and I/O Policy")

Loading runs every plugin entry independently; a failure on one
entry does not abort the others. Each failure is collected as a
`LoadError` on the resulting registry, then surfaced by
`Analysis::Runner#run` as an `:error` `Diagnostic` with:

- `path`: `".rigor.yml"`
- `line`: `1`
- `column`: `1`
- `source_family`: `:plugin_loader`
- `rule`: `"load-error"`
- `message`: the `LoadError`'s message (gem path / registration /
  config-schema / `#init` exception, depending on the failure
  kind).

`rigor check` continues with the analysis; plugins that loaded
successfully still participate in later v0.1.0 slices.

## Concurrency and value-object shareability (ADR-15)

Rigor analyses files across parallel workers. The shipped backend is a
**forked persistent worker** pool (the [ADR-15](../adr/15-ractor-concurrency.md)
amendment; the Ractor pool is the deferred target), but the contract is
authored against the stricter Ractor boundary so that target stays
reachable. The durable requirement on plugin code is therefore:

- **Every manifest-borne value object MUST be deeply frozen at
  construction and `Ractor.shareable?`.** This covers `Manifest` itself
  and every nested carrier it holds — the `Macro::*` substrate tiers
  ([`macro-substrate.md`](macro-substrate.md)), `ProtocolContract`,
  `AdditionalInitializer`, `Consumption`, and any `TypeNodeResolver` /
  `source_rbs_synthesizer` callable the author supplies (the author owns
  the thread-safety of a callable's captured state). The per-class
  "`Ractor.shareable?` returns true after `#initialize`" notes throughout
  this spec are instances of this one rule, not separate guarantees.
- **A plugin *instance* is built per worker, never shared.** The
  `Rigor::Plugin::Blueprint` carrier (frozen, `Ractor.shareable?`) is
  what crosses the boundary: it holds the plugin class's **constant path
  String** (not the class object — gems are `require`d on the main
  Ractor before any worker spawns, so each worker resolves the same
  constant via `Object.const_get`) plus a deep-copied, made-shareable
  `config` Hash. Each worker calls `Blueprint#materialize(services:)`
  once at startup — `const_get` → `klass.new(services:, config:)` →
  `#init(services)`, mirroring `Loader#instantiate` — then owns its
  plugin instances and their mutable per-run accumulators for the
  worker's lifetime. Mutable plugin state therefore never crosses a
  boundary; only the frozen Blueprint does.
- **Documented exception:** `Environment::Reflection` (the internal
  read-side carrier backing the public `Rigor::Reflection` facade) is
  frozen but **not** `Ractor.shareable?` — its backing tables transit
  `RBS::Location` objects that are not shareable ([ADR-15](../adr/15-ractor-concurrency.md)
  WD6). It is consequently rebuilt per worker from the shared
  `Cache::Store` rather than shared across the boundary. This is an
  engine-internal carrier, not a plugin surface (see
  [`public-api.md`](public-api.md)).

## Where each capability landed (historical slice map)

The v0.1.0 plugin contract shipped in six slices; all of the
following are now in place and are documented in their own specs:

- **Plugin contribution emission** (`FlowContribution` bundles,
  capability roles, dynamic returns). The standalone
  {Rigor::FlowContribution::Merger}
  ([`flow-contribution-merger.md`](flow-contribution-merger.md))
  shipped in slice 3; `#flow_contribution_for` on
  `Rigor::Plugin::Base` (the return-type contribution tier) shipped
  in slice 4 and was extended by the v0.1.1 cross-plugin work
  (ADR-9).
- **Plugin diagnostic provenance.** Slice 5 routes plugin-emitted
  diagnostics through `Diagnostic#source_family` with
  `plugin.<id>.<rule>` prefixes.
- **Plugin trust / I/O policy enforcement.** Slice 2 shipped the
  declarative {Rigor::Plugin::TrustPolicy} + {Rigor::Plugin::IoBoundary}
  surface; see [`plugin-trust.md`](plugin-trust.md).
- **Plugin-side cache producers.** Slice 6 wires
  `Store#fetch_or_compute` for plugins via `PluginEntry`
  descriptors; see [`plugin-cache-producers.md`](plugin-cache-producers.md).
- **Cross-plugin facts + pre-pass.** `#prepare(services)` +
  `services.fact_store` + `manifest(produces:/consumes:)` shipped in
  v0.1.1 (ADR-9). The extension fields in the `Manifest` table above
  (`signature_paths:`, `open_receivers:`, `protocol_contracts:`,
  `source_rbs_synthesizer:`, the macro substrate, HKT,
  `additional_initializers:`) accreted across the `0.1.x` cycle.
- **Interface segregation** ([ADR-37](../adr/37-plugin-interface-segregation.md), Accepted).
  - *Slice 1 / 1c / 1d* — the `node_rule` class DSL +
    `#node_rule_diagnostics` (the engine-owned walk) + `node_file_context`
    (two-pass support) + `NodeContext` (lexical ancestors) + the
    `#diagnostic` / `Diagnostic.from_node` / `.from_location` author
    helpers. These reframe `#diagnostics_for_file` as the whole-file
    escape valve; **every bundled diagnostic-emitting plugin is migrated
    onto `node_rule`** — `rigor-actionpack` (4 phases,
    namespace-qualification-sensitive) was the last.
  - *Slice 2* — `#flow_contribution_for`'s split into the receiver-gated
    `dynamic_return` + method-gated `type_specifier` DSLs (documented
    above), consulted alongside the now-deprecated fat hook; the
    cleanly-fitting consumers (mangrove / minitest / rspec-matcher) are
    migrated, the method-gated-return / dynamic-receiver consumers stay
    on the escape valve by design.
  - *Slice 3* — the `FactProvider` naming + the machine-readable
    `rigor plugins --capabilities` catalogue (per plugin: node_rule node
    types, dynamic_return receivers, type_specifier methods,
    produced/consumed facts).
- **Read-before-write nil gate.** `additional_initializers:`
  ([ADR-38](../adr/38-additional-initializers.md)) lets a plugin
  extend `ScopeIndexer`'s `initialize`-only ivar-seeding gate to
  framework lifecycle methods (`setup`, `after_initialize`, DI
  setters) so an ivar set there and read in a sibling method is not
  widened with `nil`.
- **Target-library invocation** ([ADR-39](../adr/39-plugin-target-library-invocation.md), Accepted).
  Plugins may invoke a trusted target library's pure, allow-listed
  methods directly (`Plugin::Inflector` over the real
  `ActiveSupport::Inflector`; the Rails-family + factorybot consumers
  migrated off their hand-rolled inflection), under a selectable
  isolation strategy (`Plugin::Isolation`: `process` default / `none` /
  `ruby_box`; documented above). The boilerplate-plan author helpers
  `Base.suggest` (§ 0c) and the inflector close the remaining
  hand-rolled-duplication items.
