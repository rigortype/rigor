# ADR-37 — Plugin interface segregation (narrow extension protocols)

Status: **Proposed, 2026-06-02; Slice 1 (NodeRule) implemented.**

**Slice 1 implemented (2026-06-02):** the `node_rule` class DSL on
`Plugin::Base` + `Base#node_rule_diagnostics` (the engine-owned walk) +
runner / worker-session wiring. A plugin declares
`node_rule(Prism::CallNode) { |node, scope, path| … }`; the engine walks each
file's AST once (via `Source::NodeWalker`) and dispatches every reachable
node to the rules whose `node_type` it satisfies, `instance_exec`'d on the
plugin instance, so authors never hand-roll a traversal. It runs alongside
the legacy `diagnostics_for_file` (now conceptually the `FileRule` escape
valve), is a zero-cost no-op for plugins that declare no rules, and is
isolated by the same per-plugin `rescue` boundary. Slice 1c adds
`node_file_context` for two-pass (collect-then-validate) plugins. The slice-1
working decisions are pinned below. Slice 1d adds `NodeContext` (lexical
context for node rules). The **slice 2 design** (`flow_contribution_for` →
`dynamic_return` + `type_specifier`) is recorded below, and its **engine
surface is implemented** (the two DSLs + the two runner methods + the
receiver-class / method-name gating, consulted at both dispatch sites
alongside the deprecated `flow_contribution_for` fan-out — fully
back-compatible, every existing consumer unchanged and green). Slice 2b
migrated the two cleanly-fitting consumers (`rigor-mangrove` → `dynamic_return`,
`rigor-minitest` → `type_specifier`); the rest legitimately stay on the
deprecated `flow_contribution_for` escape valve (two contribution shapes the
narrow DSLs do not express — see the slice 2 § "Outcome"). **Not yet done:**
rspec matcher narrowing → `type_specifier` (fits), the deferred
`dynamic_return` generalisation for the escape-valve consumers,
`FactProvider` naming (slice 3), the remaining `node_rule` migration
(`rigor-actionpack`), and the capability catalogue. Thirteen plugins are
migrated onto `node_rule` so far.

Records the decision to finish the interface-segregation work that
[ADR-2](2-extension-api.md) started: split the two remaining *imperative*
plugin hooks (`flow_contribution_for`, `diagnostics_for_file`) into a small
set of **narrow, manifest-registered, engine-gated extension protocols**,
following PHPStan's gate/payload invariant. The fat `Plugin::Base` hooks
remain as a deprecated escape valve for backward compatibility. This ADR
revises the *hook model* of ADR-2; it does not change the flow-contribution
semantics ADR-1 owns.

Grounding review:
[`docs/design/20260601-plugin-mechanism-pre-1.0-review.md`](../design/20260601-plugin-mechanism-pre-1.0-review.md)
§6 (the cross-plugin audit that motivated this ADR).

## Context

Rigor's plugin contract has grown two coexisting extension styles:

1. **Declarative manifest fields (10).** `block_as_methods`,
   `trait_registries`, `heredoc_templates`, `nested_class_templates`,
   `type_node_resolvers`, `protocol_contracts`, `hkt_registrations`,
   `hkt_definitions`, `source_rbs_synthesizer`, `owns_receivers`,
   `open_receivers`. Each is aggregated off `registry.plugins` into a
   structure the **engine indexes itself** (`SyntheticMethodScanner`,
   `TypeNode::ResolverChain`, `Registry#contracts_for_path`, the HKT
   overlay, …) and **the engine gates** by verb / receiver / class / path.
   This is already PHPStan-shaped: a narrow capability the engine consults
   only for matching nodes.

