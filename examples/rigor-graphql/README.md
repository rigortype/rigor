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
    "name"      => { type: "String", nullable: false, list: false },
    "email"     => { type: "String", nullable: true,  list: false },
    "age"       => { type: "Integer", nullable: false, list: false },
    "is_active" => { type: "TrueClass", nullable: false, list: false }
  }
}
```

table, and publishes it as `:graphql_type_table`.

## List wrappers (slice 2a)

`field :tags, [String]` is GraphQL's list-of-element shape. The
plugin recognises the single-element `Prism::ArrayNode` form and
sets `list: true` on the row:

```ruby
class Post < GraphQL::Schema::Object
  field :tags, [String], null: false
  field :authors, [Types::Author], null: false
end

# →
{
  "Post" => {
    "tags"    => { type: "String", nullable: false, list: true },
    "authors" => { type: "Types::Author", nullable: false, list: true }
  }
}
```

Multi-element list literals (`[String, Integer]`) and empty lists
(`[]`) silently drop — they are not valid GraphQL list type
expressions.

## Schema::Enum recognition (slice 2b)

Enum subclasses (`class T < GraphQL::Schema::Enum`) are walked in
the same AST pass; every `value "STRING"` declaration inside the
class body is collected into a per-enum value list, published as
the **separate** `:graphql_enum_table` cross-plugin fact:

```ruby
class Status < GraphQL::Schema::Enum
  value "ACTIVE"
  value "PENDING"
  value "DISABLED", value: :off       # value: kwarg ignored at slice 2b
end

# :graphql_enum_table fact →
{
  "Status" => ["ACTIVE", "PENDING", "DISABLED"]
}
```

Only literal-String first arguments register. The optional
`value:` Ruby-side override and `description:` kwarg ride along
but stay out of the published table at this slice. Symbol-form
(`value :ACTIVE`) and constant-form (`value SOME_CONSTANT`)
declarations drop silently.

The plugin publishes BOTH facts from one project walk; consumers
that only need one fact (or neither) are unaffected by the
other's presence / absence.

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
- **`GraphQL::Schema::Mutation`** + **`GraphQL::Schema::InputObject`**.
- **Non-Null wrappers** (`String.array`). The bracket form
  (`[String]`) is recognised in slice 2a; the `<Type>.array` /
  `<Type>!` chain forms graphql-ruby also accepts stay deferred.
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
