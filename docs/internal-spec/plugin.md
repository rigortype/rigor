# Plugin Registration and Loading

Status: **Normative.** Pins the public surface plugin authors
interact with for *registering* a plugin, declaring its *manifest*,
being *loaded* by `Analysis::Runner`, and contributing through the
ADR-37 narrow protocols. The founding-era contribution protocols
(dynamic-return, type-specifying, dynamic reflection) all landed
across the `0.1.x` cycle; `dynamic_return` / `narrowing_facts` are
specified below, and `flow_contribution_for` was removed in ADR-52
WD3.

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
and a frozen copy of the user's config, with the manifest's declared
defaults merged **under** it (see _Declared config defaults_ below).
`#init(services)` is the override hook plugins use to wire up state
from the service container; the default implementation is a no-op.

The full `Base` surface is declared in RBS
([`sig/rigor/plugin/base.rbs`](../../sig/rigor/plugin/base.rbs)) and is
**self-checked**: the bundled plugin / example lib trees run through
`rigor check` (the `make check-plugins` gate, chained into `make verify`
and CI). Combined with [ADR-43](../adr/43-rbs-complete-ancestor-resolution.md)
RBS-complete-ancestor resolution — which resolves a plugin subclass's
inherited contract calls (`manifest.…`, `io_boundary.…`) against the
`Base` RBS — a plugin that misuses the contract surface (calls a method
the contract does not declare, or a renamed helper) fails the build with
`call.undefined-method`. A complementary structural spec
([`spec/integration/plugin_contract_conformance_spec.rb`](../../spec/integration/plugin_contract_conformance_spec.rb))
covers the other half: every hook override (`init` / `prepare` /
`diagnostics_for_file`) MUST stay callable with
the engine's invocation — a narrowing override that drops a parameter the
engine supplies fails (param/arity Liskov-compatibility, ADR-5).

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
rule, so the plugin author writes the check and never the traversal.
The walk yields a `Prism::DefinedNode` itself but does not descend into
its operand (issue #318): `defined?` inspects its argument statically
and never evaluates it, so a rule never sees the nodes underneath one,
same as any other node this per-file walk reaches — this is what lets a
plugin drop the hand-rolled `def walk` / `compact_child_nodes.each`
recursion. The block runs through
`instance_exec` (so `self` is the plugin instance — `config`,
`services`, `services.fact_store`, `diagnostic` are all in scope),
receives `(node, scope, path, file_context, context)`, and returns an
`Array<Rigor::Analysis::Diagnostic>` (empty to fire nothing).
`node_type` MUST be a `Prism::Node` subclass. Multiple rules per type
run in declaration order. The engine dispatches them through one
shared per-run walk, `Plugin::Registry#node_rule_walk`
([`NodeRuleWalk`](../../lib/rigor/plugin/node_rule_walk.rb), ADR-52
WD4): a single traversal per file serves every node-rule plugin, and
the runner merges each plugin's bucket with its
`#diagnostics_for_file` result under the same `plugin.<id>` stamping
and per-plugin exception isolation; a plugin that declares no rules
pays zero cost. The instance method
`#node_rule_diagnostics(path:, scope:, root:)` remains on `Base` as
the equivalent single-plugin entry point (drift-pinned, used by
plugin specs), but the engine no longer routes through it.

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

`#diagnostics_for(violations, path:, node: nil)` (ADR-60 WD4) maps a
plugin's own violation objects onto `Diagnostic`s through `#diagnostic`,
absorbing the `violations.map { |v| diagnostic(node, …) }` block the
node-rule plugins otherwise repeat. Each violation duck-types `#message`
(required) plus optional `#node` (the Prism node to position at — falls
back to the `node:` argument), `#location`, `#severity` (defaults
`:error`), and `#rule`. Returns an Array suitable for direct return from
`#diagnostics_for_file` / a `node_rule` block.

`#read_fact(plugin_id:, name:)` (ADR-60 WD4) reads a cross-plugin fact
(ADR-9) another plugin's `#prepare` published, memoised per `(plugin_id,
name)` on the instance **including a nil result**. The nil-inclusive
memo retires the hand-rolled `@x_resolved` flag discovery plugins carried
to distinguish "fact not published" from "not yet read"; a fact no loaded
producer published reads as `nil`. (`#producer_value` / `#producer_error`
— the cache-producer twins of these helpers — are spec'd in
[`plugin-cache-producers.md`](plugin-cache-producers.md).)

`#prepare(services)` (ADR-9) is the project-wide pre-pass hook,
invoked once per plugin instance before that instance's per-file
analysis begins (see § _Concurrency and value-object shareability_).
Plugins that publish cross-plugin facts (`manifest(produces:)`)
override it to walk the project and call
`services.fact_store.publish(...)`; the loader's
topological ordering guarantees a producer's `prepare` runs before
any consumer's. The default is a no-op.

