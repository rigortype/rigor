# ADR-38 — Plugin-declared additional initializers

Status: **Accepted, 2026-06-02.** The def-form
`additional_initializers:` field + the `ScopeIndexer` nil-soundness-gate
wiring are implemented, with `rigor-minitest` shipping the first
declarations (`Minitest::Test` / `ActiveSupport::TestCase` /
`Test::Unit::TestCase` → `setup`). The block-form variant (RSpec
`before { }` / `let { }`, whose ivar writes live in a call block rather
than a `DefNode`) is deferred to a follow-on slice — it needs the ivar
write-collector to descend declared call blocks.

Records the decision to add a plugin `Manifest` field,
`additional_initializers:`, that lets a plugin declare which non-`initialize`
methods on a constrained class also establish instance-variable state — the
Ruby analogue of PHPStan's
[`AdditionalConstructorsExtension`](../../references/phpstan/website/src/developing-extensions/additional-constructors-extensions.md).
The field feeds one existing engine gate (`ScopeIndexer`'s read-before-write
nil soundness gate) so that ivars set in framework lifecycle methods
(`setup`, `after_initialize`, dependency-injection setters) stop being widened
with `nil` in sibling method bodies.

Grounding review:
[`docs/design/20260601-plugin-mechanism-pre-1.0-review.md`](../design/20260601-plugin-mechanism-pre-1.0-review.md)
§7.2 (selected as the highest-ROI, smallest extension-type to adopt from
PHPStan).

## Context

`ScopeIndexer#build_class_ivar_index` seeds per-class ivar types and, in
`contribute_read_before_write_nil!`, widens an ivar with `Constant[nil]` when
some method body reads it before writing it. The soundness gate that prevents
this from firing on normal code is in
`collect_read_before_write_evidence` (`lib/rigor/inference/scope_indexer.rb`):

```ruby
if def_node.name == :initialize
  init_set = (init_writes[class_name] ||= Set.new)
  seen_writes.each { |name| init_set << name }
  return
end
```

An ivar written in `initialize` is treated as set before any other method
runs (Ruby guarantees `initialize` runs first via `Class.new`), so a
read-before-write in a sibling method is **not** a runtime-nil case and the
nil contribution is suppressed.

The gate is hard-coded to the literal method name `:initialize`. But Ruby
frameworks routinely initialize ivars in *other* lifecycle methods that run
before the "body" methods:

- **Minitest / ActiveSupport::TestCase** — `def setup; @conn = …; end`, read in
  every `def test_*`.
- **Rails models** — `after_initialize` / `before_validation` callback methods
  defined as ordinary `def`s.
- **Dependency-injection setters** — `def inject(x); @x = x; end` called by a
  container before use.

In all of these the ivar is reliably set before the reading method runs, but
because the writing method is not literally named `initialize`, the engine
treats the read as read-before-write and widens with `nil`. Downstream that
turns `@conn.query` into a call on `Conn | nil` and surfaces a nil-receiver
diagnostic — a **false positive on working code**, which the project's
false-positive discipline ranks as the worst failure mode.

