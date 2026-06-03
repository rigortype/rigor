# Macro / DSL Expansion Substrate

The **macro substrate** is the family of plugin-manifest value objects a
plugin author declares to teach Rigor the call shapes a metaprogramming
library exposes to its users — the `define_method` / `class_eval` /
`const_missing` patterns the engine cannot see by reading source alone.
It was introduced by [ADR-16](../adr/16-macro-expansion.md) (four tiers),
extended by [ADR-18](../adr/18-substrate-per-call-site-return-type.md)
(per-call-site return type) and
[ADR-36](../adr/36-mangrove-enum-nested-class-emission.md) (nested-class
emission).

This document specifies the **plugin-author-facing value-object shapes**:
the fields, their types, their validation, and the identity/immutability
contract every entry satisfies. The shapes are the durable contract a
plugin gem is authored against. The engine-side consumption — the
dispatcher's synthetic-method tier and `Environment#synthetic_method_index`
— is normative in [`inference-engine.md`](inference-engine.md) (the
dispatcher tier ordering + the `Environment` query surface); the
floor/ceiling delivery policy and the per-tier rationale are in the ADRs.

All five classes live under the `Rigor::Plugin::Macro` namespace
(`lib/rigor/plugin/macro/`) and are declared through the corresponding
`Manifest` slots documented in [`plugin.md`](plugin.md#rigorpluginmanifest):
`block_as_methods:`, `heredoc_templates:`, `trait_registries:`,
`external_files:`, `nested_class_templates:`.

## Common value-object contract

Every macro value object MUST satisfy the same identity and immutability
rules (consistent with the rest of the plugin-contract carriers):

- **Frozen at construction.** All fields are dup-frozen in `#initialize`
  and the instance itself is frozen. `Ractor.shareable?` MUST return
  true after construction (ADR-15 Phase 1), so a materialised plugin
  carries its substrate declarations across the fork/Ractor boundary.
- **Validated at construction.** Each field is checked in `#initialize`;
  a malformed declaration MUST raise `ArgumentError` at manifest-build
  time (load), not fail silently at scan time. The `Manifest` slot
  re-validates that every entry is an instance of the expected class.
- **Value identity.** `#==` / `#eql?` / `#hash` compare by field value
  (most via the canonical `#to_h`), so two structurally-equal
  declarations are interchangeable.
- **`#to_h` round-trips into the cache key.** Every class exposes a
  string-keyed `#to_h`; the manifest folds it into `Manifest#to_h`,
  which is cache-key-stable. A plugin author MAY declare any tier today
  even where the engine integration is deferred (see _Implementation
  status_ below): the declaration round-trips and is exposed on the
  matching `Manifest` reader, and is forward-compatible when the engine
  slice lands.
- **`receiver_constraint` matching.** Where a tier carries a
  `receiver_constraint` (all but `ExternalFile`), the entry fires when
  the call's lexical receiver class **equals or inherits from** that
  fully-qualified name, matched through `Environment#class_ordering`.

## Tier A — `BlockAsMethod` (`block_as_methods:`)

"The block passed to a class-level DSL call of one of `verbs` runs as an
instance method on `receiver_constraint`'s subclass tree, with `self`
typed accordingly." Canonical target: Sinatra's `get '/path' { ... }`
(the block literally becomes the route method body).

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name the call's lexical receiver must be or inherit from. |
| `verbs` | non-empty `Array<Symbol>` | DSL method names (coerced from `Symbol`/non-empty `String`) whose block runs as an instance method. |
| `self_type` | `Symbol` | The `self`-binding kind inside the block. Default and only currently-valid value: `:receiver_instance`. `:receiver_singleton` / `:dsl_recorder` are reserved names, not yet accepted. |

## Tier C — `HeredocTemplate` (`heredoc_templates:`)

"The class-level call `<receiver_constraint>.<method_name>(name_arg, …)`
emits synthetic methods on the calling class, with names interpolating
the source-visible literal argument at `symbol_arg_position`." Canonical
targets: dry-struct's `attribute :name, T` and ActiveStorage's
`has_one_attached :avatar`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name (equals-or-inherits). |
| `method_name` | `Symbol` | The DSL method (from `Symbol`/non-empty `String`). |
| `symbol_arg_position` | `Integer >= 0` | Default `0`. The argument index whose literal Symbol value becomes the `name` interpolated into each emit row. |
| `emit` | `Array<Emit>` | Instance methods to synthesise on the calling class (coerced from `Hash`). |
| `class_level_emit` | `Array<Emit>` | Same shape; the synthesised methods are singleton (class-level). |

`NAME_PLACEHOLDER` is the literal `"#{name}"` token an emit row's `name:`
template carries for interpolation.

### `HeredocTemplate::Emit`

One row of an emit table.

| Field | Type | Notes |
| --- | --- | --- |
| `name` | non-empty `String` | The synthetic method's name template; a `"#{name}"` placeholder is interpolated with the call-site literal symbol at `symbol_arg_position`. |
| `returns` | non-empty `String` or `nil` | The declared return type name, resolved via `Environment#nominal_for_name`. When both `returns` and `returns_from_arg` are `nil`, the synthesised method's return falls back to `Dynamic[Top]` per the ADR-16 WD13 floor. |
| `returns_from_arg` | `ReturnsFromArg` or `nil` | A per-call-site return type (ADR-18), coerced from a `Hash`. |

### `HeredocTemplate::ReturnsFromArg` (ADR-18)

A sibling class of `Emit` under `HeredocTemplate` (not nested inside
`Emit`), referenced by `Emit#returns_from_arg`. Declares that the
synthesised method's return type comes from a **call-site argument's
source representation**, looked up in a cross-plugin fact channel
([ADR-9](../adr/9-cross-plugin-api.md) `FactStore`). Authoring shape:

```ruby
returns_from_arg: { position: 1, lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases } }
```

| Field | Type | Notes |
| --- | --- | --- |
| `position` | `Integer >= 0` | The call-site argument index whose source representation is the lookup key. |
| `plugin_id` | non-empty `String` | The producing plugin (from `lookup_via:`). |
| `fact` | `Symbol` | The fact name to read from that plugin's `FactStore` bucket (from `lookup_via:`). |

`.coerce(value)` accepts a `Hash` (requiring a `lookup_via:` Hash), a
`ReturnsFromArg`, or `nil`, and raises on any other shape.

## Tier B — `TraitRegistry` (`trait_registries:`)

"The class-level call `<receiver_constraint>.<method_name>(:trait_a,
:trait_b, …)` effectively includes the modules named in
`modules_by_symbol[:trait_a]` + `[:trait_b]` (plus any `always_included`
modules) on the calling class." Canonical target: Devise's `devise
:database_authenticatable, :recoverable`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name (equals-or-inherits). |
| `method_name` | `Symbol` | The DSL method (e.g. `:devise`). |
| `symbol_arg_position` | `:rest` or `Integer >= 0` | `:rest` (default, the only form the scanner honours) treats every positional Symbol arg as a trait; an Integer index is reserved for a future single-trait shape. |
| `modules_by_symbol` | `Hash<Symbol, String>` | Maps each recognised trait symbol to a FQ module name. A symbol absent from the table falls through (the scanner emits a `macro.tier_b.unknown-trait` `:info` marker). |
| `always_included` | `Array<String>` | FQ module names added at every matching call site even when no symbols match. |

`#module_for(symbol)` returns the FQ module name for a trait symbol, or
`nil` when unknown. Tier B is **not** subject to the Tier C `Dynamic[T]`
floor: the synthesised methods replay the included modules' authored RBS
return types (ADR-5 robustness — the substrate does not fabricate
precision it was not given).