#### Contributing reachability roots — the `:reachability_roots` fact ([ADR-102](../adr/102-unused-code-reachability-report.md) WD3)

`:reachability_roots` is a **reserved fact name**: the core reads it
from every loaded plugin, so it is the one fact whose consumer is
Rigor itself rather than another plugin.

A plugin declares `produces: [:reachability_roots]` and publishes an
`Array<String>` of fully-qualified constant names from `#prepare`:

```ruby
manifest(id: "rails-routes", version: "0.29.0",
         produces: %i[helper_table reachability_roots])

def prepare(services)
  services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots,
                              value: ["Admin::UsersController", "HomeController"])
end
```

`rigor unused` ([ADR-102](../adr/102-unused-code-reachability-report.md))
loads the project's plugins, runs every `#prepare`, and seeds its
mark-and-sweep with the union of these facts. Entries that are not
shaped like a constant path are dropped; a leading `::` is stripped.
Publishing nothing (or omitting the fact entirely) is how a plugin
says it contributes no roots.

Three contract points, in order of how expensive they are to get wrong:

1. **Under-supply beats over-supply.** A root naming a constant the
   project does not declare is inert. A root claiming one it does not
   really reach silently hides real dead code, and there is no
   downstream signal that it happened. When a route target is not
   statically readable — `to: redirect(...)`, an interpolated
   controller name — publish nothing rather than a guess.
2. **The value is data, not objects.** It crosses the same fact store
   worker sessions rebuild per process; keep it to Strings.
3. **Roots are for entry points, not for "probably used".** The fact
   answers "something outside the analysed code calls this by name",
   which is why route tables, DI wiring and registration DSLs qualify
   and a heuristic does not.

`rigor unused` reports how many supplied roots matched no declaration
so a contribution can be corpus-checked on a real project.

#### Contributing reachability references — the `:reachability_references` fact (WD3 / WD8)

`:reachability_references` is the second reserved fact name, and the
sibling of the one above. It answers a different question: not "what
does the framework call from outside?" but "what does this file name
that the constant scan cannot see?".

A plugin declares `produces: [:reachability_references]` and publishes
an `Array<Hash>` of `{name:, role:}` from `#prepare`:

```ruby
manifest(id: "factorybot", version: "0.3.0",
         produces: [:reachability_references])

def prepare(services)
  services.fact_store.publish(plugin_id: manifest.id, name: :reachability_references,
                              value: [{ name: "Admin::User", role: :test }])
end
```

`name` is validated exactly as a root is. `role` MUST be one of
`:production`, `:test`, `:task`, `:config` — the roles
`Reachability::Scan.role_for` assigns a file (WD8). An unrecognised
role drops the entry rather than defaulting to `:production`:
defaulting would silently promote a test-tree reference, which is the
one outcome WD8 exists to prevent. String keys and String roles are
accepted, so a value round-tripped through a cache slot still arrives.

The entry enters the graph as a file-level reference carrying that
role, **not** as a root. Choose between the two facts by asking who
does the naming:

| Who names the class | Fact |
| --- | --- |
| The framework, from outside the analysed code | `:reachability_roots` |
| The code itself, but not as a constant node | `:reachability_references` |

`rigor-factorybot` is the motivating case for the second row.
`factory :user, class: "Admin::User"` names a class as a string, and a
bare `factory :user` is FactoryBot's own constantization of the factory
name — neither leaves a constant node anywhere. But factories live in
the test tree, so publishing them as roots would make every factoried
class production-reachable and erase WD8's "reachable only from tests"
answer for exactly the classes it is most likely to be about. The role
keeps the finding.

Both facts are optional and fail-soft in the same way: a plugin that
raises in `#prepare`, or publishes junk, loses its own contribution and
nothing else.

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
consistently for both node kinds. Alongside the grid,
`.symbol_named?(node, name)` is the predicate form — true when `node`
is a `SymbolNode` whose `#unescaped` equals the `String` `name`,
false for any other node — for the "is this argument exactly
`:draft`?" test that would otherwise compare a `.symbol(node)`
result. Like the `SymbolNode`-only grid column, it does **not** match
a `"draft"` string literal.

Two call-argument helpers sit on top of the grid:

- `.symbol_arguments(call_node)` → `Array[Symbol]` — every literal
  Symbol/String positional argument in source order; non-literal
  arguments are dropped; `[]` when the call has no argument list.
- `.symbol_arg(call_node, index)` → `Symbol?` — the literal at
  positional `index`, or `nil` when the call has no argument list, the
  index is out of range, or that argument is not a literal
  Symbol/String.

#### Return-type and narrowing contributions — `dynamic_return` / `narrowing_facts` (ADR-37 Slice 2)