2. **Imperative hooks (2).** `flow_contribution_for(call_node:, scope:)` and
   `diagnostics_for_file(path:, scope:, root:)`. The engine calls **every
   loaded plugin** for **every** unresolved call node / every file, and each
   plugin **gates itself** with an internal `if`. The dispatch loop is
   duplicated verbatim in `inference/method_dispatcher.rb` and
   `inference/statement_evaluator.rb` (the latter's comment admits it
   "Mirrors … exactly"). Both sites `rescue StandardError; nil`, so a
   mis-gated plugin contributes nothing with no signal.

The fan-out-and-self-gate style is where the design costs the most, and the
costs map exactly onto the project's stated goals for the plugin
architecture — **AI-agent legibility** and **per-interface testability**:

- **AI/human comprehension.** `registry.plugins.each { |p| p.flow_contribution_for(...) }`
  says nothing about *which* plugins participate or *what* receiver/method
  they care about. That selectivity lives inside each plugin's self-gating
  `if`, so it is neither greppable nor enumerable. The declarative fields are
  the opposite: the manifest field name tells a reader (or a tool) exactly
  which subsystem consumes it.
- **Testability.** The only harness today is `run_plugin` in
  `spec/integration/support/plugin_helpers.rb`: write a demo file, run the
  **full** `Analysis::Runner`, assert on `result.diagnostics`. There is no
  way to assert "this hook returns type X for this node" or "this rule fires
  here" in isolation; even hook-named specs assert on a downstream
  `call.undefined-method` message produced by the whole engine. PHPStan, by
  contrast, ships `RuleTestCase` (assert the error set for a fixture) and
  `TypeInferenceTestCase` (assert inferred types via inline `assertType()`).
  Per-interface harnesses are only possible once the hooks are narrow.
- **Boilerplate.** Because `diagnostics_for_file` hands over the raw `root`
  and the doc tells authors to "traverse `root` themselves"
  (`plugin/base.rb`), ~25 plugins re-roll the same recursive AST walker. The
  walker exists *only* because the engine does not own the walk.
- **Performance (secondary).** Cost scales `plugins × files × nodes` with no
  pre-filter. Non-critical per the review brief — caching mitigates — but it
  falls out for free once the engine indexes the hooks.

**The window.** Hook signatures freeze as a public contract at 1.0. Splitting
the imperative hooks after 1.0 is a breaking change. This is the last
low-cost opportunity to do it.

### What PHPStan does (the one invariant to port)

PHPStan has ~50 extension interfaces, but the transferable invariant is
single:

> A **cheap gate predicate** (returns bool / `nil`-decline) is split from an
> **expensive payload** (returns a `Type` / errors / data). The engine
> indexes extensions by the gate value (`getClass()`, `getNodeType()`,
> `isMethodSupported()`) and invokes the payload **only** for matching
> nodes/receivers.

Rule extensions declare `getNodeType()` and the engine dispatches each AST
node only to the rules registered for that class. Dynamic-return extensions
declare `getClass()` + `isMethodSupported()`. The one true catch-all
(`ExpressionTypeResolverExtension`, no gate) is documented as the
discouraged last resort. Almost every extension is one class implementing one
interface; a framework package registers many.

## Working Decision

Split the two imperative hooks into narrow extension protocols, each declared
through a new `Manifest` field carrying value objects (the same registration
shape as the existing 10 declarative fields), each consumed at one
engine-indexed site. Keep the fat hooks as a deprecated, supported escape
valve so no plugin is forced to migrate at once.

The new protocol set is deliberately small — **four** new protocols plus a
rename — not PHPStan's fifty:

### 1. `DynamicReturnExtension` (from `flow_contribution_for`, return slot)

Per-call-site return-type contribution, receiver-gated.

```ruby
class DynamicReturnExtension
  # gate — the engine indexes by receiver class (reuses the
  # owns_receivers indexing machinery) and by method name
  def supported_receivers; end       # => Array[String]  (class names)
  def supports?(method_name); end    # => bool           (cheap)

  # payload — invoked only when both gates pass
  def return_type_for(call_node, scope); end  # => Rigor::FlowContribution | nil
end
```

