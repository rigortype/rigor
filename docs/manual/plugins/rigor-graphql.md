# rigor-graphql

Recognises GraphQL-Ruby schema classes — `Schema::Object`,
`Schema::Enum`, `Schema::InputObject`, `Schema::Mutation` subclasses —
and walks their `field` / `value` / `argument` DSL declarations,
publishing the resulting type tables as
[ADR-9](../../adr/9-cross-plugin-api.md) cross-plugin facts that
downstream plugins can consume. graphql-ruby's `field` DSL is a pure
metadata recorder (it synthesises no Ruby methods), so Rigor's value
here is a static type table rather than method synthesis. It reads
source only, with no `graphql` runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-graphql
```

## What it infers

```ruby
module Types
  class User < GraphQL::Schema::Object
    field :name, String, null: false
    field :email, String, null: true
    field :tags, [String], null: false   # list-of form
  end
end
```

publishes a `:graphql_type_table` fact:

```ruby
{
  "Types::User" => {
    "name"  => { type: "String", nullable: false, list: false },
    "email" => { type: "String", nullable: true,  list: false },
    "tags"  => { type: "String", nullable: false, list: true }
  }
}
```

It publishes four independent facts from one project walk; consumers
that need only one (or none) are unaffected by the others:

| Fact | Source class | Shape |
| --- | --- | --- |
| `:graphql_type_table` | `Schema::Object` | `field` → `{type, nullable, list}` |
| `:graphql_enum_table` | `Schema::Enum` | `value "..."` → ordered value list |
| `:graphql_input_object_table` | `Schema::InputObject` | `argument` → `{type, required, list}` |
| `:graphql_mutation_table` | `Schema::Mutation` | `{arguments:, fields:}` combined |

Canonical GraphQL scalars map to Ruby classes (`String`→`String`,
`Integer`/`Int`→`Integer`, `Boolean`→`TrueClass`, `Float`→`Float`,
`ID`→`String`); user-defined types are recorded under their qualified
name. `null:` extracts to `nullable:` (defaulting to `true`, mirroring
graphql-ruby); `required:` defaults to `false`. The single-element
`[String]` list form is recognised.

## Typed DSL surface

Beyond the fact tables, the plugin bundles the graphql-ruby class-level
DSL signature, so calls inside a recognised subclass type as their real
carriers instead of staying opaque: `field` returns
`GraphQL::Schema::Field`, `argument` returns `GraphQL::Schema::Argument`,
`Enum.value` returns `GraphQL::Schema::EnumValue`, `description` /
`graphql_name` return their configured strings, and the `Schema`
registration macros (`query`, `mutation`, `use`, `orphan_types`, …)
return what they registered. A block parameter on `field`/`argument`
(`field(:comments) { |f| … }`) types as `GraphQL::Schema::Field` /
`GraphQL::Schema::Argument`.

## No diagnostics, no config

The plugin emits no diagnostics and has no configuration knobs — it
contributes the type tables and signature above for the engine and
other plugins to consume. It walks every `paths:` entry's `.rb` files
for the schema-class shapes.

## Limitations

- **No resolver-method type-check.** `field` declarations are recorded
  as metadata; they are not yet cross-referenced against the Ruby
  resolver methods that back them.
- **No `Schema.execute(...)` result typing.** Typing
  `Schema.execute(query).to_h` against the queried fields is a future
  plugin.
- **Interface DSL stays opaque.** `include GraphQL::Schema::Interface`
  wires the DSL onto the includer through an include-time `extend`
  hook RBS cannot express, so `field` inside an interface module is
  not yet typed.
- **Zero-arity definition blocks keep an opaque `self`.**
  `field :x do ... end` `instance_eval`s on the new `Field` at
  runtime; only the explicit-parameter form (`{ |f| … }`) is typed.
- **Constant-form types only.** The string form (`field :foo, "User"`)
  and the `<Type>.array` / `<Type>!` sugar chains are not recognised
  (the `[String]` bracket form is). Multi-element and empty list
  literals are dropped.
- **Enum literal values only.** `value "ACTIVE"` registers; the
  symbol-form (`value :ACTIVE`) and constant-form drop, and the
  `value:` / `description:` kwargs ride along but stay out of the table.
- **No cache round-trip** — the walk re-runs each invocation.

## Plugin internals

The type scanner and the contract surfaces this plugin exercises are in
the [plugin's README](../../../plugins/rigor-graphql/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
