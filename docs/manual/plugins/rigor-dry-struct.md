# rigor-dry-struct

Recognises dry-struct's class-level `attribute :name, Type` /
`attribute? :name, Type` DSL on `Dry::Struct` subclasses and
synthesises the reader methods it generates — so a bare
`address.city` in another file resolves instead of falling through
to `call.undefined-method`.

It ships bundled in `rigortype`. Activate it — and pair it with
[`rigor-dry-types`](rigor-dry-types.md) for precise reader types:

```yaml
plugins:
  - rigor-dry-struct
  - rigor-dry-types   # optional: resolves Types::String → String on the readers
```

## What it does

```ruby
class Address < Dry::Struct
  attribute :city, Types::String
  attribute? :postcode, Types::String
end

address.city      # resolves (synthesised reader)
address.postcode  # resolves
```

When [`rigor-dry-types`](rigor-dry-types.md) is also active and the
project declares `module Types; include Dry.Types(); end`, the
reader's return type resolves through the attribute's type argument
(`attribute :city, Types::String` → `city` returns `String`). When
dry-types isn't loaded, or for a shape it can't resolve (a
`.constrained(...)` chain, an inline composition), the reader falls
back to `Dynamic[top]` — silently, no diagnostic.

## No diagnostics, no config

The plugin contributes synthesised methods, not diagnostics, and
has no config keys. It handles any class inheriting from
`Dry::Struct` (lexically, transitively, or through the RBS env when
the chain terminates upstream). Its visible effect is that
attribute-reader calls type-check.

## Limitations

- **Readers only.** The `schema` / `to_h` / `[:key]` / keyword-arg
  `.new(name:)` shapes are not synthesised yet.
- **No nested-block form.** `attribute :details do … end` (which
  mints a sibling `Dry::Struct` subclass) is deferred.

## Plugin internals

The declarative `HeredocTemplate` manifest, the
`returns_from_arg` precision path (ADR-18), and the
synthetic-method substrate it rides on are documented in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-dry-struct/README.md). To
write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
