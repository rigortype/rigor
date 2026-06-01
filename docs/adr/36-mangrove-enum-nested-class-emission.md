# ADR-36 — Macro-substrate nested-class emission tier (Mangrove `Enum`)

Status: **Accepted, 2026-05-30; Slice A implemented.**

Records the decision to extend the [ADR-16](16-macro-expansion.md)
macro-expansion substrate with a new tier that mints **nested
subclasses** (not just methods) from a class-level DSL block, motivated
by the [Mangrove](https://github.com/kazzix14/mangrove) `Enum` DSL. The
shippable, in-contract part of Mangrove support (carrier-generic
instantiation at unwrap call sites) landed separately as
`plugins/rigor-mangrove`; this ADR scopes the part that today's plugin
contract could not express.

**Slice A implemented (2026-05-30):** `Plugin::Macro::NestedClassTemplate`
(manifest slot `nested_class_templates:`) + a scanner pass in
`SyntheticMethodScanner` that, for each `variant <Const>, <Type>` row in
a `<block_method> do … end` block on a class that `extend`s the
`receiver_constraint`, records the variant subclass name (so
`Environment#class_known?` resolves it → constant reference + `.new`
dispatch via `meta_new`) and synthesises a `#inner` reader returning the
literal constant payload type through the existing
`SyntheticMethodIndex`. Wired into `rigor-mangrove` for `Mangrove::Enum`.
`Shape::Circle.new(1.0).inner` now types as `Float`. **Deferred (the WD3
ceiling):** the `sealed`-parent fact + `is_a?` cross-variant exhaustive
narrowing, which needs the synthetic-class hierarchy threaded into
`Environment#class_ordering`; and non-constant inner shapes (shape
hashes), which degrade to `Dynamic[Top]` today.

Grounding survey:
[`docs/notes/20260530-mangrove-library-survey.md`](../notes/20260530-mangrove-library-survey.md).

## Context

Mangrove's `Enum` is an algebraic-data-type DSL:

```ruby
class Shape
  extend Mangrove::Enum

  variants do
    variant Circle, Float
    variant Rectangle, { width: Float, height: Float }
    variant Unit, NilClass
  end
end
```

Each `variant Const, Type` declaration is meant to produce a **nested
subclass** `Shape::Circle < Shape` carrying `#inner : <Type>` (plus a
fixed method set — `inner`, `as_super`, `serialize`, `==`). Downstream
code then constructs and matches on those variants:

```ruby
shape = Shape::Circle.new(1.0)
case shape
when Shape::Circle then shape.inner.floor   # inner : Float
end
```

### Why current contract surfaces do not fit

Mangrove implements this with `const_missing` + `class_eval` of a
stringified Ruby heredoc — the variant subclass is defined lazily the
first time `Shape::Circle` is referenced (survey note § "Enum DSL"). The
generated surface is fully recoverable from source — the `variant
Const, Type` pairs are literal arguments and the emitted method set is
fixed — but no v0.1.x substrate tier can emit it:

- **ADR-16 Tier C (`Macro::HeredocTemplate`)** extracts a literal
  **Symbol** at `symbol_arg_position` and emits **methods on the calling
  class**. Mangrove's `variant` takes a **constant** (the variant class
  name), and the emission target is a **new nested class**, not a method
  on `Shape`. `rigor-dry-struct` already documents this exact gap:
  "Nested-block form (`attribute :details do ... end` minting
  `Address::Details`) is out of scope … that pattern needs Tier A +
  Tier C composition + `const_set` emission. Deferred."
- **Tier A (`BlockAsMethod`)** re-targets a block body's `self_type`; it
  does not mint constants.
- **Tier B (`TraitRegistry`)** maps symbols to *existing* modules to
  `include`; it does not create types.

The substrate floor (ADR-16 WD13) is "synthetic **methods** emit by
name." There is no "synthetic **class** emit" primitive. So Mangrove
`Enum` is the canonical motivating case for one.

The two other Mangrove surfaces from the survey are explicitly **out of
scope** for this ADR:

- `is_a?(Shape::Circle)` exhaustive narrowing over the sealed variant
  set is core control-flow analysis (it consumes whatever sealed
  hierarchy the type universe knows), not a substrate concern. It
  becomes *useful* once this ADR's emission tier teaches the universe
  that the variants exist and that `Shape` is their sealed parent, but
  the narrowing itself is engine work.
- Carrier-generic instantiation (`unwrap!` → `OkType`) shipped in
  `plugins/rigor-mangrove` and needs nothing here.

## Decision

Add a **nested-class emission tier** to the ADR-16 substrate. Working
shape (subject to refinement during implementation):

```ruby
nested_class_templates: [
  Rigor::Plugin::Macro::NestedClassTemplate.new(
    receiver_constraint: "Mangrove::Enum",   # extend-side marker
    block_method: :variants,                 # the enclosing DSL block
    variant_method: :variant,                # each declaration call
    name_arg_position: 0,                     # constant arg → nested class name
    inner_arg_position: 1,                    # type arg → #inner return
    superclass: :enclosing,                   # Shape::Circle < Shape
    emit: [
      { name: "inner",    returns_from_arg: { position: 1 } },
      { name: "as_super", returns: :enclosing },
      { name: "==",       returns: "bool" }
    ],
    sealed: true                              # mark the parent sealed
  )
]
```

Working decisions to settle in the ADR body before implementation:

- **WD1 — Emission primitive.** The pre-pass synthesises, for each
  `variant Const, Type` row, a nominal type `<<Enclosing>>::<<Const>>`
  whose parent is the enclosing class, registered in the same
  `SyntheticMethodIndex` substrate the dispatcher already consults — but
  keyed as a **class** entry the constant resolver and `.new` dispatch
  can both see. This is the new substrate capability.
- **WD2 — `#inner` return precision.** `inner_arg_position` reuses
  ADR-18's `returns_from_arg:` machinery; the literal second argument
  (`Float`, a shape hash, `NilClass`) resolves through
  `Environment#nominal_for_name` (or a shape literal) to the variant's
  `#inner` return. Floor per ADR-16 WD13: `Dynamic[T]` until the
  resolver chain is wired.
- **WD3 — Sealedness.** `sealed: true` publishes the parent → variant
  set so the engine's control-flow narrowing (the deferred `is_a?`
  surface) can later treat the variant set as exhaustive. Emitting the
  fact is in scope; consuming it for narrowing is not.
- **WD4 — Demand-gating.** Like Tier D today, ship the value class +
  validation first; wire the pre-pass + dispatcher integration when a
  bundled consumer (`rigor-mangrove` Enum slice) is built against it.

## Consequences

- Unblocks a whole class of ADT / sealed-variant DSLs beyond Mangrove
  (`Dry::Struct` nested `attribute … do … end`, any `const_set`-minting
  macro). The `rigor-dry-struct` deferral note becomes addressable.
- `rigor-mangrove` gains a second slice (Enum) once the tier lands,
  keeping all Mangrove support in the one bundled plugin.
- Adds a genuinely new substrate primitive (class emission); raises the
  engine's surface area and must be gated behind the same
  false-positive discipline as the rest of ADR-16 — a synthesised
  variant class must never *remove* a working program's behaviour, only
  add resolution where there was `Dynamic[Top]`.
- Deferring keeps v0.1.x's contract honest: until this ships, the
  `rigor-plugin-author` skill correctly routes Mangrove `Enum` requests
  to "stop and ask / open an ADR" rather than inventing a walker
  workaround.