Manifest field: `dynamic_returns:`. Engine site:
`MethodDispatcher#dispatch` (the existing plugin tier between the precise
tiers and `RbsDispatch`), but indexed by receiver class instead of fanned
out to all plugins.

### 2. `TypeSpecifyingExtension` (from `flow_contribution_for`, fact slots)

Predicate / assertion narrowing — the `truthy_facts` / `falsey_facts` /
`post_return_facts` slots — method-gated and edge-aware.

```ruby
class TypeSpecifyingExtension
  def supported_methods; end          # => Array[Symbol]   (gate)
  # payload — `edge` is :truthy / :falsey / :post_return (assertion)
  def specify(call_node, scope, edge); end  # => Rigor::FlowContribution | nil
end
```

Manifest field: `type_specifiers:`. Engine site:
`StatementEvaluator#apply_plugin_assertions`, indexed by method name. This
retires the second copy of the dispatch loop.

### 3. `NodeRule` (from `diagnostics_for_file`) — the keystone

Node-scoped diagnostic rule. **The engine owns the single AST walk** and
dispatches each node only to the rules registered for that node's class.

```ruby
class NodeRule
  def node_type; end                  # => Class (Prism::CallNode, …)  (gate)
  def check(node, scope, context); end  # => Array[Diagnostic]  (payload)
end
```

Manifest field: `node_rules:`. Engine site: the runner walks each file's
AST once, building a node-class → rules index, and calls `check` per matching
node. This is the change that **deletes the ~25 hand-rolled walkers** — the
reason they exist (raw `root` handed over) disappears. `context` carries the
lexical info ADR-2 promised but never delivered (current file, class/module,
method, visibility) so rules need not re-derive it by walking.

### 4. `FileRule` (escape valve, from `diagnostics_for_file`)

Whole-file rule for the genuine cross-file / index-validation cases that a
node-scoped rule cannot express (e.g. validating a discovered model index
against the file). Documented as the **last resort**, mirroring PHPStan's
`ExpressionTypeResolverExtension`.

```ruby
class FileRule
  def check(path, root, scope); end   # => Array[Diagnostic]
end
```

Manifest field: `file_rules:`. This is the migration target for the legacy
`diagnostics_for_file` hook: the old hook is reframed as "an unnamed,
deprecated `FileRule`."

### 5. `FactProvider` (rename of the existing `prepare` surface)

The `prepare(services)` + `produces:` / `consumes:` surface (ADR-9) is
*already* narrow and topologically ordered. This ADR only **names** it as a
protocol for symmetry and discoverability; no behavioural change. (PHPStan's
`Collector<TNode, TValue>` — structured per-node cross-file collection — is a
natural future extension of `FactProvider` layered on the engine-owned walk
that `NodeRule` introduces; deferred until a consumer needs it.)

### Backward compatibility

`flow_contribution_for` and `diagnostics_for_file` remain callable, marked
deprecated. Internally the loader adapts a legacy plugin into:

- `flow_contribution_for` → a single all-receivers `DynamicReturnExtension`
  + all-methods `TypeSpecifyingExtension` (i.e. the un-gated fan-out
  behaviour, preserved).
- `diagnostics_for_file` → a single `FileRule`.

So legacy plugins keep working with the legacy (un-indexed) cost; migrated
plugins get the indexed, testable surface. The declarative fields (10) are
untouched — sinatra / devise / dry-struct / typescript-utility-types and the
RBS/contract halves of hanami/web are already segregated and need no change.

### Machine-readable capability catalogue

Because every extension is now declared on the manifest, the engine can emit
a `rigor plugins --capabilities` catalogue: per plugin, the receivers it
contributes return types for, the methods it specifies, the node types it
rules on, the facts it produces/consumes. PHPStan has no machine-readable
`interface → tag` registry; Rigor can. This directly serves the AI-legibility
goal — an agent enumerates what every plugin does without reading a line of
self-gating code.

