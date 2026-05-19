# rigor-dry-schema — example Rigor plugin

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
consumers (a future `rigor-dry-validation` plugin) can reason
about list-vs-scalar fields uniformly.

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

The **ceiling** (future slices, demand-driven):

- **Synthesise typed `result.to_h` returns** from each schema
  via ADR-16 Tier C heredoc-template substrate — promotes
  `NewUserSchema.call(input).to_h` from `Hash[Symbol, untyped]`
  to `HashShape[{email: String, age: Integer}]`.
- **Nested schemas** (`schema(do ... end)` inside another row).
- **`predicates(:size?)` / per-row constraint walks**.
- **`each { ... }` element-type recursion**.
- **Per-row diagnostics** — `dry-schema.unknown-predicate` /
  `dry-schema.unknown-type` `:info` when a row's predicate or
  type symbol isn't recognised.
- **`rigor-dry-validation` integration** — Contract subclasses
  whose `params { ... }` block delegates to a dry-schema
  declaration would consume `:dry_schema_table` for typed
  `Contract#call → Result` payloads.

## What the plugin does NOT do (yet)

- Synthesise typed return shapes for schema-bearing methods
  (`NewUserSchema.call(...)` is still `untyped` at this slice).
- Emit diagnostics for unknown predicates / types / keys.
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