## Tier D — `ExternalFile` (`external_files:`)

"Files matching `glob` are analysed as if their body were pasted at a
call site whose `self` is an instance of `receiver_type` (and whose
`@ivar` facts come from `bound_ivars`)." Motivating cases: Redmine's
`WebhookPayload#instance_eval(File.read(path), …)`; tDiary's plugin
loader.

| Field | Type | Notes |
| --- | --- | --- |
| `glob` | non-empty `String` | File pattern, interpreted relative to the project root (the directory holding `.rigor.yml`). |
| `receiver_type` | non-empty `String` | The class name `self` binds to inside the loaded file. |
| `bound_ivars` | `Hash<String, String>` | Each key MUST start with `@`; each value is a non-empty type-name String. Pre-bound as ivar facts in the file-entry scope. |

> **Declaration-only (engine integration deferred).** Tier D ships the
> value class + manifest slot only; the engine integration that adds
> matched files to the analysis set, narrows the file-entry `self_type`,
> and pre-binds `bound_ivars` is queued for ADR-16 slice 5b, gated on
> demonstrated demand. A declared entry round-trips and is exposed on
> `Manifest#external_files` but the substrate does not yet act on it.

## Nested-class tier — `NestedClassTemplate` (`nested_class_templates:`, ADR-36)