### Per-interface test harnesses

Ship a test base per protocol, the half of the goal that only narrow
interfaces make reachable:

- `NodeRuleTest` — feed a node + scope, assert the returned diagnostics
  (PHPStan `RuleTestCase` analogue).
- `DynamicReturnTest` / `TypeSpecifierTest` — feed a call + scope, assert the
  contributed type / facts (PHPStan `TypeInferenceTestCase` analogue).

The existing `run_plugin` end-to-end harness stays for integration coverage.

## Slices

1. **NodeRule + engine-owned walk** (highest leverage; retires the walker
   boilerplate and unlocks `NodeRuleTest`). Reframe legacy
   `diagnostics_for_file` as `FileRule`.
2. **`flow_contribution_for` split** into `DynamicReturnExtension` (receiver
   index, reuse `owns_receivers` machinery) + `TypeSpecifyingExtension`;
   collapse the duplicated dispatch loop into one indexed registry.
3. **`FactProvider` naming** + the capability catalogue command.
4. **Migrate the bundled plugins** off the legacy hooks, plugin-family at a
   time, deleting per-plugin walkers as the author-helper layer
   (review §1.3) becomes unnecessary for migrated plugins.

Slices 1–3 are engine-side and back-compatible; slice 4 is mechanical and
incremental.

### Slice 1 working decisions (implemented)

- **Registration is a class DSL, not a manifest field.** `node_rule` mirrors
  the existing `producer` DSL: the block runs through `instance_exec` so the
  plugin instance (`config`, `services`, `io_boundary`, `diagnostic`,
  `services.fact_store`) is in scope. A rule carries *logic* that needs the
  instance, so it cannot be a pure manifest value object built at class-load
  time like `block_as_methods` et al.
- **The engine owns the walk in `Base#node_rule_diagnostics`**, not the
  runner. Putting it on `Base` (over `Source::NodeWalker`) means the single
  dispatch point is shared by both the runner and the worker session with a
  one-line call each, and the walk is testable in isolation.
- **`node_type` matches by `node.is_a?(node_type)`** (not exact class), so a
  rule may register `Prism::Node` to see everything, or a concrete class for
  the common case.
- **Additive to `diagnostics_for_file`.** Both run; the legacy hook is the
  `FileRule` escape valve, unchanged. No plugin is forced to migrate.
- **The block receives `(node, scope, path)`.** The rich `ContextInfo`
  (lexical class/method/visibility) ADR-2 promised but never delivered stays
  deferred — `scope` already carries `self_type` and the narrowing facts most
  rules need; `path` is supplied for `diagnostic(node, path:)`.
- **Two-pass (collect-then-validate) plugins** — *resolved in slice 1c (see
  below).* A per-node `NodeRule` cannot express a file-local collect pass in
  the engine's single forward walk (a reference may precede its declaration),
  so a `node_file_context` pre-pass hook supplies it.

### Slice 1c — two-pass support (`node_file_context`, implemented)

`node_file_context { |root, scope| … }` runs once per file (via `instance_exec`)
before any node rule fires and returns an arbitrary file-local value threaded
to every `node_rule` block as its **fourth argument**. This is what lets a
*same-file* two-pass plugin drop its hand-rolled validate walk: the collect
pass computes the closed namespace once (it must complete before validation),
and the engine owns the validate walk. The fourth block arg is backward-
compatible — existing three-parameter blocks ignore it.

The split between the two two-pass shapes is deliberate:

- **Same-file collect** (e.g. statesman gathering declared states) → use
  `node_file_context`. The collect pass itself uses the shared
  `Source::NodeWalker`, so no hand-rolled traversal remains.
- **Cross-file collect** (e.g. activerecord's model index from `db/schema.rb`
  + `app/models`) → already belongs in `#prepare` + `services.fact_store`
  (the `FactProvider` surface). A node rule reads the published fact directly
  and needs no per-file context.

