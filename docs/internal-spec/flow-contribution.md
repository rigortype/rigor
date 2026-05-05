# Flow Contribution Bundle — `Rigor::FlowContribution`

Status: **Public read shape (v0.0.9 group B).** This document
fixes the surface every flow-contribution producer (built-in
narrowing rules today, `RBS::Extended` annotations and plugin
authors after v0.1.0) hands the analyzer at a single call edge.
The merge policy that consumes these bundles is owned by
[ADR-2 § "Plugin Contribution Merging"](../adr/2-extension-api.md);
v0.0.9 ships only the bundle struct itself — the merger lands
alongside the plugin API in v0.1.0.

## Public surface

```ruby
contribution = Rigor::FlowContribution.new(
  return_type: Rigor::Type::Combinator.constant_of(42),
  truthy_facts: [...],
  falsey_facts: [...],
  post_return_facts: [...],
  mutations: [...],
  invalidations: [...],
  exceptional: nil,
  role_conformance: [...],
  provenance: Rigor::FlowContribution::Provenance.new(
    source_family: "plugin.my-gem",
    plugin_id: "my-gem",
    node: ast_node,
    descriptor: cache_descriptor
  )
)
```

Every keyword argument is optional. A slot left unset means "this
contribution does not assert anything in that dimension" and the
merge policy treats it as absent. Bundles are frozen on
construction; collection slots are duped and frozen so callers
cannot mutate them after the fact.

## Slot definitions

The eight content slots match
[ADR-2 § "Flow Contribution Bundle"](../adr/2-extension-api.md):

| Slot | Type | Meaning |
| --- | --- | --- |
| `return_type` | type carrier or `nil` | Normal-edge return type. Plugins MAY narrow within the selected RBS contract; an incompatible return becomes a conflict diagnostic per the merge policy. |
| `truthy_facts` | `Array` or `nil` | Facts that hold only on the truthy control-flow edge. Edge-local: a truthy-edge fact does NOT imply its falsey-edge complement unless the contribution explicitly supplies it. |
| `falsey_facts` | `Array` or `nil` | Dual of `truthy_facts`. |
| `post_return_facts` | `Array` or `nil` | Facts that hold after the call returns normally on every edge. The carrier for assertion-style contributions (`%a{rigor:v1:assert ...}`). |
| `mutations` | `Array` or `nil` | Receiver and argument mutation effects. Conflicts with `pure`-style declarations are diagnostics. |
| `invalidations` | `Array` or `nil` | Targeted fact invalidations beyond what `mutations` already implies. |
| `exceptional` | effect tag or `nil` | Non-returning, raising, or unreachable effect. |
| `role_conformance` | `Array` or `nil` | Capability-role conformance facts the contribution provides. |

The shape of the values inside the collection slots is
intentionally not pinned in v0.0.9. The merger that lands in
v0.1.0 will define a tagged element form; until then
contributions are free to use the analyzer-internal narrowing
representation that already drives built-in rules.

## Provenance

```ruby
Rigor::FlowContribution::Provenance = Data.define(
  :source_family,  # Symbol or String — :builtin / :rbs_extended / "plugin.<id>" / ...
  :plugin_id,      # String or nil
  :node,           # AST node or nil — the Prism node carrying the annotation
  :descriptor      # Rigor::Cache::Descriptor or nil — cache slice this contribution attaches to
)

Rigor::FlowContribution::Provenance.builtin
# => #<data Provenance source_family=:builtin, plugin_id=nil, node=nil, descriptor=nil>
```

`source_family` mirrors `Rigor::Analysis::Diagnostic#source_family`
so attribution composes cleanly: a diagnostic produced by a
plugin contribution carries the same source-family string the
contribution declared. Cache invalidation runs through
`descriptor` per [ADR-2 § "Registration, Configuration, and
Caching"](../adr/2-extension-api.md) and the
[`Rigor::Cache::Descriptor`](cache.md) schema.

## Equality, hashing, and emptiness

- `==` compares the bundle structurally (every content slot plus
  provenance). `hash` is consistent with `==`.
- `to_h` returns a Hash keyed by every slot name plus
  `:provenance` (whose value is the Provenance Data's `to_h`).
- `empty?` is true when every content slot is `nil` or an empty
  collection. Provenance does NOT count toward emptiness — an
  empty bundle still carries source attribution.

## Producers wired through the bundle

Internal producers may surface their contributions as
`FlowContribution`s alongside their typed-Data carriers. The
typed carriers (`PredicateEffect`, `AssertEffect`, …) keep
serving the analyzer-internal narrowing / dispatch machinery;
the bundle is the public packaging for the v0.1.0 contribution
merger and for diagnostic / documentation surfaces that want a
single shape across producers.

### `Rigor::RbsExtended.read_flow_contribution(method_def) -> FlowContribution | nil`

Rolls up every recognised RBS::Extended directive on a single
RBS method definition into one bundle:

| Directive | Bundle slot |
| --- | --- |
| `rigor:v1:predicate-if-true ...`  | `truthy_facts` (each entry an `RbsExtended::PredicateEffect`) |
| `rigor:v1:predicate-if-false ...` | `falsey_facts` (`PredicateEffect`s) |
| `rigor:v1:assert ...`             | `post_return_facts` (each entry an `AssertEffect`) |
| `rigor:v1:assert-if-true ...`     | `post_return_facts` (`AssertEffect` with `condition: :if_truthy_return`) |
| `rigor:v1:assert-if-false ...`    | `post_return_facts` (`AssertEffect` with `condition: :if_falsey_return`) |
| `rigor:v1:return: ...`            | `return_type` (a `Rigor::Type`) |

Slots that have no contributions stay `nil` (rather than empty
collections) so the bundle's `#empty?` rule applies cleanly.

`provenance` is the shared
`Rigor::RbsExtended::RBS_EXTENDED_PROVENANCE`:

```ruby
Rigor::FlowContribution::Provenance.new(
  source_family: :rbs_extended,
  plugin_id: nil,
  node: nil,
  descriptor: nil
)
```

`source_family: :rbs_extended` lines up with the diagnostic-
provenance prefix introduced in v0.0.8 slice 5, so a diagnostic
sourced from an RBS::Extended directive can carry the same
attribution string.

`param: <name>` directives are intentionally NOT bundled — they
refine the call's signature contract rather than its flow facts
and do not fit ADR-2 § "Flow Contribution Bundle" slot
semantics. Callers that care about parameter contracts keep
using `RbsExtended.read_param_type_overrides` /
`RbsExtended.param_type_override_map`.

## Element-list flattening (deferred)

ADR-2 mentions an analyzer-internal flattening of each bundle
into a tagged element list keyed by `(target, flow edge, effect
kind)`. That representation is the implementation surface the
merge policy will consume; v0.0.9 deliberately does not ship it.
The merger and the element-list form land together in v0.1.0.
Plugin authors should not rely on the element-list form.

## Stability

The constructor surface and slot names are stable as a v0.0.x
public read shape. Adding a new slot is a public-API expansion
that should be accompanied by an ADR-2 amendment plus a
schema-version note in this document. Renaming or removing a
slot is a breaking change that requires a major-version bump.
