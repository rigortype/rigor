# rigor-dry-types — example Rigor plugin

[ADR-12](../../docs/adr/12-dry-rb-packaging.md) **Tier A foundation**:
recognises the canonical dry-types alias-module declaration

```ruby
module Types
  include Dry.Types()
end
```

and publishes the resulting `{aliased_name => underlying_class_name}`
table as the `:dry_type_aliases` [ADR-9](../../docs/adr/9-cross-plugin-api.md)
cross-plugin fact. Foundation gem for the `rigor-dry-*` family.

## What the plugin does

For source like

```ruby
# lib/types.rb
module Types
  include Dry.Types()
end
```

the plugin's `prepare(services)` hook scans every `paths:` entry
for `module X; include Dry.Types(); end` shapes, builds a frozen

```ruby
{
  "Types::String"   => "String",
  "Types::Integer"  => "Integer",
  "Types::Float"    => "Float",
  "Types::Decimal"  => "BigDecimal",
  "Types::Symbol"   => "Symbol",
  "Types::Bool"     => "TrueClass",
  "Types::True"     => "TrueClass",
  "Types::False"    => "FalseClass",
  "Types::Nil"      => "NilClass",
  "Types::Date"     => "Date",
  "Types::DateTime" => "DateTime",
  "Types::Time"     => "Time",
  "Types::Hash"     => "Hash",
  "Types::Array"    => "Array",
  "Types::Any"      => "Object"
}
```

table, and publishes it as `:dry_type_aliases` so downstream
plugins (`rigor-dry-struct`, `rigor-dry-validation`,
`rigor-dry-schema`) can consume it.

Nested modules work too — `module App; module Types; include
Dry.Types(); end; end` publishes `"App::Types::String"` /
`"App::Types::Integer"` / etc.

## Floor / ceiling

The slice-1 deliverable is the **floor**:

- Canonical-shortcut names (`Types::String` etc.) only.
- Fact-publishing only; no user-facing diagnostics yet.
- The visible value depends on downstream plugins consuming
  the published fact — at slice 1 alone, no behavioural change
  is observable in `bundle exec rigor check` runs.

The **ceiling** (future slices):

- **Nested categories** — `Types::Coercible::Integer`,
  `Types::Strict::Symbol`, `Types::Params::Bool`,
  `Types::JSON::Date`. Each is a separate dry-types coercion
  family with its own underlying behaviour.
- **User-authored compositions** — `Email = Types::String.constrained(format: …)`
  registers `Email` as an aliased subtype of `Types::String`.
- **Diagnostics** — `dry-types.unknown-alias` for references
  to a `Types::*` name that wasn't published;
  `dry-types.alias-shadow` when two modules conflict.
- **`rigor-dry-struct` precision uplift** — currently
  `attribute :city, Types::String` resolves `address.city` to
  `Dynamic[T]` (ADR-16 WD13 floor). When the slice-6
  precision-promotion path lands ([ADR-16](../../docs/adr/16-macro-expansion.md)
  Implementation slicing § "slice 6"), `rigor-dry-struct` will
  consume `:dry_type_aliases` and promote the reader to
  `Nominal[String]`.

## What the plugin does NOT do (yet)

- Recognise `Coercible::` / `Strict::` / `Params::` / `JSON::`
  nested namespaces (deferred to slice 2).
- Recognise user-authored compositions or `.constrained(...)` /
  `.optional` / `.default(...)` chaining (deferred to slice 2+).
- Emit `dry-types.*` diagnostics (deferred to demand).
- Round-trip the alias table through the cache descriptor —
  `prepare(services)` re-scans on every run. A descriptor entry
  is the natural slice when scan cost becomes load-bearing.

## Configuration

```yaml
plugins:
  - rigor-dry-types
```

No plugin-specific config keys. The plugin walks every `paths:`
entry's `.rb` files looking for the alias-module declaration.

## Running the demo

```sh
cd demo
cp .rigor.dist.yml .rigor.yml
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo writes a minimal `lib/types.rb` containing the canonical
`module Types; include Dry.Types(); end` shape. With the plugin
enabled the `:dry_type_aliases` fact is populated; without it the
fact is absent.

A full end-to-end demonstration of the precision uplift requires
the downstream consumer slice (ADR-16 slice 6 + ADR-13 resolver
chain) that consumes `:dry_type_aliases` — until then, the demo's
observable result is "no diagnostics" with vs without the plugin.
The integration spec
([`spec/integration/examples/dry_types_plugin_spec.rb`](../../spec/integration/examples/dry_types_plugin_spec.rb))
asserts the fact-publication contract directly.

## Related

- [ADR-12](../../docs/adr/12-dry-rb-packaging.md) — dry-rb
  plugin packaging decision (per-gem + meta umbrella).
- [ADR-9](../../docs/adr/9-cross-plugin-api.md) — the
  `Plugin::FactStore` cross-plugin fact channel.
- [`rigor-dry-struct`](../rigor-dry-struct/) — the first dry-rb
  consumer plugin (LANDED v0.1.5); will consume
  `:dry_type_aliases` once the slice-6 precision promotion path
  lands.
- [dry-rb plugins survey](../../docs/design/20260509-dry-plugins-roadmap.md) —
  the per-gem inventory + tiering that ADR-12 fixed.