`flow_contribution_for` was consulted at exactly two engine sites, each
reading exactly one slot of the returned bundle: `MethodDispatcher`
reads `.return_type` (the per-call-site return type) and
`StatementEvaluator` reads `.post_return_facts` (assertion-edge
narrowing). ADR-37 Slice 2 splits those two consumption sites into two
narrow, declaratively-gated class DSLs — the `producer`-style shape, so
the block carries logic and runs through `instance_exec`:

- `dynamic_return(receivers:, methods:, file_methods:) { |call_node,
  scope| Type | nil }` — the per-call-site **return type**, gated on the
  receiver's class, the method name, or both (at least one gate is
  REQUIRED — a rule gated on neither would fire on every dispatch, which
  `dynamic_return` rejects at load). With `receivers:` (a non-empty
  `Array` of class names, or a `-> { … }` callable resolved once per run
  after `#prepare`, ADR-52 slice 3) the engine calls the block only when
  the call's receiver type's class equals or inherits from a declared
  entry (matched via `Environment#class_ordering`). `methods:` (an
  `Array` of Symbol/String names, or a run-time callable, ADR-52 slice 4)
  gates on `call_node.name`; `file_methods:` (a callable receiving the
  path, memoised per `(rule, path)`, ADR-52 slice 5a) is its per-file
  specialisation for a name set that varies by analysed file
  (rigor-rspec's `let` names) and replaces `methods:`. First non-`nil`
  wins. The engine invokes it through `#dynamic_return_type(call_node:,
  scope:, receiver_type:)`. `rigor-mangrove` (unwrap → carried
  `type_args[0]`) is the worked consumer.
  - **Binary operators are ordinary calls here.** Ruby's `a + b` parses
    to a `Prism::CallNode` named `:+`, so it reaches this hook like any
    other call: a `dynamic_return(receivers: ["Money"])` rule can branch
    on `call_node.name ∈ {:+, :-, :*, :/, :<=>, …}` and return the
    operator's result type — Rigor's equivalent of PHPStan's
    `OperatorTypeSpecifyingExtension` for the self / left-operand case,
    with no operator-specific extension point. Confirmed by
    `spec/integration/plugin_operator_dynamic_return_spec.rb`. **Caveat
    (coerce direction):** the gate is on the *receiver* class, and Ruby
    dispatches `1 + money` on `Integer`, so a `["Money"]` rule does not
    fire there; that result types left-biased as `Integer` (see ADR-42).
  - **A `dynamic_return` answer suppresses `call.undefined-method` at
    that call site** (issue #653). The tier sits above `RbsDispatch` in
    `MethodDispatcher#resolve`, so when a plugin answers, the receiver's
    RBS never dispatched the call and the type at the site is the
    plugin's; the existence check MUST NOT then read that same RBS to
    prove the call undefined. The dispatcher records each answered call
    node on `Scope#plugin_typed_calls` during the typing pass and
    `Analysis::CheckRules` consults the record — it never re-runs a
    plugin block to decide a diagnostic. The suppression is **per call
    site, not per receiver class**: it is narrower than the
    `open_receivers:` exemption below, and a name neither the RBS nor
    any plugin answers still reports on the same receiver.
    - The precedence is **unconditional on what the RBS says**, not
      "only where the RBS is silent": it restates the dispatcher's own
      tier order, and the dispatcher does not consult the RBS before
      letting a plugin answer. Plugins that answer a method their
      coexisting RBS also declares are ordinary and shipping —
      `rigor-activesupport-core-ext`'s `%i[+ - *]` rule deliberately
      overrides the *fully declared* core `Time#-` / `Integer#*`
      signatures because the RBS-projected return is wrong once a
      `Duration` is the operand, and `rigor-dry-validation` refines a
      `to_h` its own bundled `sig/` declares. For this rule the two
      readings coincide anyway — a method the RBS declares resolves and
      never reaches the diagnostic.
    - The two rules that read a RESOLVED SIGNATURE (`call.wrong-arity`,
      `call.argument-type-mismatch`) are **not** covered by this record
      today; they still validate against the RBS signature at a
      plugin-answered site. See issue #653's follow-up note.
- `narrowing_facts(methods:) { |call_node, scope| facts | nil }` —
  **post-return narrowing facts**, gated on `call_node.name` being in
  the declared `methods:`. The engine invokes it through
  `#narrowing_facts_for(call_node:, scope:)`. `rigor-minitest`
  (assertion narrowing) and `rigor-rspec`'s matcher narrowing are the
  worked consumers. Renamed from `type_specifier`
  ([ADR-80](../adr/80-narrowing-facts-rename.md)); the old verb was a
  deprecating alias through `0.2.x` and is gone in 0.3.0, together with
  the reader (`type_specifiers`), the engine consumer
  (`#type_specifier_facts`), and the capability key
  (`type_specifier_methods`) it left behind.

`receivers:` / `methods:` are the greppable, indexable gates the
`rigor plugins --capabilities` catalogue (ADR-37 § "Machine-readable
capability catalogue") enumerates.

**`#flow_contribution_for` was removed in ADR-52 WD3 (2026-06-11).** A
plugin that still defines the hook raises `ArgumentError` at load time.
All five production users migrated to `dynamic_return` / `narrowing_facts`
(see CHANGELOG `### Removed` for the full migration table). The
historical role it played — an ungated per-call fat hook returning a
`FlowContribution` bundle — is now expressed through the narrow,
compiled-dispatch DSL forms described above.

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
      "narrowing_facts_methods": ["<method name>", "..."],
      "produces": ["<fact id>", "..."],
      "consumes": ["<plugin_id/fact_name>", "..."]
    }
  ]
}
```

The five capability arrays are exactly the declarative gates of the
narrow protocols above: `node_rule_types` from each `node_rule` node
type, `dynamic_return_receivers` from `dynamic_return(receivers:)`,
`narrowing_facts_methods` from `narrowing_facts(methods:)`, and
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
  `camelize` / `singularize` / `pluralize` / `classify` delegate to
  the real `ActiveSupport::Inflector` (the fixed `ALLOWED_METHODS`
  allow-list); `tableize` is deliberately **not** delegated — AS's own
  `tableize("Admin::User")` returns the slash-separated `"admin/users"`,
  never a valid SQL identifier, so `.tableize` composes the AS-backed
  `underscore` / `pluralize` with a `::` → `_` flatten instead. That
  flatten is **not** ActiveRecord's real table-name computation for a
  namespaced model, though — AR demodulizes (drops the enclosing module
  entirely) and applies a `table_name_prefix` / `table_name_suffix` only
  when the enclosing module declares one, so `Admin::User` reads
  `users`, not `admin_users`, unless `Admin` sets a prefix. Its sole
  caller, `rigor-activerecord`'s `ModelIndex.inflected_table_name`,
  demodulizes a namespaced model's class name before calling `tableize`,
  so it never actually passes `tableize` a namespaced one. It carries
  **no approximation** (raises when the gem is unreachable, so the
  caller declines to silence). `rigor-rails-routes` /
  `rigor-activerecord` / `rigor-actionpack` / `rigor-actionmailer` /
  `rigor-factorybot` use it.
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
| `open_receivers` | `Array<String>` | Receiver class names whose method surface is unbounded — e.g. `ActiveRecord::Relation`, which delegates every user-declared `scope` to its model (ADR-26). Such a class is exempted from `call.undefined-method` outright, and from the two signature-reading rules (`call.wrong-arity`, `call.argument-type-mismatch`) for any method name it INHERITED rather than declared: a delegated name that collides with an ancestor's (`relation.open` → `Kernel#open`) resolves to a signature the call does not run. A method the open class declares itself keeps both checks; a method it genuinely has through an ancestor (`Enumerable` on a Relation) loses them too — the test is the definition site, not delegation. This field only takes effect once a project loads the declaring plugin. Two OTHER, plugin-independent sources feed the same `CheckRules#unbounded_receiver_surface?` gate: `RbsLoader#synthesized_type_names` stub types, and (issue #632, tracked further by #660) `CheckRules::GEM_OVERLAY_OPEN_RECEIVERS` — a plain constant, not a manifest field, for a class Rigor's own BUNDLED gem-overlay RBS (`data/gem_overlay/`, ADR-72) declares knowing the declaration is partial. An auto-applied overlay has no plugin manifest for an `open_receivers:` entry to live on, so a receiver it declares open (`ActiveSupport::Duration`, which forwards undeclared members to the wrapped numeric via `method_missing`) needs protection independent of whether any plugin is loaded at all; `rigor-activesupport-core-ext` ALSO lists the same class under its own `open_receivers:`, so the two sources overlap there by design — either alone is sufficient, and the constant is what covers the overlay-only case the manifest field structurally cannot reach. Membership in that constant is NOT itself sufficient, though: `CheckRules#gem_overlay_loaded?` additionally requires the bundled overlay directory that motivated the entry to have actually loaded THIS run (`RbsLoader#signature_paths` including one under `RbsLoader.under_gem_overlay_root?`) — otherwise a project that never locks the gem, and happens to own a class of the same qualified name itself, would silently lose `call.undefined-method` coverage on it. This restores the same "the protection is active exactly when the RBS is" property `open_receivers:` gets for free from requiring the declaring plugin to be loaded (ADR-26 WD1). |
| `type_node_resolvers` | `Array` | `Plugin::TypeNodeResolver` entries contributing custom RBS type-name resolution (ADR-13). |
| `protocol_contracts` | `Array<ProtocolContract>` | Path-scoped behavioural contracts (`path_glob` + `method_name` + `singleton` + param/return types + severity); provide-and-check (ADR-28). |
| `source_rbs_synthesizer` | `#call(path) -> String?` | A callable that synthesises RBS from a project source file at env-build time (e.g. rbs-inline ingestion) (ADR-32). |
| `block_as_methods`, `heredoc_templates`, `trait_registries` | `Array<Plugin::Macro::*>` | The ADR-16 macro / DSL expansion substrate tiers (A / C / B; the never-wired Tier D `external_files:` was removed by ADR-60 WD1). Value-object shapes spec'd in [`macro-substrate.md`](macro-substrate.md). |
| `nested_class_templates` | `Array<Plugin::Macro::NestedClassTemplate>` | Nested-subclass emission from an enum-shaped block DSL (`variant <Const>, <Type>`); the macro-substrate tier that mints classes, not just methods (ADR-36). Spec'd in [`macro-substrate.md`](macro-substrate.md). |
| `hkt_registrations`, `hkt_definitions` | `Array` | Lightweight-HKT type-function registrations (ADR-20). |
| `additional_initializers` | `Array<AdditionalInitializer>` | `{ receiver_constraint:, methods:, block_methods: }` entries declaring which non-`initialize` methods on a class (and its subclasses) also establish ivar state — `methods:` for `def`-form (`def setup`), `block_methods:` for call-with-block form (`before { … }`, `let(:x) { … }`); at least one must be non-empty. Feeds `ScopeIndexer`'s read-before-write nil soundness gate (ADR-38). |
| `effect_root` | `String?` matching `/\A[a-z][a-z0-9_]*\z/` | The effect-label root this plugin asks to open ([ADR-103](../adr/103-effect-labels.md) WD2). Granted only to a first-party bundled plugin; see _Effect contributions_ below. |
| `effect_labels` | `Array<String>` | Effect labels this plugin registers into the run's vocabulary (ADR-103 WD2). |
| `effect_attributions` | `Array<EffectAttribution>` | What a call into the framework this plugin models does (ADR-103 WD6 / WD10). |
| `effect_edges` | `Array<EffectEdge>` | Framework call-graph edges the syntax does not contain — callbacks, `perform_now`, mailer bodies (ADR-103 WD10). |
| `effect_entry_points` | `Array<EffectEntryPoints>` | Named `effects.snapshot.reach:` presets (ADR-103 WD14). |
| `effect_ancestry` | `Array<EffectAncestry>` | Ancestry edges this plugin's own gem introduces and the project's source never writes (ADR-103 WD17). Bundled plugins only; see _Discharge and first-party standing_ below. |