Where Tier C synthesises *methods*, this tier synthesises *nested
subclasses* declared by an enum-shaped block DSL. Motivating shape:
Mangrove's `variants do variant Circle, Float end`, where each `variant
<Const>, <Type>` row mints a nested subclass `Shape::Circle < Shape`
carrying `#inner : <Type>`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ module name the enclosing class must `extend` for the block to be recognised (e.g. `"Mangrove::Enum"`). |
| `block_method` | `Symbol` | The enclosing DSL block. Default `:variants`. |
| `variant_method` | `Symbol` | Each declaration call inside the block. Default `:variant`. |
| `name_arg_position` | `Integer >= 0` | Default `0`. The argument index whose literal constant names the nested subclass. |
| `inner_arg_position` | `Integer >= 0` | Default `1`. The argument index whose type expression becomes the `#inner` reader's return type. A constant type argument resolves; a non-constant inner shape degrades to `Dynamic[Top]`. |
| `inner_reader` | `Symbol` | The payload reader synthesised on each variant subclass. Default `:inner`. |

The `sealed`-parent fact + `is_a?` cross-variant exhaustive narrowing
(ADR-36 WD3) is the deferred ceiling.

## Implementation status

| Tier | Class | Manifest slot | Engine status |
| --- | --- | --- | --- |
| A | `BlockAsMethod` | `block_as_methods:` | Live (worked consumer: `rigor-sinatra`). |
| B | `TraitRegistry` | `trait_registries:` | Live (worked consumer: `rigor-devise`). |
| C | `HeredocTemplate` (+ `Emit` / `ReturnsFromArg`) | `heredoc_templates:` | Live (worked consumers: `rigor-dry-struct` / `rigor-dry-types`); `returns_from_arg` per-call-site lookup is the ADR-18 layer. |
| D | `ExternalFile` | `external_files:` | Declaration-only — engine integration deferred to ADR-16 slice 5b. |
| nested-class | `NestedClassTemplate` | `nested_class_templates:` | Live, Slice A (worked consumer: `rigor-mangrove`); sealed-parent exhaustiveness deferred. |

Per [ADR-16 WD13](../adr/16-macro-expansion.md), substrate-produced output
ships at a **floor** ("substrate-affected code parses cleanly and has its
identifiers resolved"); precise return-type emission is the ceiling,
layered per tier (Tier C `returns:` strings via
`Environment#nominal_for_name`; ADR-13 `TypeNodeResolver` chain for richer
forms).

## Drift-pin status

The public-API drift spec
([`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb))
pins the instance method sets of `BlockAsMethod`, `HeredocTemplate`,
`HeredocTemplate::Emit`, `HeredocTemplate::ReturnsFromArg`, `TraitRegistry`,
`ExternalFile`, and `NestedClassTemplate` — **every shipped value object on
the public manifest surface now carries the same accidental-change guard.**
The two formerly-unpinned objects (`NestedClassTemplate` per ADR-36 and
`HeredocTemplate::ReturnsFromArg` per ADR-18) were pinned via the
`PLUGIN_MACRO_NESTED_CLASS_TEMPLATE_INSTANCE` and
`PLUGIN_MACRO_HEREDOC_TEMPLATE_RETURNS_FROM_ARG_INSTANCE` snapshot constants.
None of these objects carry an `sig/rigor/*.rbs` signature yet, so they are
guarded by the runtime instance-method snapshot only, not the RBS sig-drift
dual.