`rigor-statesman` is migrated as the first two-pass consumer: its `collect`
becomes a `node_file_context`, its `validate` a `node_rule(Prism::CallNode)`,
and both hand-rolled walks are gone (behaviour unchanged, integration spec
green).

### Slice 2 — `flow_contribution_for` split (design)

The second imperative hook, `flow_contribution_for(call_node:, scope:)`, is
split the same way slice 1 split `diagnostics_for_file`: narrow,
declaratively-gated class DSLs the engine indexes, with the fat hook kept as a
deprecated escape valve.

**Grounding fact.** Although `FlowContribution` carries nine slots, the engine
consults a plugin's `flow_contribution_for` at exactly two sites and reads
exactly two slots:

- `Inference::MethodDispatcher#try_plugin_contribution` merges all plugins'
  contributions and uses only `.return_type` (the per-call-site return type,
  ahead of `RbsDispatch`).
- `Inference::StatementEvaluator#apply_plugin_assertions` merges all plugins'
  contributions and uses only `.post_return_facts` (the assertion-edge
  narrowing).

So the split is clean and 1:1 with the two consumption sites:

**`dynamic_return` (→ `return_type`, receiver-gated).** A class DSL mirroring
`node_rule` / `producer`:

```ruby
dynamic_return receivers: ["ActiveRecord::Base"] do |call_node, scope|
  # self = plugin instance; return a Rigor::Type or nil
end
```