`#validate_config(config)` returns an array of error strings; the
loader converts a non-empty result into a `LoadError`. Each extension
field carries its own validation in `Manifest#initialize`.

#### Effect contributions — `effect_root` / `effect_labels` / `effect_attributions` / `effect_edges` / `effect_entry_points` / `effect_ancestry` ([ADR-103](../adr/103-effect-labels.md), issue #387)

**Status: normative as of #387.** A plugin that models a framework knows things about effects that no
amount of reading the application's source can recover: that `save` runs the class body's callbacks,
that `perform_later` is a Redis write under Sidekiq and a database write under Solid Queue, that
`Rails.env` is mutable process state. These five fields are how it says so.

Everything a plugin declares here is **declarative and frozen**: value objects over Strings and Symbols,
Marshal-clean, compiled once per process into `Rigor::Effects::PluginFacts`. No plugin code runs inside
the effect scan — ADR-103 WD13 forbids anything there that resolves, walks or types, and a callback
would not survive the fork-pool boundary the collection window crosses either.

##### Cost when effects are off

Zero beyond the manifest allocation. `Plugin::Registry#effect_contributions` is **lazy** — the one
aggregate that is, because a plugin MAY compute its rows from project facts (rigor-activejob reads
`config.active_job.queue_adapter`, which is an `IoBoundary` read) — and nothing calls it unless the
project has an `effects:` block. `rigor check` without one is byte-identical and opens no extra file.