PHPStan solved the symmetric problem (its `checkUninitializedProperties`
reporting `setUp()`-initialized properties) with two layers: a declarative
`additionalConstructors:` config list of `Class::method`, and an
`AdditionalConstructorsExtension` interface for dynamic cases ("all subclasses
of X"). The declarative layer covers the common case; the extension covers the
rest. Rigor already has the declarative-manifest mechanism (the ten
engine-gated fields of ADR-2 / ADR-37); this ADR adds one more field of the
same shape.

### Why this is FP-safe

The field only ever *suppresses* a nil contribution — it makes the analyzer
strictly more lenient, never stricter. A missed match simply fails to help
(the existing nil widening stands); a spurious match removes a nil widening
that may or may not have been warranted. The downside of over-matching is
therefore the same trade-off the existing `initialize` gate already accepts,
and it is opt-in per plugin/config. It cannot, by construction, introduce a
new false positive. This is what makes it the lowest-risk extension-type to
adopt before 1.0.

## Working Decision

Add a `Manifest` field `additional_initializers:` carrying
`Rigor::Plugin::AdditionalInitializer` value objects:

```ruby
manifest(
  id: "minitest",
  version: "0.1.0",
  additional_initializers: [
    Rigor::Plugin::AdditionalInitializer.new(
      receiver_constraint: "Minitest::Test",
      methods: [:setup]
    )
  ]
)
```

- `receiver_constraint` — fully-qualified class name (String). The entry
  applies to that class and its subclasses.
- `methods` — Array of Symbol method names treated, on a matching class, as
  initializers for the read-before-write soundness gate.

`Plugin::Registry#additional_initializers` aggregates the entries across
loaded plugins (the same flat `plugins.flat_map { … }` aggregation the other
manifest fields use).

`ScopeIndexer` consumes them at the single existing gate. The class match
reuses `Environment#class_ordering` — the exact mechanism
`Inference::MacroBlockSelfType` (ADR-16 Tier A) uses to match a Sinatra app
class against `Sinatra::Base` — so transitive subclass relationships resolve
through the same class graph, and any resolution failure degrades to
"no match" (FP-safe). The environment is reached through the pre-pass's
`default_scope.environment`; the registry through
`environment.plugin_registry`.

The gate becomes:

```ruby
if def_node.name == :initialize ||
   additional_initializer?(class_name, def_node.name, default_scope)
  # … fold writes into init_writes, suppress nil contribution …
end
```

### v1 scope and deferral

v1 handles **`def`-form** lifecycle methods (`def setup`, `def after_initialize`,
DI setters) — the methods `collect_read_before_write_evidence` already walks
(it descends `Prism::DefNode` bodies).

**Deferred:** the **block-form** establishment idioms — RSpec
`before { @x = … }` / `let(:x) { … }`. Their ivar writes live inside a block
passed to a method call, not a `DefNode`, so the ivar write collector
(`ivar_write_collector` / `collect_def_ivar_writes`) does not currently see
them at all. Supporting them needs the collector to descend
`block_as_initializer`-declared call blocks first; that is a larger change to
the write-collection pass and is split out. (Tracked as a follow-on slice; the
manifest field shape already anticipates it — a future `block_methods:` slot or
a `kind:` discriminator can extend the same value object.)

## Slices

1. **This ADR (the `def`-form floor).** Value object + manifest field +
   validation + registry aggregator + `ScopeIndexer` gate extension + tests.
   Wire `rigor-minitest` (`Minitest::Test`/`ActiveSupport::TestCase` → `setup`)
   as the first consumer.
2. **Block-form (`before`/`let`)** establishment for `rigor-rspec` — deferred,
   demand-driven, needs the write collector to descend declared call blocks.
3. **Dynamic logic hook** (the full `AdditionalConstructorsExtension`
   analogue, "compute the initializer set per class") — deferred; the
   declarative field covers the known framework cases and no dynamic case is
   yet demonstrated.

## Relationship to other ADRs

- **ADR-2 / ADR-37** — this is one more declarative, engine-gated manifest
  field of the kind ADR-37 holds up as the good model; it needs no imperative
  hook.
- **ADR-16** — reuses the `Environment#class_ordering` receiver-constraint
  match `MacroBlockSelfType` established.
- **ADR-5 (robustness) / false-positive discipline** — the motivating value:
  the field exists to stop frightening working framework code.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A flat global config list (`additional_initializers: ["Minitest::Test#setup"]` in `.rigor.yml`) instead of a plugin field | Deferred | A project-level config knob can be added later for non-plugin cases; the plugin field is the right home for framework knowledge (ships with `rigor-minitest`, versioned with the framework support). |
| Treat *every* method that writes an ivar before any read as an initializer | Rejected | Unsound generalisation; would suppress genuine read-before-write nil cases far beyond lifecycle methods. The constraint to declared (class, method) pairs is the safety boundary. |
| Match by direct superclass only (skip `class_ordering`) | Rejected | Misses the common transitive case (`FooTest < ApplicationTestCase < ActiveSupport::TestCase`); `class_ordering` already resolves it and degrades safely. |
| Block-form (`before`/`let`) in v1 | Deferred | Needs a separate change to the ivar write-collection pass (block bodies are not walked today); split to keep this slice small and verifiable. |

## Consequences

Positive:

- Removes a class of false positives in test and Rails code (`@x` set in
  `setup`/callbacks read as `T | nil`) — directly serves the project's
  top-tier value.
- Tiny, additive surface: one value object, one manifest field, one gate
  extension. No new imperative hook, no engine-walk change.
- Demonstrates the ADR-37 "declarative, engine-gated field" model on a fresh
  capability and gives `rigor-minitest` an immediate precision win.

Negative:

- A spurious or over-broad declaration silently suppresses a nil widening that
  might have been warranted (bounded by the opt-in, FP-safe direction).
- The block-form gap (`before`/`let`) means RSpec users see no benefit until
  slice 2; the field's documentation must state the `def`-form limitation.
