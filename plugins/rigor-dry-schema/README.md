# rigor-dry-schema

[ADR-12](../../docs/adr/12-dry-rb-packaging.md) Tier A plugin per the
slicing plan in
[`docs/design/20260517-dry-validation-slicing.md`](../../docs/design/20260517-dry-validation-slicing.md):
recognises the canonical dry-schema declaration shapes

```ruby
NewUserSchema = Dry::Schema.Params do
  required(:email).filled(:string)
  required(:age).value(:integer)
  optional(:nickname).maybe(:string)
end
```

and publishes the per-schema typed-key table as the
`:dry_schema_table` [ADR-9](../../docs/adr/9-cross-plugin-api.md)
cross-plugin fact. Downstream `rigor-dry-validation` will consume
the fact for typed-payload synthesis on `Contract#call` results.

> **Using this plugin?** The user guide — what it recognises and
> the (no-diagnostics / no-config) usage note — lives in the manual
> at
> [docs/manual/plugins/rigor-dry-schema.md](../../docs/manual/plugins/rigor-dry-schema.md).
> This README covers the plugin's internals (the scan, the
> published `:dry_schema_table`, and the slice floor/ceiling).

## What the plugin does

For source like

```ruby
# app/schemas/new_user_schema.rb
NewUserSchema = Dry::Schema.Params do
  required(:email).filled(:string)
  required(:age).value(:integer)
  optional(:nickname).maybe(:string)
end
```

the plugin's `prepare(services)` hook scans every `paths:` entry for
`Foo = Dry::Schema.{Params,JSON,define} { ... }` shapes, builds a
frozen

```ruby
{
  "NewUserSchema" => {
    required: {
      email: { type: "String", list: false },
      age:   { type: "Integer", list: false }
    },
    optional: {
      nickname: { type: "String", list: false }
    }
  }
}
```

table, and publishes it as `:dry_schema_table`.

## `each(<Type>)` list recognition (slice 2)

The `each` predicate on dry-schema rows marks the key as a list:

```ruby
ContactSchema = Dry::Schema.Params do
  required(:tags).each(:string)
  required(:scores).value(:array)
  optional(:authors).each(:string)
end

# → :dry_schema_table fact
{
  "ContactSchema" => {
    required: {
      tags:   { type: "String", list: true },   # each-list
      scores: { type: "Array",  list: false }   # value(:array) — single Array, not list-of-element
    },
    optional: {
      authors: { type: "String", list: true }
    }
  }
}
```

`each` is the only verb that produces `list: true`; the other
three type-bearing predicates (`filled` / `value` / `maybe`)
yield `list: false`. The `list:` slot is symmetric with
`rigor-graphql`'s field-table shape so downstream cross-plugin
consumers (`rigor-dry-validation`) can reason about
list-vs-scalar fields uniformly.

## `each do ... end` element-type recursion

`each` also accepts a block instead of a type symbol, declaring
an array of a NESTED schema rather than an array of a scalar:

```ruby
OrderSchema = Dry::Schema.Params do
  required(:items).each do
    required(:sku).filled(:string)
    optional(:qty).value(:integer)
  end
end
```

The block is walked with the same required/optional algorithm a
top-level `Dry::Schema.X { ... }` body uses (predicate
vocabulary, cross-plugin alias resolution, the untyped-row
fallback all apply identically at the nested level), and the
row's `type:` slot becomes a nested shape rather than a class
name:

```ruby
{
  "OrderSchema" => {
    required: {
      items: {
        type: { nested: { required: { sku: { type: "String", list: false } },
                           optional: { qty: { type: "Integer", list: false } },
                           unmodelled: { required: [], optional: [] } } },
        list: true
      }
    },
    optional: {}
  }
}
```

`each do schema do ... end end` — dry-schema's other spelling for
the identical declaration — is recognised too; both unwrap to the
same nested shape. `OrderSchema.call(input).to_h[:items]` types as
`Array[{ sku: String, ?qty: Integer, ... }]`.