##### Which channel a row belongs in

A plugin has two ways to colour a framework method, and the choice is not a matter of taste:

| The plugin… | Channel | Why |
| --- | --- | --- |
| already ships an RBS signature for the method | `%a{rigor:v1:effect …}` / `%a{pure}` in `signature_paths:` | Tier 1. The annotation rides the **accepted signature** stratum, which ADR-103 WD6 already trusts for types; the bound is imported at the call site by `Effects::EnvelopeIndex` and discharges. rigor-activerecord's `sig/active_record/relation.rbs` is the worked example — the builder / materializer split lives there because the file already draws it. |
| does not, or cannot name the method per app | `effect_attributions:` | Association readers, `find_by_*`, scopes and the `Enumerable` delegations on a Relation are either per-project or would change how the method **types** if declared. So is any class the plugin ships no signature for at all. |

A row must never be in both: two channels on one method produce two origins for one fact, which reads as
duplication in `rigor effects explain`.

##### `EffectAttribution`

`Rigor::Plugin::EffectAttribution.new(receiver:, method:, labels:, why:, singleton: false, narrow: nil,
discharge: false, within: nil, on_result: false, taint: nil)`.

`why:` is **required and non-empty**, exactly as every row of `data/effects/core.yml` requires one: a
label with no stated reason is a claim nobody can review.

