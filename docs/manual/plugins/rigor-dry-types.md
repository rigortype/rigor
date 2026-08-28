# rigor-dry-types

The foundation plugin for the dry-rb family. It recognises the
canonical dry-types alias module —

```ruby
module Types
  include Dry.Types()
end
```

— and makes the alias names it generates resolvable to their
underlying Ruby classes, publishing them as a cross-plugin fact
(`:dry_type_aliases`) that [`rigor-dry-struct`](../07-plugins.md),
`rigor-dry-schema`, and `rigor-dry-validation` consume.

It ships bundled in `rigortype`. Activate it alongside the dry-rb
plugins that consume it:

```yaml
plugins:
  - rigor-dry-types
  - rigor-dry-struct
  # - rigor-dry-schema / rigor-dry-validation as needed
```

## No diagnostics of its own

This plugin emits **no diagnostics** and has **no config keys** —
it only supplies type information to the other dry-rb plugins, so
its visible effect surfaces through them (a `Types::String`-typed
attribute resolving downstream, etc.).

## What it recognises

- **Canonical shortcuts** — `Types::String` / `Integer` / `Float` /
  `Decimal` → `BigDecimal` / `Bool` / `Date` / `Hash` / `Array` /
  `Any` → `Object`, and the rest.
- **Coercion-category namespaces** — the same names under
  `Coercible::` / `Strict::` / `Params::` / `JSON::` (they share an
  underlying class; the difference is runtime coercion).
- **Nested alias modules** — `module App; module Types; include
  Dry.Types(); end; end` publishes `App::Types::String`, etc.
- **User-authored single-head compositions** — `Email =
  String.constrained(format: …)`, `Status = Strict::Symbol`,
  `PositiveInt = Integer.constrained(gt: 0).optional` publish under
  the head's underlying class.

Unions (`String | Integer`), intersections, and transitive
references to other compositions (`ManagerEmail = Email`) are
skipped — there's no single underlying class to publish.

## Plugin internals

The `prepare(services)` scan, the published `:dry_type_aliases`
table, and the slice floor/ceiling are documented in the
[plugin's README](../../../plugins/rigor-dry-types/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
