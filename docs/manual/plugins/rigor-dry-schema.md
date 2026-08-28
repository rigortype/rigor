# rigor-dry-schema

Recognises dry-schema declarations and publishes a per-schema
typed-key table as a cross-plugin fact (`:dry_schema_table`) that
`rigor-dry-validation` consumes for typed-payload synthesis. Like
[`rigor-dry-types`](rigor-dry-types.md), it is a foundation plugin:
no diagnostics of its own, no config keys.

It ships bundled in `rigortype`. Activate it (pair with
`rigor-dry-types` to resolve `Types::*` aliases inside predicate
arguments):

```yaml
plugins:
  - rigor-dry-types     # optional: resolves Types::Email etc.
  - rigor-dry-schema
```

## What it recognises

```ruby
NewUserSchema = Dry::Schema.Params do
  required(:email).filled(:string)
  required(:age).value(:integer)
  required(:tags).each(:string)
  optional(:nickname).maybe(:string)
end
```

- `required` / `optional` keys, with the predicate's type symbol
  mapped to a Ruby class (`:string` → `String`, `:integer` →
  `Integer`, `:decimal` → `BigDecimal`, `:bool` → `TrueClass`, …).
- `each(:T)` marks the key as a **list** (`list: true`);
  `filled` / `value` / `maybe` are scalar (`list: false`).
- `value(Types::Email)` resolves through the `:dry_type_aliases`
  fact when `rigor-dry-types` is loaded; without it (or for an
  unknown reference) the row drops from the table rather than
  mislead downstream consumers.
- Top-level (`Foo = Dry::Schema.Params { … }`) and class-level
  (`class Bar; SCHEMA = …; end` → `"Bar::SCHEMA"`) declarations,
  across `.Params` / `.JSON` / `.define`.

## No diagnostics, no config

The plugin only publishes the schema table for other plugins to
consume; it surfaces no diagnostics and takes no config keys. (A
future slice adds `dry-schema.unknown-predicate` / `unknown-type`
info diagnostics and typed `result.to_h` synthesis.)

## Plugin internals

The `prepare(services)` scan, the published `:dry_schema_table`
shape, and the slice floor/ceiling are documented in the
[plugin's README](../../../plugins/rigor-dry-schema/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