`receiver:` is spelled one of three ways, and the spelling picks the matching rule:

| Spelling | Example | Matches |
| --- | --- | --- |
| class name | `"ActiveRecord::Base"` | The class the receiver projects to, **through the project's own `class … <` lines**. One row reaches every model in the app. |
| receiver path | `"Rails.cache"` | The receiver *expression* as written. `Rails.cache` returns whatever `config.cache_store` names, so there is no class to key on. |
| self path | `"self.session"` | The same, rooted at implicit self. MUST carry `within:` — a receiver-less `session` in an unrelated project class is a different `session`. |

`on_result: true` shifts a class-name row one link outwards: it matches a call on **what a call to that
class returned**. `UserMailer.welcome(u).deliver_now` and `WelcomeJob.set(wait: 1.hour).perform_later`
are the two idioms that need it — the object in the middle is a lazy `MessageDelivery` / `ConfiguredJob`
that nothing declares a type for, while the class that produced it is written right there.

The inheritance walk reads the cross-file discovery pre-pass's `discovered_superclasses` — the project's
own declarations, and deliberately **not** the RBS ancestor chain. Reading RBS would make a row's reach a
function of whether the project happens to run `rbs prototype`, so a contribution would appear and
disappear with an unrelated tool. A project whose models are declared only in RBS gets no plugin
attribution and no taint, which is the fail-quiet direction.

`narrow:` names a `Rigor::Effects::Narrowing` handler, so the call's own argument literals can settle a
question the row cannot: `connection.execute("UPDATE …")` is a write and `execute(sql)` keeps `io.db`.

`taint:` lets a row state a bound AND say the bound is not the whole story. It is restricted to
`template-not-analysed` and `opaque-callable` — the only two things a framework model can honestly not
see. `render` is the case: what the controller does is fully stated, and what the template does is
unknown until views are effect units.

##### Discharge and first-party standing

ADR-103 WD6 grants two things to a **first-party bundled** plugin and to nothing else:

- it may open the effect-label root of the framework it models (`rails.*`, not `activerecord.*`);
- its attributions may carry `discharge: true`, which makes the call site **exhaustive** rather than
  tainted — the same standing an accepted signature's `%a{…}` has, and for the same reason: the
  contribution is versioned with the engine, reviewed in this repository, and gated by
  `make check-plugins`;
