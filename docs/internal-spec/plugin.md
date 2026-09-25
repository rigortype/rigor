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

#### Project-global disclosures — `#disclose_once` ([#1051](https://github.com/rigortype/rigor/issues/1051))

`#disclose_once(key, message:, severity: :info, rule: "load-error")`
is the **run-scoped** emission channel: a notice about the run's
*inputs* rather than about a line of a file. The canonical case is a
degrade disclosure — "`db/schema.rb` is not there, so column checks
are off".

The method registers; it does not return a row. Plugin authors MAY
call it from any hook (`#prepare` is the usual place, because a
disclosure is normally a fact about the project known before a file is
read; `#diagnostics_for_file` and a `node_rule` block are also
allowed), and it returns `nil` in every case. The engine harvests the
registrations after analysis, **de-duplicates them by `(plugin id,
key)`**, and emits one row per surviving pair. `key` is any object with
a stable `#to_s`; it is never shown to the user, so it MUST NOT
interpolate anything that varies between plugin instances. The row is
stamped `source_family: "plugin.<manifest.id>"` like every other
plugin-emitted row.

**Two properties are binding.**

*Exactly once per run.* De-duplication happens on the parent, over the
union of the coordinator-side registry and every pool worker's table:
the pre-fork `WorkerSession`'s registrations (so anything registered
during `#prepare`), each fork child's `disclosures:` payload slot, and
each Ractor worker's `:done` message. A run therefore emits the same
multiset of disclosures under `--workers 0` and `--workers N`.

