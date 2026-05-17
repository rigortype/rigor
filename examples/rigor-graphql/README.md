# rigor-graphql — example Rigor plugin

Tier 3D per the
[Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md):
recognises `class T < GraphQL::Schema::Object` subclasses and walks
every `field :name, Type, null: false` declaration inside, publishing
the resulting per-type field table as the `:graphql_type_table`
[ADR-9](../../docs/adr/9-cross-plugin-api.md) cross-plugin fact.

## What the plugin does

For source like

```ruby
class User < GraphQL::Schema::Object
  field :name, String, null: false
  field :email, String, null: true
  field :age, Integer, null: false
  field :is_active, Boolean, null: false
end
```

the plugin's `prepare(services)` hook scans every `paths:` entry for
`Schema::Object` subclasses, builds a frozen

```ruby
{
  "User" => {
    "name"      => { type: "String", nullable: false },
    "email"     => { type: "String", nullable: true },
    "age"       => { type: "Integer", nullable: false },
    "is_active" => { type: "TrueClass", nullable: false }
  }
}
```

table, and publishes it as `:graphql_type_table`.

## Why this is a metadata-recorder plugin (not ADR-16 substrate)

graphql-ruby's `field` DSL is a **pure metadata recorder** — it just
appends to the class's `own_fields` registry; it does NOT emit Ruby
methods. The user writes resolver methods themselves. This makes the
gem an unusual fit for the ADR-16 macro expansion substrate (which
synthesises methods from manifest declarations).

The macro-expansion library survey at
[`docs/notes/20260515-macro-expansion-library-survey.md`](../../docs/notes/20260515-macro-expansion-library-survey.md)
§ "GraphQL-Ruby" documents the analysis: graphql-ruby is "neither
Lisp-macro nor PHPStan-trait" because there's no Ruby method to
expand. Rigor's value for graphql-ruby is therefore a STATIC TYPE
TABLE downstream consumers can cross-reference — not method
synthesis.

## Type mapping

Canonical GraphQL scalar names map to underlying Ruby classes:

| GraphQL name | Underlying class |
|---|---|
| `String` | `String` |
| `Integer` / `Int` | `Integer` |
| `Boolean` | `TrueClass` |
| `Float` | `Float` |
| `ID` | `String` |

User-defined types (`Types::User`, `Types::Status`) are recorded
under their qualified name so downstream consumers can resolve
them through the same table.

## Nullability

The `null:` keyword extracts to `nullable: true` / `false`. When
`null:` is omitted, the plugin defaults to `nullable: true` to
mirror graphql-ruby's own field default.

## Floor / ceiling

Slice 1 ships the **floor**:

- Recognises `class T < GraphQL::Schema::Object` subclasses
  (top-level AND nested under `module Types; class User <
  Schema::Object`).
- Recognises `field :name, Type, null: ...` declarations with
  constant-form Type.
- Publishes the table; no user-facing diagnostics yet.

The **ceiling** (future slices, demand-driven):

- **Resolver-method check** — for each `field :name, Type`, if
  `name` is also defined as a Ruby method, verify the return type
  matches `Type`'s underlying class.
- **`GraphQL::Schema::Enum`** — `value "ACTIVE"` declarations.
- **`GraphQL::Schema::Mutation`** + **`GraphQL::Schema::InputObject`**.
- **List / Non-Null wrappers** (`[String]`, `String.array`).
- **`resolver:` / `mutation:`** reroute recognition.
- **String type-expression diagnostic** — graphql-ruby accepts
  `field :foo, "User"` and `BuildType.parse_type` constantizes at
  runtime; static resolution fails. A future slice could surface
  these as `graphql.string-type` `:info` diagnostics that point the
  user at the constant-reference form.
- **`Schema.execute(...)` result typing** — a future plugin could
  type `Schema.execute(query).to_h` against the queried fields.

## What the plugin does NOT do (yet)

- Type-check resolver methods against their `field` declarations.
- Recognise enums, mutations, input objects.
- Emit `graphql.*` diagnostics.
- Round-trip the type table through the cache descriptor —
  `prepare(services)` re-scans on every run.

## Configuration

```yaml
plugins:
  - rigor-graphql
```

No plugin-specific config keys. The plugin walks every `paths:`
entry's `.rb` files looking for `Schema::Object` subclass shapes.

## Related

- [Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)
  § 3D — the tiering entry for this plugin.
- [Macro expansion library survey](../../docs/notes/20260515-macro-expansion-library-survey.md)
  § "GraphQL-Ruby" — the analysis that grounded the
  metadata-recorder plugin shape rather than ADR-16 substrate.
- [ADR-9](../../docs/adr/9-cross-plugin-api.md) — the
  `Plugin::FactStore` cross-plugin fact channel the
  `:graphql_type_table` fact uses.