- its `effect_ancestry:` claims are honoured ([#465](https://github.com/rigortype/rigor/issues/465)).
  A claim carries no labels, which is what makes it look like the harmless one of the three: what it
  does is make **other** plugins' rows reachable, so a third-party plugin asserting
  `Foo < ActiveRecord::Base` would pull rigor-activerecord's first-party discharging rows onto `Foo`.
  A refused claim is warned about rather than dropped in silence, on the same reasoning as the
  `effect_root:` demotion — an author whose claim vanished would read it as the rows having vanished.

An `EffectAncestry` is `{ child:, parent:, why: }`, and `parent:` need only be a **true** ancestor
rather than the immediate superclass. The ancestry's only use is to make a row reachable, and no plugin
row is ever keyed on a project class, so skipping intermediate links loses nothing — while insisting on
the immediate parent would force a claim a project can falsify: `Devise::SessionsController`'s real
parent is `DeviseController`, whose own parent is `Devise.parent_controller`, which an application may
configure. A claim that skips links says so in its `why:`.

"First-party" is **derived, never listed**: `Rigor::Plugin::FirstParty.bundled?(id)` asks whether the
engine bundles `rigor-<id>`, which is the same question `Loader.bundled_plugin_path` already answers when
it decides how to require a plugin. A list would be a second source of truth to keep in sync with
`plugins/`, and the first drift would silently demote a plugin's rows.

A third-party plugin's overreach is **accepted in part, never fatal**: its `effect_root:` is ignored and
its labels open the root named after its plugin id; its `discharge: true` is ignored and its rows behave
like the project's own `effects.attribution:` table — declared, carrying a `plugin-attribution` taint.
Both demotions are recorded on `PluginFacts#warnings` and surfaced by `rigor effects`. They are **not**
diagnostics: a plugin the user chose is not the project's mistake to be flagged for. A label whose root
neither exists nor belongs to the extender is refused outright (`Registry::OwnershipError`), and only
that plugin's labels drop — one plugin overreaching must not un-name another's vocabulary.

Either way the labels land in the **declared** lane, never the proven one. A discharging row is a trusted
claim, not a proof: "this is what it does", not "the analyzer read the body and saw this".

##### `EffectEdge`

`Rigor::Plugin::EffectEdge.new(receiver:, target:, why:, method: nil, singleton: false)`. `target:` is a
**closed enum** the engine implements; the plugin supplies parameters only.

| `target:` | What the engine does |
| --- | --- |
| `:activerecord_callbacks` | On every project class whose ancestry reaches `receiver:`, reads the class body's callback and validation macros (`before_save :sym`, `validate :sym`, `after_commit :sym`, …) and synthesises the persistence selectors (`save`, `create!`, `destroy`, `valid?`, …) as effect units edged to those methods. `validates … uniqueness: true` additionally contributes an `io.db.read` origin. |
| `:perform_now` | `Job.perform_now(…)` on a project subclass of `receiver:` reaches `Job#perform`. `method:` names the synthesised selector, defaulting to `perform_now`. |
| `:mailer_body` | `UserMailer.welcome(u)` on a project subclass of `receiver:` reaches `UserMailer#welcome`. |

The edges materialise as **synthetic effect units on the framework class itself** (`Rigor::Effects::
FrameworkUnits`), not as edges at the call site: the call site is in another file, and the callbacks are
in the model's. The propagator then resolves an ordinary `(User, :instance, "save")` edge to the
synthetic unit exactly as it resolves any other, ancestry and closed-world override join included.

A synthesised unit stands for the whole selector, so it also carries whatever the plugin's own
`effect_attributions:` say about that `(class, singleton, selector)` — a plugin that rows
`ActiveRecord::Base#save` as `io.db.write` gets that write on `User#save`, not only at `user.save`. See
[the effect-summaries spec](effect-summaries.md) for the normative rule, including the one exemption
for a class body that replaces the selector without reaching `super`.

The enum has **no spelling for `perform_later` → `perform`**, and that absence is the enforcement of
ADR-103 WD4: the deferred body runs in another process on another stack, so the caller's code does not
contain it. The one exception is licensed by the project rather than by the plugin — under a declared
`queue_adapter = :inline` Rails really does run the job on the caller's stack, and rigor-activejob emits
`target: :perform_now, method: :perform_later` only after reading that declaration.

##### `EffectEntryPoints`

`Rigor::Plugin::EffectEntryPoints.new(name:, globs:, why: "")`. Registered into
`Rigor::Effects::EntryPoints` when `PluginFacts` is compiled, and adopted by name in
`effects.snapshot.reach:`.

Because a preset is named by a plugin and plugins load **from** the configuration being validated,
`Configuration` checks only that a `reach:` entry is *shaped* like a preset name; the existence check
runs in `Effects::Snapshot.expand_reach`, which is the first point at which the registered set is
complete. A name registered twice with different globs is a genuine conflict and raises; the same name
with the same globs is a no-op, so two runs in one process do not collide.

##### Cache identity

`PluginFacts#digest` — a content digest of every compiled label, attribution, edge and preset, each with
the plugin that contributed it — joins `Effects::Identity`. A plugin upgrade that moves a row therefore
invalidates the effects cache slot exactly as a re-audited `data/effects/core.yml` row does. The digest
is deliberately independent of the project's superclass table, which is a project input the diagnostics
identity already covers.

The `--incremental` snapshot's own effects identity is deliberately plugin-**blind**: its two sides sit
on opposite sides of the run (the restore asks before any plugin is loaded, the save after), so folding
the plugin facts in would compare a blind digest against a sighted one and miss every time. The bound
that leaves — a plugin upgrade does not invalidate an `--incremental` snapshot's effect collections — is
recorded in [`effect-summaries.md`](effect-summaries.md); the primary whole-run path has no such hole.

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
| `fact_store` | `Rigor::Plugin::FactStore` (ADR-9 / v0.1.1) — the per-run cross-plugin fact store; `#prepare` publishes to it, `#diagnostics_for_file` / `dynamic_return` blocks read from it. |

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
or plugin id), `cause_class` (the underlying exception class,
when applicable), and `resolved_path` (the file the plugin gem
loaded from, stamped by the loader when the `require` succeeded
but a later configuration / instantiation step failed; nil for a
`require` that failed outright). The runner converts each one into
a `Rigor::Analysis::Diagnostic` with `source_family:
:plugin_loader` and `rule: "load-error"`.

## Internal surfaces (NOT public)

- `Rigor::Plugin::Loader` — the loader is internal infrastructure.
  Plugin authors should not subclass or depend on its private
  helpers; the public entry point is `Loader.load(configuration:,
  services:, requirer:, feature_resolver:)` (the last two default to
  a plain `require` and the bundled feature resolver; the specs pass
  their own).

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
  - gem: rigor-rbs-inline
    enabled: false                      # opts the entry out entirely (ADR-93 WD3)
```

`Configuration` normalises every entry to one of those two shapes
and exposes them via `Configuration#plugins`. A fourth key,
`enabled:`, defaults to `true`; only an explicit `false` disables —
the loader skips the entry without requiring the gem. It is the
project-level opt-out for the auto-wired `rigor-rbs-inline` default,
but it works for any entry.

## Load order

The loader processes `.rigor.yml` `plugins:` entries in the order
the user wrote them. For an entry that resolves to multiple
registered plugin classes (one gem registering > 1 plugin), the
explicit `id:` field disambiguates; without it the loader emits a
`LoadError` rather than guessing. Duplicate ids across entries are
an error, not a silent dedupe.

## Bundled-plugin resolution ([ADR-93](../adr/93-default-rbs-inline-ingestion.md) WD5)

An entry whose `gem` names a plugin the engine itself bundles —
`<engine root>/plugins/<gem>/lib/<gem>.rb` exists, the engine root
anchored from the loader's own location — is `require`d **by that
absolute path**, not by gem name. The engine and its bundled
plugins are versioned together, so name resolution against
whichever installation's `require_paths` happens to win is
skew-prone by definition: a stale installed `rigortype` gem could
otherwise displace the engine's own copy silently (the [#194][i194]
hazard). Anchoring loads the engine's own vendored file instead.
When the anchored file does **not** exist — a trimmed packaging,
the [ADR-27](../adr/27-tool-distribution-model.md) single-binary
target — the loader falls back to the bare gem-name `require`, so no
install mode regresses. The rule is uniform across the auto-wired
`rigor-rbs-inline` default and every user-listed entry. There is no
name-level escape hatch back to gem resolution; an external copy
would earn an explicit per-entry `path:` key
([ADR-99](../adr/99-config-schema-authority.md)), not a silent name
race. `rigor doctor` flags any bundled plugin that still resolved
outside the engine tree — the guard for the fallback path and
genuinely mixed installations that anchoring cannot see.