One exception, on the Ractor backend only (off by default, and
currently unable to complete a run at all — see
[#1055](https://github.com/rigortype/rigor/issues/1055)): when a
worker dies, `PoolCoordinator#reanalyze_degraded_in_process` re-runs
its slice on a bare environment with no `WorkerSession`, and `#prepare`
does not run on the coordinator-side registry under pool mode, so a
disclosure that worker registered from `#prepare` is lost with it. One
registered from `#diagnostics_for_file` survives, because the
re-analysis runs the coordinator-side plugin instances the harvest
reads. The fork backend has no such gap: its degrade re-analyses on
the parent session and drains it.

*Positioned at `.rigor.yml:1:1`.* Not at the first analysed file. A
disclosure has no source position it could be right about, and the
config file is where the user declared the input the notice is about —
the same position plugin load errors, `#prepare` raises and
`plugin_trust.read-refused` already use. Pinning it there also settles
the question #1051 raised: a project-global disclosure can never land
on a synthesised template unit's path (an `.erb`, [#393](https://github.com/rigortype/rigor/issues/393)),
where it would read as a claim about that view.

Moving an existing disclosure to this channel is therefore a
**baseline-visible** change: `Analysis::Baseline` buckets by `(file,
qualified_rule[, message])`, so an entry recorded at the row's old file
position stops matching and the row surfaces as new. The qualified rule
does not change, so `rigor baseline regenerate` is the whole migration
— but a plugin making this move owes its users a changelog and manual
note saying so, because a `:warning`-grade disclosure otherwise breaks
a `--fail-on=warning` CI on upgrade.

Emission order is `(registry position, key)` — the plugin load order
(topological by `consumes:`) and then the key string — **not**
registration order, which is a function of how the pool sliced the
file list.

The superseded idiom is a per-instance `@emitted` flag consulted from
`#diagnostics_for_file`. It is per plugin INSTANCE, and a fork-pool
worker has its own, so `--workers N` emitted up to N copies, each on
whichever file that worker happened to analyse first. Plugins that
still carry it are not silently fixed: the flag is theirs, and the
engine cannot tell a run-level row from a file-level one that happens
to repeat. Adopting `#disclose_once` is the migration.

The question that chooses the channel is whether the row has a
position it could be **right** about. "The index did not load" does
not — it goes here. A project-wide scan whose rows each name a real
file and line does, and must keep it — it goes to `#emit_once`, below.

#### Project-wide positioned batches — `#emit_once` ([#1060](https://github.com/rigortype/rigor/issues/1060))

`#emit_once(key, diagnostics)` is the positioned sibling of
`#disclose_once`: it registers a **batch** of fully built
`Rigor::Analysis::Diagnostic`s under `key` and emits it once per run,
with every row keeping the `path` / `line` / `column` the plugin gave
it. It exists for a project-wide scan whose rows name files that no
single analysed file owns — `rigor-rails-i18n`'s view-template scan is
the bundled case: the views are usually not analysed targets (an `.erb`
reaches the engine only as a template unit a `template_globs:` plugin
contributes), so there is no per-file return to anchor the rows to, and
returning them from whichever file an instance analysed first repeated
the batch once per fork-pool worker.

It rides the `#disclose_once` registration table, so everything above
about call sites, the `nil` return, the de-duplication sources, the
Ractor-degrade exception and emission order applies unchanged. `key`
shares one namespace per plugin with `#disclose_once`, but a key keeps
the kind it was first registered as: repeating it on the same channel
is a no-op, and reusing it on the other channel, in either order,
raises `ArgumentError` (reported through the `runtime-error` envelope)
instead of silently dropping one of the two registrations. The
differences are binding:

- *The rows keep their positions.* The engine stamps only
  `source_family: "plugin.<manifest.id>"`, the stamp a
  `#diagnostics_for_file` row gets, so the qualified rule and the file
  a baseline entry keys on are unchanged. Moving a batch from an
  `@emitted` flag to `#emit_once` is therefore **baseline-neutral** —
  unlike moving a row to `#disclose_once`.
- *De-duplication is by key alone, and the first registration wins
  whole.* A later batch under the same key — from this instance or any
  other worker's — is dropped entirely, never merged row by row: every
  worker scans the same project, so a row-wise union could only add a
  partial or divergent view.
- *The batch is stamped into the file-positioned stream,* immediately
  after the per-file rows and before the run-level block the
  disclosures sit in; order is `(registry position, key)`, then the
  batch's own row order, identically under `--workers 0` and
  `--workers N`. It is not part of the per-file stream the incremental
  cache stores for any one file.
- *Rows carry source positions; the engine does not relocate them.* A
  batch bypasses the template-unit line remap, so each row MUST name
  the position in the file the user edits (the template's own line,
  or `1:1`). A row built from a line of a unit's compiled Ruby is
  emitted at that compiled line, unrelocated.

A batch is re-registered only by a run that reaches the registering
hook. A narrowed `--incremental` recheck that analyses no file calls
no plugin, so it does not replay a batch registered from
`#diagnostics_for_file` — the same as a disclosure.

Each row is copied and frozen on registration (Marshal- and
Ractor-clean). A non-`Diagnostic` element raises `ArgumentError`,
reported through the usual `runtime-error` isolation envelope.

#### Template units — `template_globs:` / `#template_units_for_file` ([#392](https://github.com/rigortype/rigor/issues/392))

`#template_units_for_file(path:, source:)` is the **source transform** half of the revived ADR-16 Tier-D
seam: a plugin that declared `template_globs:` is offered each matched file's bytes and returns an
`Array<Rigor::Plugin::TemplateUnit>` — the compiled Ruby plus the line map, the declared `self`, the render
site's locals and the rendering action's ivar seeds. The default returns `[]`, so a plugin that declares no
globs is never asked and one that does may still decline a file it cannot read.

A returned unit MUST name the file it was offered (`unit.path == path`). A unit naming anything else is
refused: without the check a `path:` naming another project file silently **replaced** that file's source
(the engine serves a unit's bytes for its own path), and a `path:` naming something outside the project
root was analysed with no dependency-descriptor row — both from one wrong string.

A transform that **raises**, a template that cannot be **read**, and a unit naming the **wrong path** are
each reported as one `:plugin_loader` `runtime-error` diagnostic positioned at the template file — the
same isolation envelope a raise from `#diagnostics_for_file` produces (ADR-2 § "Plugin Trust and I/O
Policy"). The file contributes no unit, the run continues, and the plugin author has something to read.

Three properties make it safe to add to the contract at this point in the freeze:

- **It runs once, on the parent, before analysis.** Everything downstream is the frozen, `Marshal`-clean
  value object, so no plugin code runs inside the fork-pool worker, inside the effect scan (ADR-103 WD13
  forbids it there), or on any per-file hot path.
- **It isolates like `#diagnostics_for_file`.** A raise costs that file its unit and surfaces as the row
  above; the run continues. A template compiler meeting a file it cannot read must never cost the run.
- **It costs nothing when unused.** A run whose loaded plugins declare no `template_globs:` performs no
  glob, calls no plugin, adds no cache-key slot and analyses exactly the files it analysed before. `rigor
  check` on such a project is byte-identical.

A unit may also declare `suppressed_rules:` — rule-id prefixes the engine drops for that unit's diagnostics
([#393](https://github.com/rigortype/rigor/issues/393)). It is the per-unit rule posture: only the plugin
knows which families of finding its own compiler's output can support, and the alternative — a project-wide
`disable:` entry — would silence the rule in the project's `.rb` files too. rigor-actionpack declares
`["call."]` for an ERB unit while its `view_type_checks:` is off (`flow.` left the set in
[#1047](https://github.com/rigortype/rigor/issues/1047), once render-site locals were traced).

`#template_units_pass_started` ([#1047](https://github.com/rigortype/rigor/issues/1047)) is called once at
the start of every collection pass over the plugin's claim — before its first `#template_units_for_file`,
and even when the pass compiles nothing because every unit was carried. It exists for a transform that reads
state gathered across its claimed files and memoises it on the plugin instance: a long-lived owner
(`LanguageServer::ProjectContext`) keeps that instance across passes, and a warm pass offers only the
editor's buffer, so no order of `#template_units_for_file` calls can tell one pass from the next. The
default does nothing, and a raise is swallowed — the pass proceeds, only the plugin's own revalidation is
skipped. The same cross-file dependency is why the collector carries a plugin's claim as a whole: if any
of its templates was edited, added or deleted since the carried index was built, none of its units is
reused (a deleted template that had produced no unit is the one change that rule does not see).

The value-object fields, the position mapping, the `view:<logical_name>` effect key, the rule posture, the
cache identity and the `--incremental` bound are normative in
[`macro-substrate.md`](macro-substrate.md#template-units--templateunit-template_globs--template_units_for_file-392).

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

`Rigor::Plugin::Base.ffi_binding_recognizer(name, &block)` / `.ffi_binding_recognizers`
(ADR-30 / #727) is the class-level DSL contributed by `rigor-ffi`. Plugins authoring
FFI binding recognizers (such as `rigor-rbnacl`, `rigor-sassc`) register custom
binding recognizers using this DSL so the FFI catalog can recognize their binding
declarations.

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
  entry (matched via `Environment#class_ordering`) **and** the receiver
  is of the kind that entry names. `methods:` (an
  `Array` of Symbol/String names, or a run-time callable, ADR-52 slice 4)
  gates on `call_node.name`; `file_methods:` (a callable receiving the
  path, memoised per `(rule, path)`, ADR-52 slice 5a) is its per-file
  specialisation for a name set that varies by analysed file
  (rigor-rspec's `let` names) and replaces `methods:`. First non-`nil`
  wins. The engine invokes it through `#dynamic_return_type(call_node:,
  scope:, receiver_type:)`. `rigor-mangrove` (unwrap → carried
  `type_args[0]`) is the worked consumer.
  - **A `receivers:` entry names a receiver KIND, not just a class**
    (issue #701). A bare class name — `"Widget"` — matches an INSTANCE
    receiver: `Type::Nominal[Widget]`, and the `Type::Result` /
    `Type::Maybe` carriers, which are instances of their class. The
    class object itself is written in RBS's own spelling,
    `"singleton(Widget)"`, and matches `Type::Singleton[Widget]`. A rule
    that deliberately wants both declares both entries
    (`["Widget", "singleton(Widget)"]`); `rigor-ffi` is the bundled
    consumer, because `attach_function` installs a binding the library
    module answers to under either kind. Inheritance is matched on the
    class name in both kinds, so `"singleton(ActiveRecord::Base)"`
    covers `singleton(User)` exactly as the bare entry covers `User`. A
    receiver carrier with no nominal class (a refinement dimension, an
    inferred shape) matches no entry at all. `singleton(` opening an
    entry that does not close is rejected at load, so a mistyped kind
    wrapper fails loudly instead of silently never matching. **This is
    the difference between an instance rule and a class-level answer**:
    before #701 an entry matched both kinds, so a rule written for
    `Widget#price` also answered `Widget.price` — and, since the #653
    suppression below, silenced that call's genuine
    `call.undefined-method` on the strength of a type the plugin was
    never asked to produce.
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
  - **A `dynamic_return` answer takes precedence over the RBS return,
    silently** ([ADR-2](../adr/2-extension-api.md) § "Amendment
    2026-09-26 — a `dynamic_return` answer outranks the RBS return",
    issue #700). `MethodDispatcher#resolve` consults the plugin tier
    after the precision tiers (`MethodFolding.try_backward`,
    `dispatch_precise_tiers`) and ahead of every RBS-backed tier, ending
    in `RbsDispatch.try_dispatch`, and returns the first plugin answer.
    The answer is the call site's type whether it narrows the declared
    return or contradicts it, and the engine MUST NOT report the
    difference: the RBS return never enters `FlowContribution::Merger`,
    so there is no tier comparison. An RBS `def self.logger: () ->
    Integer` alongside a plugin answering `Frameworkish::Logger` types
    the site `Frameworkish::Logger`
    (`spec/integration/plugin_typed_call_undefined_method_spec.rb`).
    Bundled plugins rely on this: `rigor-activesupport-core-ext`'s
    `%i[+ - *]` rule answers over the fully declared core `Time#-` /
    `Integer#*`, because the RBS projection is wrong once a `Duration`
    is the operand (`Time.now - 30.minutes` projects `Float`), and
    `rigor-dry-validation` narrows the `Result#to_h` its own `sig/`
    declares per contract.
    - **The rule covers the return type only.** A `def` body is still
      checked against its declared RBS return, and
      `call.wrong-arity` / `call.argument-type-mismatch` still validate
      a plugin-answered call against the RBS signature today — whether
      they should is left open below.
    - **The safeguard is a test-time check, not a diagnostic**
      ([#1413](https://github.com/rigortype/rigor/issues/1413), not yet
      built). The suite compares each bundled plugin's answer in its
      integration fixtures with the RBS return, and a rule that answers
      outside it on purpose declares `overrides_rbs: "<reason>"` on its
      `dynamic_return`. Until #1413 lands, nothing checks an override.
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
    - **This rule does not rest on which subsystem outranks the other.**
      A method the receiver's RBS declares resolves through the rule's
      own `lookup_method` and never reaches the diagnostic, so
      `call.undefined-method` fires identically whether the record is
      read as "a plugin answer wins outright" or as "a plugin answer
      wins where the RBS is silent". The record is consulted for every
      plugin answer only because that is the cheaper and more honest
      shape; the precedence itself is the bullet above.
    - **The suppression is only as sound as the plugin's own receiver
      gate**, which is why that gate carries the receiver KIND (issue
      #701, above). While a `receivers:` entry matched a class NAME
      alone, an ordinary instance-method rule (`receivers: ["Widget"],
      methods: [:price]`) also answered `Widget.price`, and this record
      then silenced a genuine `undefined method 'price' for
      singleton(Widget)` on the plugin's say-so — for a call the plugin
      had already mis-typed. An instance entry no longer answers there,
      so the class-level miss reaches `RbsDispatch` and is reported. A
      rule that declares `"singleton(Widget)"` does suppress it, and
      that is the point: the plugin has then said, explicitly, that it
      models the class-level call.
    - The two rules that read a RESOLVED SIGNATURE (`call.wrong-arity`,
      `call.argument-type-mismatch`) are **not** covered by this record
      today: at a plugin-answered site they still validate the call
      against whatever signature the RBS declares for that name. No
      bundled plugin reaches that shape — every one of them answers a
      method its coexisting RBS declares with a compatible arity — so
      the gap is currently unreachable in the shipped set, and closing
      it would suppress two checks that do catch real errors. Decide it
      on evidence from a plugin that actually hits it.
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

#### Enumerating synthesized members — `#declared_members` (ADR-113 WD4, [#1082](https://github.com/rigortype/rigor/issues/1082))

A `dynamic_return` rule answers a *type* for one call site at a time; it
cannot say "class `User` has `email`, `name`, …". `#declared_members(class_name)`
is the per-class enumeration hook the `rigor lens` declaration map
([ADR-113](../adr/113-rigor-lens.md)) calls for plugin-synthesized
members — the surface grep can never find on a DSL-generated member.

The hook returns an `Array` of `{name:, kind:, type:}` Hashes:

- `name` — the member name as a caller spells it (`String`).
- `kind` — a `Symbol` grouping same-shaped members (`:column_reader`);
  the lens collapses a group into one line of names.
- `type` — the `Rigor::Type` the plugin commits to for the member
  itself, or nil where it does not commit to one. It is the
  member-level answer, not the best a typed call site can do: a plugin
  that narrows `user.name` to `String` on a written receiver but
  declines to type the bare `name` read reports `Dynamic[top]` here —
  `Rigor::Type::Combinator.untyped`, the explicit dynamic answer,
  distinct from nil's "no answer". rigor-activerecord's column readers
  report `untyped` on purpose: precise column types at member level
  were measured at 57 false positives on mastodon (#963).

The default returns `[]`. The hook is off the `check` hot path
(ADR-52): the lens invokes it and `check` never does, so its cost is a
lens run's alone; it may read state `#prepare` built.
rigor-activerecord is the first implementor — it enumerates column
readers and their `column?` predicates, association accessors,
declared scopes, enum attributes (only where no column row already
carries the name), and `macro_methods` (delegate / attachment /
enum-predicate names) straight off the prepared `ModelIndex`.
`alias_attribute` aliases and the columns of a model whose table name
the plugin cannot derive are NOT listed — matching `check`, which
answers nothing for them either.

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
  the invocation, chosen by `.rigor.yml`'s `plugins_isolation:` key or by
  `RIGOR_PLUGIN_ISOLATION`. **The environment variable wins over the
  configuration**: it is the operator's one-invocation override (the fork
  worker misbehaving on one machine, a CI image that cannot fork), and an
  override a committed file can veto is not an override; it is also the
  only ordering under which `ruby_box` can work, since `exe/rigor` re-execs
  with `RUBY_BOX=1` on the variable alone, before any YAML is parsed
  (ADR-87 / ADR-104 boot-slim). `plugins_isolation: ruby_box` in the
  configuration is therefore a `ConfigurationError` naming the variable,
  never a silent fall back to another strategy
  ([#911](https://github.com/rigortype/rigor/issues/911)). One
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
    versions in-process. Experimental. Before the re-exec,
    `Rigor::Plugin::BoxProbe` runs the minimal reproducer of Ruby Bug
    #22260 (a class-body proc isolated by `Ractor.make_shareable` loses
    its box and segfaults on its first method call) in a child Ruby under
    `RUBY_BOX=1` with an empty `RUBYOPT` and a ten-second deadline. Only
    a child killed by a signal is reported as the bug; one that prints the
    wrong answer, exits non-zero, cannot start, times out, or reports
    `Ruby::Box` inactive is reported as such. Either way the launcher
    writes a notice to stderr (`$stderr.puts`, so `-W0` cannot hide it),
    drops `RIGOR_PLUGIN_ISOLATION=ruby_box` / `RIGOR_BOX`, and runs under
    the configured strategy. The probe is skipped when `RUBY_BOX` is
    already set, since the process has booted inside the box by then.
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
| `target_gems` | `Array<String>` | The gems this plugin models, spelled as `Gemfile.lock` spells them (ADR-96 WD1). Not derivable from the plugin name — `rigor-factorybot` models `factory_bot`, `rigor-rspec` models `rspec-core`, `rigor-rails-routes` models `actionpack` / `railties` — which is why it is declared rather than inferred. An empty list is the meaningful answer for a plugin that models no gem (`rigor-typescript-utility-types`), and such a plugin is never advised about. Read by `Plugin::BundledCatalog` and, through it, by the `rigor doctor` / `rigor skill describe` plugin-gap advisory (ADR-96 WD2), which matches these names against the lockfile's `DEPENDENCIES` section — the project's own dependencies, expanded through an umbrella table for `rails` — and never against the resolved graph. Naming a plugin never loads it: gem presence is evidence for advice, not for execution. The catalogue holds one entry per id: a class defined under the engine's `plugins/` tree wins its id, and an anonymous or third-party class is consulted only for an id no bundled class claims (#982); the catalogue only advises, and the registry still refuses a second class per id. |
| `produces` | `Array<Symbol>` | Cross-plugin facts this plugin publishes (ADR-9). |
| `consumes` | `Array<Consumption>` | Cross-plugin facts this plugin reads (`{ plugin_id:, name:, optional: }`); drives the loader's topological ordering (ADR-9). |
| `signature_paths` | `Array<String>` | RBS signature directories the plugin contributes, relative to the plugin gem root; resolved by `Loader` and merged into the environment (ADR-25). Where the plugin types a subclass's instances as a class declared here, `call.wrong-arity` and `call.argument-type-mismatch` check a call on the subclass against the declared parameter list, so that list MUST accept every argument the subclass's override accepts. § Which channel a row belongs in has the worked example and states the same rule for effect bounds. |
| `owns_receivers` | `Array<String>` | Receiver class names this plugin owns for dispatch routing. |
| `rbs_complete_extends` | `Array<String>` | The `extend`-edge twin of `rbs_complete_ancestors`: module names whose RBS *instance* surface this plugin's `signature_paths:` declares COMPLETELY. A Ruby-source class or module whose body contains `extend M` for a listed `M` resolves singleton-side calls through `M`'s declared instance methods — `class F; extend T::Sig; sig { ... }; end` reaches `T::Sig#sig` (issue #1097). The walk also consults `Environment#singleton_extended_modules` on each discovered superclass, so `class Doc < T::ImmutableStruct` picks up `T::ImmutableStruct`'s own RBS-declared `extend T::Sig`. The same guards as the superclass bridge apply: an RBS-known receiver answers through the direct lookup, a nearer source `def self.x` shadows the bridge, and a candidate that resolves to a project class (or a non-allow-listed RBS module) and defines the method owns the edge and stops the whole walk — later `extend`s and RBS superclasses are not searched, matching `MacroBlockSelfType`. A module whose declared surface is partial does not belong here — the bridge would misreport real calls as `call.undefined-method`. A nearer source `def self.x` shadows only once it has executed: `Scope#singleton_def_shadows_call?` orders it against the call through the `discovered_deferred_ranges` table — calls inside def / block / lambda bodies run at invocation time and are shadowed iff a same-name def of the same class is known at all, while an eager class-body call is shadowed only by a same-name def OF THE SAME CLASS that starts before it. |
| `rbs_complete_ancestors` | `Array<String>` | Class names whose RBS surface this plugin's `signature_paths:` declares COMPLETELY for its supported DSL surface (ADR-43 WD4). A Ruby-source subclass of a listed class bridges inherited calls to the ancestor's RBS — the manifest-declared half of the `RbsDispatch` allow-list — so the declared methods' return types and block parameters resolve on every subclass. The bridge is a signature lookup ONLY: the subclass itself stays outside RBS, so `call.undefined-method` / `call.wrong-arity` / `call.argument-type-mismatch` do not fire on calls the subclass makes to undeclared names (pairing with `open_receivers:` is therefore the honest pairing for a DSL whose surface is generated at runtime). A project `def` of the same name on the subclass or a nearer source ancestor shadows the bridge. Only a class whose declared surface is accurate belongs here — a signature member that does not exist at runtime makes a genuinely failing call resolve silently. |
| `open_receivers` | `Array<String>` | Receiver class names whose method surface is unbounded — e.g. `ActiveRecord::Relation`, which delegates every user-declared `scope` to its model (ADR-26). Such a class is exempted from `call.undefined-method` outright, and from the two signature-reading rules (`call.wrong-arity`, `call.argument-type-mismatch`) for any method name it INHERITED rather than declared: a delegated name that collides with an ancestor's (`relation.open` → `Kernel#open`) resolves to a signature the call does not run. A method the open class declares itself keeps both checks; a method it genuinely has through an ancestor (`Enumerable` on a Relation) loses them too — the test is the definition site, not delegation. This field only takes effect once a project loads the declaring plugin. Two OTHER, plugin-independent sources feed the same `CheckRules#unbounded_receiver_surface?` gate: `RbsLoader#synthesized_type_names` stub types, and (issue #632, tracked further by #660) `CheckRules::GEM_OVERLAY_OPEN_RECEIVERS` — a plain constant, not a manifest field, for a class Rigor's own BUNDLED gem-overlay RBS (`data/gem_overlay/`, ADR-72) declares knowing the declaration is partial. An auto-applied overlay has no plugin manifest for an `open_receivers:` entry to live on, so a receiver it declares open (`ActiveSupport::Duration`, which forwards undeclared members to the wrapped numeric via `method_missing`) needs protection independent of whether any plugin is loaded at all; `rigor-activesupport-core-ext` ALSO lists the same class under its own `open_receivers:`, so the two sources overlap there by design — either alone is sufficient, and the constant is what covers the overlay-only case the manifest field structurally cannot reach. Membership in that constant is NOT itself sufficient, though: `CheckRules#gem_overlay_loaded?` additionally requires one of Rigor's own partial declarations of that gem to have actually loaded THIS run — `RbsLoader#signature_paths` including a directory under `RbsLoader.under_gem_overlay_root?` (the auto-applied overlay) or one matching `RbsLoader.gem_overlay_twin_signatures_loaded?` (the bundled plugin twin's own `sig/`, reached when a project wires it through `signature_paths:` instead of `plugins:` — issue #672, where the overlay now stands down and the twin's manifest-less declaration is the only one loaded) — otherwise a project that never locks the gem, and happens to own a class of the same qualified name itself, would silently lose `call.undefined-method` coverage on it. This restores the same "the protection is active exactly when the RBS is" property `open_receivers:` gets for free from requiring the declaring plugin to be loaded (ADR-26 WD1). |
| `type_node_resolvers` | `Array` | `Plugin::TypeNodeResolver` entries contributing custom RBS type-name resolution (ADR-13). |
| `protocol_contracts` | `Array<ProtocolContract>` | Path-scoped behavioural contracts (`path_glob` + `method_name` + `singleton` + param/return types + severity); provide-and-check (ADR-28). |
| `source_rbs_synthesizer` | `#call(path) -> String?` | A callable that synthesises RBS from a project source file at env-build time (e.g. rbs-inline ingestion) (ADR-32). A synthesiser that must emit a member the source never gave a return type MUST annotate it `%a{rigor:v1:inferred-return}` ([rbs-extended.md](../type-specification/rbs-extended.md)) rather than declare a placeholder return, so the member stays declared while its callers keep the inferred type ([ADR-93](../adr/93-default-rbs-inline-ingestion.md) WD6). |
| `block_as_methods`, `heredoc_templates`, `trait_registries` | `Array<Plugin::Macro::*>` | The ADR-16 macro / DSL expansion substrate tiers (A / C / B). Value-object shapes spec'd in [`macro-substrate.md`](macro-substrate.md). |
| `template_globs` | `Array<String>` | Project-relative globs whose files this plugin compiles into template units — the revived ADR-16 Tier D (`external_files:`, removed by ADR-60 WD1, returned demand-gated as template units in [#392](https://github.com/rigortype/rigor/issues/392)). Purely a claim: the transform itself is `#template_units_for_file` below. Absolute globs and `..` segments raise at manifest-build time. Spec'd in [`macro-substrate.md`](macro-substrate.md) § Template units. |
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
| already ships an RBS signature for the method | `%a{rigor:v1:effect …}` / `%a{pure}` in `signature_paths:` | Tier 1. The annotation rides the **accepted signature** stratum, which ADR-103 WD6 already trusts for types; the bound is imported at the call site by `Effects::EnvelopeIndex` and discharges. rigor-activerecord's `sig/active_record/relation.rbs` is the worked example — the builder / materializer split lives there because the file already draws it. To bound a method the class defines but the shipped signature leaves out, and that no row already covers, the plugin adds it to the signature when declaring it changes no type. On an `open_receivers:` class an undeclared method already types as `untyped`, so a `-> untyped` declaration adds the bound and the call checks every declared method gets (`call.wrong-arity`, `call.possible-nil-receiver`). Its parameter list MUST admit every call the class and each override it types as the class accept. `Relation#insert` / `insert!` / `upsert` are the case. |
| does not, or cannot name the method per app | `effect_attributions:` | Association readers, `find_by_*`, scopes and the `Enumerable` delegations on a Relation are either per-project or would change how the method **types** if declared. So is any class the plugin ships no signature for at all. |

A row must never be in both: two channels on one method produce two origins for one fact, which reads as
duplication in `rigor effects explain`.

A bound is written for **every run-time class the plugin types as the declaring class**, not just the one it
names. Where a plugin types a subclass's instances as the base class, the base's bound is what a call on
the subclass imports, so it MUST also admit the subclass's override. rigor-activerecord types a `has_many`
reader, and every query builder called on it, as `ActiveRecord::Relation[Model]`. The reader actually
returns a `CollectionProxy`, and the builders return an `AssociationRelation`, and the `build` of both pushes
the new record into the association's target. `Relation#build` therefore carries `mutate.self`, although a
plain Relation's `build` changes nothing. A writer that only the subclass defines (the proxy's `<<`) becomes
an `effect_attributions:` row keyed on the base class. A bound that fits only the base class would give
`%a{pure}` to a method that changes an object its caller still holds.

The rule holds for parameter lists as well as bounds (the `signature_paths` row of
§ `Rigor::Plugin::Manifest`). The proxy's `delete_all(dependent = nil)` is why `Relation#delete_all`
declares an optional argument that a plain Relation's and an `AssociationRelation`'s do not take. The check
then misses `delete_all(:nullify)` on either of those, which raises `ArgumentError`. That is the same trade
as `build`'s `mutate.self`: a declaration that fits only the base class reports `call.wrong-arity` on
valid Rails.

A bound also names **every read and write the framework's own implementation performs, on any path**.
Sibling leaves do not subsume each other, so a writer that queries before its write, or after a failed one,
carries both `io.db.read` and `io.db.write`. rigor-activerecord's `find_or_create_by` is `find_by` and then a
create, and `destroy_all` loads the records it destroys. A class method that the framework delegates to
another receiver carries that receiver's bound: `Model.update_all` is `Model.all.update_all`. Two kinds of
work stay outside it. Schema reflection is one, because counting it would make every query builder a read.
The model's callbacks and validators are the other, including the ones an association option such as
`dependent:` or `touch:` registers. They belong to the model, and an `effect_edges:` strategy is the only
channel that can carry them. Today's strategy carries symbol-argument callback macros and a uniqueness
validator, so the reads those association options register are carried by nothing. Which association a
proxy stands for is not a callback: the `has_many :through` proxy's `delete_all` loads its target first, so
the bound counts that read.

`io.db.transaction` is not held to the rule yet. A write that opens a transaction around itself is not
labelled with it: `save`'s implicit transaction and the explicit ones in `create_or_find_by` and the proxy's
`create` are not. rigor-activerecord's proxy-writer rows and its `transaction` / `with_lock` rows do carry
it.

##### `EffectAttribution`

`Rigor::Plugin::EffectAttribution.new(receiver:, method:, labels:, why:, singleton: false, narrow: nil,
discharge: false, within: nil, on_result: false, taint: nil, callee: nil, callee_fallbacks: nil,
responds: false)`.

`why:` is **required and non-empty**, exactly as every row of `data/effects/core.yml` requires one: a
label with no stated reason is a claim nobody can review.

`labels:` describe the **call**, not the callee's body. A row cannot run the ownership judgment the scan
applies to a core mutator, so a change to a receiver that is not the caller's `self` is spelt bare `mutate`,
and `mutate.self` is kept for an implicit-self call. Examples of the two are rigor-actionpack's
`session[:k] = v` and `render`. A change to class-level or process-global state belongs to no frame and is
`mutate.static` either way, as in rigor-railties' `Rails.application.reload_routes!`. An RBS envelope is the other way round, because it bounds the callee's own
body ([`effect-labels.md`](../type-specification/effect-labels.md) § The declared lane at call sites).

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
unknown until the render site is edged to the template's own unit.

##### `callee:` — a framework method that is also an EDGE ([#1048](https://github.com/rigortype/rigor/issues/1048))

`callee:` names a `Rigor::Effects::CalleeRule` rule, and it is shaped exactly as `narrow:` is, for the
same reason: the plugin supplies a **name** and the engine owns the strategy. A block would have to run
inside the per-file effect scan — the one place [ADR-103](../adr/103-effect-labels.md) WD13 forbids
anything that resolves, walks or types — and would not survive the fork-pool / Ractor boundary. A rule
reads the call's own argument literals, the unit's owner class and the unit's own key, and **nothing
else**: no dataflow, no typer question, no filesystem.

`render :show` inside `UsersController` runs `app/views/users/show.html.erb`, synchronously and
in-process, and since [#393](https://github.com/rigortype/rigor/issues/393) that template is an effect
unit keyed `view:users/show.html` sitting in the same summaries table. `effect_edges:` could not spell
it — its payload is a receiver *class name* and it mints units on a class body — so the edge is produced
here, at the call site, from the literals the author wrote.

| Rule | Applied | Reads |
| --- | --- | --- |
| `rails_render` | one call node, inside a controller | `render :show`, `render "show"`, `render "users/show"`, `render template:`, `render action:`, `render partial:` (with or without `collection:`) |
| `rails_render_partial` | one call node, inside a template unit | the same, with a **bare argument read as a partial** and `layout:` read as one too — which is what a view means by them |
| `rails_implicit_render` | once per unit, from its owner and its own key | nothing; the producing fact is that the body made no call at all |

A rule that cannot settle the target from literals alone answers **nil**, and a nil leaves the site
exactly as it was, `taint:` included. A rule that answers a key the run's table has no unit for produces
an edge that resolves to nothing, and the row's `taint:` is seeded **by the propagator** from
`FileCollection::Edge#taint_if_unresolved` — added on failure rather than subtracted on success, so
every step of the fixpoint stays monotone. Between them those two rules are why `render foo`,
`render json:`, and a `render` of a template the plugin never compiled (a Haml view, or a partial
that exists in neither the requested format nor its fallback) all keep the `template-not-analysed` taint,
while only a render that reached a real unit clears it.

##### `callee_fallbacks:` — the framework's lookup order, as data ([#1065](https://github.com/rigortype/rigor/issues/1065))

`callee_fallbacks:` is a Hash from a callee **selector** to the ordered selectors to retry when no unit
answers it — rigor-actionpack's view row carries `{ "js" => ["html"] }`, because while a `.js.erb`
template renders, Action View's lookup context is `[:js, :html]`. Every key and value is one lowercase
segment (`/\A[a-z0-9_]+\z/`); a selector listed as its own fallback is dropped; a row naming it without
`callee:` is refused at construction.

The table is plugin data rather than an engine constant because the lookup order is a fact about the
framework, and the engine's rules stay declarative. **Whether** it is consulted is the rule's call, not
the row's, because only the rule knows where the selector came from:

| Rule | Consults the table | Why |
| --- | --- | --- |
| `rails_render_partial` | only for a format **inherited** from the enclosing template unit | a `formats:` / `format:` keyword or a format spelled into the name (`render "list.js"`) is the author's word, and the rule keeps the taint rather than guess at a lookup the call overrode |
| `rails_render` | never | its format is either the author's literal or the `html` default standing in for a request format the rule cannot see |
| `rails_implicit_render` | never | a unit rule's edge carries no taint to keep, and its `html` is the same stand-in |

The rule copies the list onto the edge (`FileCollection::Edge#fallback_selectors`) and the **propagator**
decides, because whether `view:watchers/_list.js` exists is a question about the merged table the
per-file scan cannot ask. The first selector — the requested one, then each fallback in order — that
resolves is the edge's only target; the row's `taint:` is seeded only when all of them fail. One ordered
list rather than one edge per candidate, because two edges would join **both** units where both exist,
and only one of them runs.

A fallback is **not** tried past a requested key the run declined — a template the plugin claimed and
produced no unit for, carried as `Analysis::TemplateUnits#declined_unit_keys` and handed to
`Propagator.propagate` ([#1065](https://github.com/rigortype/rigor/issues/1065)). "No unit answers" and
"no such template" are different facts, and only the second licenses the framework's next candidate: a
`_row.js.haml` beside a `_row.html.erb` is run as Haml, so joining the ERB unit would be a label no
execution produces. A plugin that wants that protection for a handler it does not compile must CLAIM the
handler in `template_globs:` and decline it in `template_units_for_file`, which is what rigor-actionpack
does for `{haml,slim,jbuilder,builder,rabl,ruby}`; an unclaimed handler is invisible to the engine and
its fallback fires as if no template were there.

One over-approximation remains and is accepted: a partial reached *through* a fallback renders its own
partials in the format its own unit key carries, while the framework's lookup context is still the
original list. Where a nested partial exists in both formats, the first template joins the wrong one's
labels — labels, never a taint, and zero occurrences on the measured corpus.

A **unit rule** is the one shape neither `effect_attributions:` nor `effect_edges:` could carry before.
Rails' implicit render is a fact about a method that made *no call*, so there is no site to colour and
no class body that can see which of its methods responded — only a finished unit scan can. Such a row
contributes an **edge and nothing else**: no label, no taint, so an edge that resolves to nothing costs
exactly nothing. It is also the one case where `labels:` MAY be empty; every other row must still
declare at least one.

`responds: true` marks a row whose call supplies the unit's answer, so a unit rule on the same receiver
stands down. `render`, `redirect_to`, `head`, `send_data` and `send_file` each carry it: an action that
called one of them did not take Rails' implicit render, and edging it to the conventional template would
attribute a view the action never runs. `render_to_string` deliberately does **not** — it builds a
string and leaves the response unanswered.

The engine narrows a unit rule three ways beyond the ancestry match, and each is a false positive it
would otherwise produce:

- a `responds:` call counts only at the unit's **top level**. `redirect_to root_path if @user.nil?`
  leaves the other path taking the implicit render, and standing down there would drop the template
  edge *and* leave the unit reading exhaustive. Branching ancestors are `If` / `Unless` / `Case` /
  loops / `And` / `Or` (modifier forms included), `Rescue` — the rescue **clause**, not the body it
  guards, so a `render` in the `begin` half of `begin … rescue … end` is at depth zero and stands the
  rule down, correctly, because that half runs — and a **block or lambda**, whose body a call may never
  make (`User.transaction { redirect_to "/" }`, `[1].each { … }`, `@after = -> { redirect_to "/" }`). The exception is `respond_to` /
  `respond_with`'s own block, a format dispatcher rather than a branch; its arms are ordinary blocks,
  so `format.json { render json: @user }` no longer stands the HTML arm's implicit render down. Three
  over-approximations remain — an `if`/`else` whose every branch responds, a response inside a format
  arm, and `redirect_to … and return` — and each keeps an edge that is not needed rather than
  dropping one that is;
- a **`private` or `protected`** member is skipped. Rails' `action_methods` is a controller's public
  instance methods, so a `private def card` is never rendered as `users/card` — while a project that
  happens to ship `app/views/users/card.html.erb` would otherwise hand that template's effects to the
  helper. `Effects::Visibility` reads `private` / `protected` as a region and in their argument forms
  (`private def foo`, `private :foo`, `private %i[foo bar]`), and `public` **subtracts** in all of
  them; a `def self.x` inside a region marks nothing, since a region hides no singleton method. A
  **splat** (`private(*names)`) is a value rather than syntax and is not read, so such a member stays
  public. It reads the class body's own top
  level in source order, and anything deeper — `send(:private, :card)`, a `class_eval`, a concern that
  privatises on include — reads as public, which leaves today's behaviour intact rather than guessing;
- a **nested `def`** and a **singleton method** are skipped outright. Neither is ever an action.

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
[ADR-103](../adr/103-effect-labels.md) WD17 weighed promoting a first-party row into `proven` and
declined it — that would be a redefinition of `proven` rather than an extension, and it would stake
`rigor check`'s red on the correctness of plugin authorship rather than on code Rigor read. The
consequence a policy author feels is that `EnvelopeCheck` cannot judge a plugin-sourced label at all;
the enforcement surface for one is `rigor effects check`.

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
**plugin-registration order** (`Registry#type_node_resolvers`, compiled
at registry construction from the same guarded manifest read its
`compile_aggregates` siblings use) — into a single
`Rigor::TypeNode::ResolverChain`, which
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
| `#load_errors` | `Array<Rigor::Plugin::LoadError>` collected during loading, followed by any raised by a plugin's manifest read at registry construction. |
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
entry does not abort the others. Registry construction then reads
each loaded plugin's manifest once, behind the same per-plugin
isolation: a plugin whose `#manifest` raises contributes nothing to
the construction-time aggregates (`type_node_resolvers`,
`open_receivers`, `additional_initializers`) and its raise is
collected as a further `LoadError` — appended after the loader's own,
and referring to the plugin CLASS, since `manifest.id` is exactly what
could not be read. Aggregating there rather than on demand is
load-bearing: `Environment#build_name_scope` demands
`Registry#type_node_resolvers` during Environment construction, which
nothing rescues, so a lazy read would abort the run rather than
degrade it.

Each failure is collected as a
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