The engine calls the block only when the call's receiver type's class equals or
inherits from a declared `receivers:` entry (matched via
`Environment#class_ordering`, the now-standard mechanism); method-name and
type-shape refinement (e.g. a Mangrove carrier's `type_args`) stays in the
block. Returns a `Type` (or `nil` to decline). `receivers:` is the greppable,
indexable gate — the engine can group extensions by class instead of asking
every plugin about every call.

**`type_specifier` (→ `post_return_facts`, method-gated).** 

```ruby
type_specifier methods: [:assert_kind_of, :assert_instance_of] do |call_node, scope|
  # return an Array of post-return facts, or nil
end
```

The engine calls the block only when `call_node.name` is in the declared
`methods:`. Returns the same `post_return_facts` the merger already applies.
(The `truthy_facts` / `falsey_facts` edge slots are part of the same surface
for when condition-edge narrowing from plugins is wired; today only
`post_return_facts` is consumed, so the floor targets it.)

**Registration & gating.** Both are `producer`-style class DSLs (they carry
logic needing the plugin instance, so not manifest value objects), stored on
the class and aggregated by `Plugin::Registry` into a receiver-class index
(`dynamic_return`) and a method-name index (`type_specifier`). The engine
consults the matching subset at the two existing sites instead of the
duplicated `collect_plugin_contributions` fan-out — which is then deleted from
both `method_dispatcher.rb` and `statement_evaluator.rb` (the two copies the
slice-1 review flagged).

**Backward compatibility.** `flow_contribution_for` stays, deprecated, and the
engine still consults it (fat fan-out) at both sites, merged with the indexed
results. So the unmigrated consumers — `rigor-sorbet`, `rigor-activerecord`,
`rigor-activestorage`, `rigor-mangrove`, `rigor-rspec`, `rigor-minitest`, and
the example plugins — keep working untouched; migration to `dynamic_return` /
`type_specifier` is incremental, plugin-family at a time, each guarded by its
golden-master integration spec. Because flow contributions feed type narrowing
(and therefore diagnostics), every migration is verified behaviour-preserving
before landing — the false-positive floor is the binding constraint.

**Mapping of the consumers** (which surface each uses):

- `dynamic_return`: **mangrove** (unwrap → carried `type_args[0]`) — *migrated*.
- `type_specifier`: **minitest** (assertion narrowing) — *migrated*; rspec
  matcher narrowing — fits, migration pending.

**Outcome / the escape valve is load-bearing.** Migrating the consumers
surfaced that two contribution shapes the narrow DSLs deliberately do *not*
express are common, and those consumers legitimately stay on the deprecated
`flow_contribution_for` (exactly the role PHPStan's discouraged
`ExpressionTypeResolverExtension` catch-all plays):

- **Method-gated return type.** rspec's `let(:x) { create(:x) }` / `subject`
  binding sets the *return type* of a call gated by *method name* (`let` /
  `subject`), not by receiver class. `dynamic_return` is receiver-gated and
  `type_specifier` produces facts (not a return type), so neither fits.
  sorbet's `sig`-driven returns are similar — keyed on the called method
  having a sig, not on a fixed receiver class.
- **Dynamic receivers.** activestorage contributes `Attached::One` / `::Many`
  on the project's *discovered model* classes — a per-project set, not the
  static `receivers:` list `dynamic_return` declares.

These stay on the escape valve by design. A future `dynamic_return`
generalisation (an optional `methods:` gate for method-gated returns, and/or
a dynamic-receiver predicate) is the path to migrating them, deferred until
demand justifies widening the narrow surface.

## Relationship to other ADRs

- **ADR-2** — this revises its fat-hook model. The Scope / Type / Reflection
  / FactStore / IoBoundary service contracts and the 10 declarative fields
  are unchanged. The "broad expression/operator hooks deferred" stance is
  reinforced: `FileRule` is the only catch-all and is discouraged.
- **ADR-1** — flow-contribution semantics (the bundle fields, certainty
  rules, merge policy) are untouched; `DynamicReturnExtension` /
  `TypeSpecifyingExtension` still return `FlowContribution` bundles merged by
  the same `Merger`.
- **ADR-9** — `FactProvider` is the existing `prepare` surface, renamed.
- **ADR-16** — magic-member / dynamic-reflection needs are already covered by
  the macro substrate; this ADR adds no reflection protocol.
- **ADR-15** — narrow extension objects carry no per-run mutable dispatch
  state (unlike the `rigor-sorbet` identity-keyed hashes), which simplifies
  the Ractor per-worker instantiation question (ADR-2 § Open Questions).

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep the two fat hooks as-is for 1.0 | Rejected | Functionally sufficient, but the signatures freeze at 1.0 and the goals (AI-legibility, per-interface testing) are unreachable with self-gating hooks. The window is now. |
| Port PHPStan's full ~50-interface catalogue | Rejected | Over-segregation. Magic members are covered by ADR-16; dead-code / restricted-usage are demand-driven (review §7). Four protocols + a rename is the right granularity for Rigor today. |
| Remove the fat hooks outright (no escape valve) | Rejected | Forces a 31-plugin big-bang migration and leaves no expression for genuine whole-file rules. `FileRule` keeps the catch-all, discouraged. |
| A single generic "extension" object with optional methods | Rejected | That is the current fat `Plugin::Base`; it reproduces the self-gating and un-indexable problem this ADR solves. |
| Structured `Collector<TNode,TValue>` now | Deferred | Layer on `FactProvider` + the engine-owned walk once a consumer needs per-node cross-file collection. |

## Consequences

Positive:

- The plugin contract becomes uniformly declarative + engine-gated: 10
  existing fields plus four new protocols, all enumerable from the manifest.
- Per-interface test harnesses become possible; plugin tests stop asserting
  on whole-engine downstream behaviour.
- The engine owns the AST walk; ~25 hand-rolled walkers and the duplicated
  dispatch loop are retired.
- A capability catalogue gives AI agents (and humans) a complete, greppable
  map of every plugin's behaviour — a capability PHPStan lacks.
- Indexing removes the `plugins × files × nodes` fan-out (secondary).

Negative:

- A larger public protocol surface to document and keep stable.
- A migration period in which legacy and narrow plugins coexist (managed by
  the escape-valve adapter).
- Engine work to build and maintain the node-class and receiver indexes.