The recursion caps at ONE level: an `each do ... end` found
INSIDE another `each do ... end` is not modelled (the outer key
falls back to `untyped`, the scanner's standard "declined, not
wrong" posture for anything outside its recognised vocabulary).
A block with no recognisable `required`/`optional` row at all — a
bare per-element predicate like `each { int? }` — declines the
same way.

## Predicate type recognition

Each `required(:key).<predicate>(<arg>)` row maps the predicate's
type argument to an underlying Ruby class:

| dry-schema symbol | Underlying class |
|---|---|
| `:string` | `String` |
| `:integer` | `Integer` |
| `:float` | `Float` |
| `:decimal` | `BigDecimal` |
| `:symbol` | `Symbol` |
| `:bool` | `TrueClass` |
| `:nil` | `NilClass` |
| `:date` | `Date` |
| `:date_time` | `DateTime` |
| `:time` | `Time` |
| `:hash` | `Hash` |
| `:array` | `Array` |

The four predicate verbs `filled` / `value` / `maybe` / `each` are
all accepted on the same row; their runtime semantic difference
(presence-vs-coercion-vs-element) does not change the underlying
class for Rigor's purposes.

## Cross-plugin: `value(Types::Email)` resolution

When `rigor-dry-types` is also loaded, the plugin reads the
`:dry_type_aliases` fact to resolve user-authored constant
references inside predicate arguments. For

```ruby
module Types
  include Dry.Types()
  Email = String.constrained(format: /@/)
end

ContactSchema = Dry::Schema.Params do
  required(:email).value(Types::Email)
end
```

the published shape becomes
`{ "ContactSchema" => { required: { email: "String" } } }` because
`rigor-dry-types` exposes `Types::Email => "String"` through the
shared fact.

Without `rigor-dry-types` (or for a reference the alias table
doesn't know about) the row silently drops from the table rather
than misleading downstream consumers.

## Floor / ceiling

The slice-1 deliverable is the **floor**:

- Recognises top-level `Foo = Dry::Schema.X { ... }` assignments
  and class-level constants (`class Bar; SCHEMA = ...; end`
  registers as `"Bar::SCHEMA"`).
- Accepts the canonical-type vocabulary above + cross-plugin
  alias resolution.
- Publishes the table; no user-facing diagnostics yet.

**Landed since**:

- **Typed `result.to_h` returns**. `NewUserSchema.call(input).to_h`
  infers `{ email: String, age: Integer, ?nickname: String, ... }`
  instead of an untyped hash. See § "Typed `result.to_h`" below.
- **`each do ... end` element-type recursion** (issue #137). See
  § "`each do ... end` element-type recursion" above.
- **`dry-schema.unknown-type` `:info` diagnostic** (issue #137).
  See § "Diagnostics" below.
- **`rigor-dry-validation` integration** (issue #137) — landed in
  that plugin's own slices 2/3, not here: a Contract's inline
  `params { ... }` / `json { ... }` block is walked with the
  SAME DSL vocabulary this plugin defines, refining
  `Contract#call(...).to_h`. See
  [`rigor-dry-validation`'s README](../rigor-dry-validation/README.md).

The **ceiling** (still open, demand-driven):

- **Nested schemas outside `each`** (`required(:x).schema do ... end`
  with no `each` in the chain) — the key stays untyped; only the
  `each`-wrapped nested form (above) recurses.
- **`predicates(:size?)` / other per-row constraint walks.**
- **`dry-schema.unknown-predicate` diagnostic** — deliberately not
  shipped. There's no reliable static signal that distinguishes a
  genuinely-mistyped predicate name from one of dry-schema's many
  legitimate fine-grained predicates (`size?` / `gt?` / `format?` /
  `included_in?` / ...) this scanner doesn't model, and a bare
  `required(:key)` with no type-bearing predicate at all is itself
  valid dry-schema (a presence-only check). Guessing here would
  flag correct code — the `AGENTS.md` "false positives outrank
  worst-case reading" call, applied by declining.

## Typed `result.to_h`

`SomeSchema.call(input).to_h` returns the schema's own hash
shape:

```ruby
payload = NewUserSchema.call(input).to_h
#=> { email: String, age: Integer, ?nickname: String, ... }

payload[:email]     #=> String
payload[:nickname]  #=> String?
```

A `required` row becomes a required key and an `optional` row an
optional one — the declaration's own vocabulary. That is
deliberately *not* the worst case: `Result#to_h` returns the
coerced input, so a failed validation can drop a required key
too. Modelling that would type `payload[:email]` as `String?`
even inside an `if result.success?` branch, and a false positive
on correct code costs more here than a worst-case reading buys
(`AGENTS.md` § Implementation Guidelines).

The shape is **open**, and a key the scanner cannot type — a
predicate outside the canonical vocabulary, a nested
`schema do ... end` row, an unresolved alias — is shown as
`untyped` rather than omitted:

```ruby
NestedSchema.call(input).to_h
#=> { email: String, address: Dynamic[top], ... }
```

Reads are unaffected either way (an undeclared key on an open
shape already reads as `untyped`). What the entry buys is the
rendering: hover and `dump_type` say the schema declares
`address` and Rigor cannot type it, where omitting it would be
indistinguishable from a schema that never mentioned the key —
the trailing `...` only means "further keys are permitted".

The schema must be named by a constant as written at the call
site (`NewUserSchema.call(x).to_h`). Reached through a local or
by a relative constant path from inside the declaring module,
the chain contributes nothing and `to_h` types as it did before.

## Diagnostics

`dry-schema.unknown-type` (`:info`) fires when a type-bearing
predicate (`filled` / `value` / `maybe` / `each`) receives a
literal Symbol argument that is NOT one of the canonical dry-schema
type symbols in the table above:

```ruby
Schema = Dry::Schema.Params do
  required(:count).filled(:integr)   # typo for :integer
end
# → info: `count` uses `:integr`, which is not a recognised
#   dry-schema canonical type symbol [dry-schema.unknown-type]
```

It does NOT fire for a Constant argument
(`value(Types::Email)`) — an unresolved alias already has the
silent fallback described above, and flagging it would misfire on
every entirely-correct row in a project that simply doesn't have
`rigor-dry-types` loaded. It recurses into an `each do ... end`
nested row too, so a bad symbol on a nested key is caught at its
own position.

## What the plugin does NOT do (yet)

- Emit `dry-schema.unknown-predicate` (see § "Floor / ceiling"
  for why) or any per-row key-existence diagnostic.
- Round-trip the schema table through the cache descriptor —
  `prepare(services)` re-scans on every run. Add a glob-based
  `Cache::Descriptor::FileEntry` when scan cost becomes
  load-bearing.

## Configuration

```yaml
plugins:
  - rigor-dry-types       # optional; enables Types::* alias resolution
  - rigor-dry-schema
```

No plugin-specific config keys. The plugin walks every `paths:`
entry's `.rb` files looking for the schema declarations.

## Related

- [ADR-12](../../docs/adr/12-dry-rb-packaging.md) — dry-rb
  plugin packaging decision (per-gem + meta umbrella).
- [ADR-9](../../docs/adr/9-cross-plugin-api.md) — the
  `Plugin::FactStore` cross-plugin fact channel.
- [`rigor-dry-types`](../rigor-dry-types/) — publishes
  `:dry_type_aliases`; consumed here for user-authored
  reference resolution.
- [dry-validation slicing plan](../../docs/design/20260517-dry-validation-slicing.md)
  — the design note that orders this plugin BEFORE the
  validation plugin.
- [dry-rb plugins survey](../../docs/design/20260509-dry-plugins-roadmap.md) —
  the per-gem inventory + tiering that ADR-12 fixed.
