# ADR-18 — Substrate per-call-site return-type DSL

Status: **proposed, 2026-05-16.** Amends [ADR-16](16-macro-expansion.md)'s
macro-expansion substrate to support per-call-site return types
on synthesised methods. Builds on the v0.1.6 work that landed
`rigor-dry-types` ([ADR-12](12-dry-rb-packaging.md)) and the
ADR-9 `:dry_type_aliases` fact: the natural consumer
(`rigor-dry-struct` precision uplift) cannot land without this
amendment.

## Context

The ADR-16 substrate today represents synthesised methods as
**(receiver, method name) → static `returns:` String**:

```ruby
heredoc_templates: [
  Rigor::Plugin::Macro::HeredocTemplate.new(
    receiver_constraint: "Dry::Struct",
    method_name: :attribute,
    symbol_arg_position: 0,
    emit: [{ name: "\#{name}", returns: "Object" }]
  )
]
```

The `returns:` string is **static per template** — same value
for every `attribute :city, X` call regardless of the second
argument's source representation. Slice 6b promotes the string
through `Environment#nominal_for_name`, so the floor today is:

> Every `address.city` reader returns `Nominal[Object]`,
> regardless of whether `:city` was declared `Types::String`
> or `Types::Integer` or `Types::Bool`.

The user-visible gap surfaces when a plugin like `rigor-dry-struct`
wants to **vary the synthetic reader's return type by call-site
argument**:

- `attribute :city, Types::String` → `address.city` should be
  `Nominal[String]`.
- `attribute :age, Types::Integer` → `address.age` should be
  `Nominal[Integer]`.

This is a **per-call-site** return type — same template, same
receiver, same method name, different argument → different
synthesised return.

The ADR-16 substrate has no DSL for this today. Plugin authors
who want per-call precision today resort to writing a hand-rolled
walker (defeats the point of declarative substrate manifests).

## Decision

Extend `Rigor::Plugin::Macro::HeredocTemplate` (and `TraitRegistry`
in the same shape) with a **`returns_from_arg:`** field on each
`emit:` row:

```ruby
emit: [
  {
    name: "\#{name}",
    returns_from_arg: {
      position: 1,
      lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
    }
  }
]
```

When present, the substrate's pre-pass:

1. Reads the argument node at `position:` from the call site
   (e.g., the AST node `Types::String` from `attribute :city,
   Types::String`).
2. Resolves the argument's source representation into a String
   (the qualified constant name; e.g., `"Types::String"`).
3. Looks up that String in the named cross-plugin fact (e.g.,
   `:dry_type_aliases` published by `rigor-dry-types`).
4. Uses the looked-up underlying class name as the synthetic
   method's `return_type:` String (the existing slice-6b
   promotion path then resolves it through
   `Environment#nominal_for_name`).

The `lookup_via:` shape is **declarative** — no plugin code
runs at substrate-pre-pass time. The plugin author declares
"which fact to consult"; the substrate handles the lookup.

### Resolution semantics

When the per-call-site argument's source representation cannot
be resolved into a String (e.g., the argument is a method call,
a complex expression, or a constant the plugin author didn't
expect):

- **No fact match** → fall back to the row's optional `returns:`
  String (the slice-6b static default).
- **No `returns:` either** → fall back to `Dynamic[Top]` (the
  pre-ADR-16-slice-6 substrate floor).

This three-tier fallback keeps `returns_from_arg:` strictly
additive — plugins that don't declare it continue to use the
static `returns:` path unchanged.

### Argument shape recognition

The substrate's argument source-representation extractor MUST
handle the following Prism shapes at the floor:

- `Prism::ConstantReadNode` — bare constant (`String`).
- `Prism::ConstantPathNode` — qualified constant
  (`Types::String`, `App::Types::Coercible::Integer`).
- Anything else — return nil, triggering the fallback chain.

Method-call arguments (`Types::String.constrained(format: …)`)
are out of scope for the floor — they need either the ADR-10
walker's heuristic machinery (Phase B return type for the chain)
or a separate "chain head resolver" addition. Recorded as
demand-driven follow-up.

### Public-API drift surface

This amendment adds:

- `Rigor::Plugin::Macro::HeredocTemplate::Emit#returns_from_arg`
  attr_reader (new frozen-Data field on the existing Emit row).
  Default `nil`; existing manifests continue to work.
- A new validator branch in `HeredocTemplate.new` that ensures
  exactly one of `returns:` / `returns_from_arg:` is present
  per Emit row (both nil is also valid; falls back to
  `Dynamic[Top]`).
- `Rigor::Inference::SyntheticMethod#return_type_source` slot
  (Symbol) recording which path resolved the return type:
  `:static`, `:from_arg`, or `:fallback`. Surfaces in cache
  descriptor `to_h` for debugging; not a load-bearing
  external surface.
- `Rigor::Inference::SyntheticMethodScanner` consults the
  per-run `Plugin::FactStore` to resolve `returns_from_arg:`
  lookups during the pre-pass. The scanner gains a
  `fact_store:` keyword argument (default `nil` → all
  `returns_from_arg:` rows fall back to `returns:` / Dynamic).

All updates land in
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
in the same commit as the implementing slice.

## Implementation slicing

Recommended order; each slice independently shippable.

1. **`HeredocTemplate::Emit` field + validation.** Add
   `returns_from_arg:` slot; validator accepts the new shape;
   manifest serialisation round-trips it. No substrate
   behaviour change yet.
2. **Scanner argument-position extraction.** Pre-pass reads
   the argument node at the declared `position:` and stashes
   the source representation (qualified constant name) into
   the emitted `SyntheticMethod`.