[i194]: https://github.com/rigortype/rigor/issues/194

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
  kind), suffixed with ` (loaded from <path>)` when the `require`
  succeeded but a later step failed — so a config/init failure
  names the exact plugin copy it loaded from; a `require` that
  failed outright has no resolved path and the message is
  unchanged.

`rigor check` continues with the analysis; plugins that loaded
successfully still participate in the rest of the run.

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
  worker's lifetime. Each `WorkerSession` then runs
  `#prepare(services)` on its own materialised instances at
  construction, before its first `#analyze`, so `#prepare` is invoked
  once **per plugin instance** (the coordinator plus each worker),
  never once per run, and each worker's `fact_store` is rebuilt
  rather than shipped across the boundary. Mutable plugin state
  therefore never crosses a boundary; only the frozen Blueprint does.
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
  shipped in slice 3; the return-type contribution tier shipped
  in slice 4 (originally `#flow_contribution_for`, later split into
  `dynamic_return` / `narrowing_facts` per ADR-37, then
  `flow_contribution_for` was removed ADR-52 WD3) and was extended
  by the v0.1.1 cross-plugin work (ADR-9).
- **Plugin diagnostic provenance.** Slice 5 routes plugin-emitted
  diagnostics through `Diagnostic#source_family` with
  `plugin.<id>.<rule>` prefixes.
- **Plugin trust / I/O policy enforcement.** Slice 2 shipped the
  declarative {Rigor::Plugin::TrustPolicy} + {Rigor::Plugin::IoBoundary}
  surface; see [`plugin-trust.md`](plugin-trust.md).
- **Plugin-side cache producers.** Slice 6 wires
  `Store#fetch_or_validate` (ADR-60 WD3 record-and-validate) for plugins
  via `PluginEntry` descriptors; see
  [`plugin-cache-producers.md`](plugin-cache-producers.md).
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
  - *Slice 2* — `#flow_contribution_for` split into the receiver-gated
    `dynamic_return` + method-gated `narrowing_facts` DSLs (documented
    above); cleanly-fitting consumers migrated, remaining consumers
    stayed on the escape valve. **`flow_contribution_for` was then
    deleted in ADR-52 WD3 (2026-06-11)** — all five escape-valve
    consumers fully migrated before deletion.
  - *Slice 3* — the `FactProvider` naming + the machine-readable
    `rigor plugins --capabilities` catalogue (per plugin: node_rule node
    types, dynamic_return receivers, narrowing_facts methods,
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