3. **Fact-store lookup during pre-pass.** Scanner gains
   `fact_store:` keyword; consults the named fact's published
   value; populates `SyntheticMethod#return_type` with the
   resolved underlying class name. Falls back to static
   `returns:` / Dynamic per the contract.
4. **TraitRegistry parity (optional).** If demand surfaces,
   the same `returns_from_arg:` row applies to
   `Plugin::Macro::TraitRegistry`'s emit table.
5. **Documentation + worked consumer.** Update ADR-16,
   handbook plugin chapter; ship the corresponding
   `rigor-dry-struct` manifest update so its `attribute :city,
   Types::String` precision-promotes through this path. This
   is the slice that delivers the user-visible payoff.

## Working decisions

### WD1 — Why declarative `lookup_via:`, not a callback?

A Proc-shaped callback (`returns_from_arg: { position: 1,
resolve: ->(node, services) { … } }`) would let plugin
authors execute arbitrary Ruby at substrate-pre-pass time.
That breaks two ADR-2 contracts:

1. **Plugins MUST NOT execute application code at analysis
   time.** Substrate-pre-pass is analysis time; a callback
   here would be analyser-driven user-code execution.
2. **Plugins MUST be `Ractor.shareable?` at construction.**
   Proc bodies referencing closure state aren't shareable
   under [ADR-15](15-ractor-concurrency.md) Phase 4.

A declarative shape (the cross-plugin fact name + the
argument position) sidesteps both. The substrate executes
the lookup; the plugin author declares the policy.

### WD2 — Why per-row `returns_from_arg:`, not per-template?

A template can emit multiple synthetic methods per call site
(e.g., a future `attribute :city, Types::String` template
emitting both `Address#city` reader and `Address#city=`
setter). Each emit row may want a different return-type
resolution policy (the reader returns the type; the setter
returns the type or `self`). Per-row keeps the DSL flexible
without forcing all emissions onto the same path.

### WD3 — Why `:dry_type_aliases` as the canonical example?

It's the first concrete consumer (`rigor-dry-struct` slice
landed in v0.1.5 alongside `rigor-dry-types` slice 1 in
v0.1.6). The pattern generalises: any plugin family that
publishes a cross-plugin fact (`:helper_table` for routes,
`:model_index` for AR, …) can host its own
`returns_from_arg:` consumers.

### WD4 — Boundary with ADR-10 walker heuristic

The walker's `ReturnTypeHeuristic` extracts a return type
from a method *body*'s tail expression. The amendment's
`returns_from_arg:` extracts a return type from a call
*site*'s argument. Both surfaces produce a `Rigor::Type::*`
or nil; both feed into the same `Type::Combinator.dynamic(facet)`
wrapping at the dispatcher. The two paths are orthogonal —
walker is "what does the gem's method return?", amendment
is "what does the user's substrate call declare?". A future
slice could reuse the heuristic to handle chained-call
arguments (`Types::String.constrained(...)`) by extracting
the chain head's underlying class.

### WD5 — Cache descriptor implications

`returns_from_arg:` consumes the cross-plugin fact's value at
pre-pass time. The cache descriptor for the pre-pass therefore
needs to depend on the fact's content digest (so a change in
`rigor-dry-types`'s published aliases invalidates the
`SyntheticMethodIndex` cache). Existing
`Cache::Descriptor::PluginEntry` carries plugin version +
config; extending it with a `fact_digest:` per produced fact
is the slice-3 work.

## Alternatives considered

- **Hand-rolled walker per dry-* consumer.** Rejected per
  ADR-16's design goal (declarative manifests beat per-plugin
  walkers).
- **Inline Proc callback** (Procs in manifest). Rejected per
  WD1.
- **Resolve at dispatch time, not pre-pass time.** The
  dispatcher already has access to `Environment#fact_store`
  through `Plugin::Services`; we could defer the
  `returns_from_arg:` lookup until call dispatch instead of
  pre-pass. Rejected: the lookup result is identical per
  call site across the whole run, and per-call-site dispatch
  cost would multiply by the call count. Pre-pass amortises
  over the discovery walk.
- **Cross-plugin TypeNodeResolver chain.** Recorded as a
  related but separate ADR-13 follow-up: routing
  `synthetic.return_type` strings through the
  `Plugin::TypeNodeResolver` chain unlocks parameterised
  forms (`Array[String]`, `Pick<T, K>`). Orthogonal to
  this amendment.

## Open questions

- **Should `returns_from_arg:` accept multiple positions?**
  E.g., `Tuple[A, B] = (A, B)` style — return type derived
  from multiple arguments. Deferred to demand.
- **Should `lookup_via:` accept a list of fact channels for
  fallback chaining?** A plugin might want to consult
  `:dry_type_aliases` then fall back to `:custom_aliases`.
  Decision deferred to slice 3 if a concrete case surfaces.
- **Should the substrate emit a diagnostic when
  `returns_from_arg:` declines (no fact match)?** Today the
  silent fallback to `returns:` / Dynamic is the simplest
  contract; a future `dynamic.substrate.unresolved-arg`
  `:info` diagnostic could surface the cases for debugging.
  Deferred to slice 5 (documentation + worked consumer)
  feedback.

## Revision history

- 2026-05-16 — initial proposal. Triggered by the v0.1.6
  scoping discussion: the often-misnamed "rigor-dry-struct
  precision via rigor-dry-types fact" task surfaced as
  needing a substrate amendment rather than a single slice
  of ADR-16's existing slicing plan. ADR-12 slice 1 (the
  `rigor-dry-types` plugin) landed the natural consumer in
  v0.1.6; this amendment provides the substrate-side
  mechanism the consumer needs.
