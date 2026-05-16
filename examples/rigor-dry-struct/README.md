# rigor-dry-struct — example Rigor plugin

ADR-16 **Tier C** worked target: recognises dry-struct's class-
level `attribute :name, T` DSL and synthesises a reader method on
the enclosing `Dry::Struct` subclass.

This plugin is the **first worked consumer of `Plugin::Macro::HeredocTemplate`**
(ADR-16 slice 2c) — the textbook Tier C target per the
[per-library survey](../../docs/notes/20260515-macro-expansion-library-survey.md).
Like `rigor-sinatra` (the slice-1c Tier A consumer), the plugin's
body is **purely declarative**:

```ruby
class DryStruct < Rigor::Plugin::Base
  manifest(
    id: "dry-struct",
    version: "0.1.0",
    heredoc_templates: [
      Rigor::Plugin::Macro::HeredocTemplate.new(
        receiver_constraint: "Dry::Struct",
        method_name: :attribute,
        symbol_arg_position: 0,
        emit: [{ name: "\#{name}", returns: "Object" }]
      ),
      Rigor::Plugin::Macro::HeredocTemplate.new(
        receiver_constraint: "Dry::Struct",
        method_name: :attribute?,
        symbol_arg_position: 0,
        emit: [{ name: "\#{name}", returns: "Object" }]
      )
    ]
  )
end
```

No `diagnostics_for_file`, no AST walker, no plugin-side state.
The substrate's slice-2b pre-pass scans for matching calls and
populates a `SyntheticMethodIndex` the dispatcher consults below
RBS dispatch.

## What the plugin does

For source like

```ruby
class Address < Dry::Struct
  attribute :city, Types::String
  attribute :country, Types::String
  attribute? :postcode, Types::String
end
```

the substrate's pre-pass scanner walks the file once, sees the
three `attribute` / `attribute?` calls with literal Symbol
arguments, and synthesises:

- `Address#city`
- `Address#country`
- `Address#postcode`

as instance readers. Bare `address.city` calls in other files
then dispatch through the substrate's tier (between RBS and
dependency-source) and return `Dynamic[T]` rather than falling
through to `call.undefined-method`.

## Precision uplift via `rigor-dry-types` (ADR-18, v0.1.6)

The manifest's `emit:` row uses [ADR-18](../../docs/adr/18-substrate-per-call-site-return-type.md)'s
`returns_from_arg:` DSL to look up the call-site type argument
through the `:dry_type_aliases` cross-plugin fact published
by [`rigor-dry-types`](../rigor-dry-types/):

```ruby
emit: [{
  name: "\#{name}",
  returns_from_arg: {
    position: 1,
    lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
  }
}]
```

When both plugins are loaded and the project declares
`module Types; include Dry.Types(); end`, the substrate
resolves `attribute :city, Types::String` into a synthetic
`Address#city` returning `Nominal[String]` (via the slice-6b
`environment.nominal_for_name` promotion path).

When `rigor-dry-types` isn't loaded OR the call uses an
unresolvable shape (`attribute :tag, Types::String.constrained(...)`,
inline method-chain whose chain-head isn't currently
extracted), the row falls back to `Dynamic[Top]` (the
pre-ADR-18 floor). The fallback is silent — no diagnostic.

## What the plugin does NOT do (yet)

- **Reader return-type precision.** Per WD13 — `address.city`
  is `Dynamic[T]` at the floor. Ceiling is `String` when the
  type argument resolves through ADR-13.
- **`schema` / `to_h` / `[:key]` / `.new(name:)` keyword arg.**
  The per-library survey lists five emit rows for dry-struct;
  slice 2c stops at the reader. The other four rows need either
  RBS-level shape synthesis (not yet a substrate primitive) or
  additional dispatch hooks beyond `try_synthetic_method`.
- **Nested-block form** (`attribute :details do ... end`) that
  mints `Address::Details` as a sibling `Dry::Struct` subclass.
  Needs Tier A + Tier C composition + const_set emission;
  deferred.
- **dry-types `Types::String` etc.** A separate `rigor-dry-types`
  plugin (not yet authored) covers the constant-emit side of the
  `include Dry.Types()` DSL. Its absence is why the demo's
  `Types::String` is currently typed as `untyped` in the demo
  RBS stub.

## Configuration

```yaml
plugins:
  - rigor-dry-struct
```

No plugin-specific config keys. The substrate handles every
class that inherits from `Dry::Struct` (lexically, transitively,
or through the RBS env when the chain terminates at an upstream
class).

## Running the demo

The demo provides a minimal `Dry::Struct` RBS stub locally
(`demo/sig/dry_struct.rbs`). A real project depending on
`dry-struct` would consume the upstream gem's own RBS through
rigor's Bundler-awareness path.

```sh
cd demo
cp .rigor.dist.yml .rigor.yml
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo's `consumer.rb` calls `address.city`, `address.country`,
`user.name`, `user.email`, `user.admin` across the file
boundary from `demo.rb`. With the plugin enabled these calls
resolve through the synthetic-method tier; without it they would
all degrade to undefined-method or `Dynamic[T]` via the
user-class fallback.

## Related

- [ADR-16](../../docs/adr/16-macro-expansion.md) — the substrate
  contract.
- `Rigor::Plugin::Macro::HeredocTemplate`
  ([lib/rigor/plugin/macro/heredoc_template.rb](../../lib/rigor/plugin/macro/heredoc_template.rb))
  — the value class the manifest entries instantiate.
- `Rigor::Inference::SyntheticMethodIndex`
  ([lib/rigor/inference/synthetic_method_index.rb](../../lib/rigor/inference/synthetic_method_index.rb))
  — the index the dispatcher consults.
- `Rigor::Inference::SyntheticMethodScanner`
  ([lib/rigor/inference/synthetic_method_scanner.rb](../../lib/rigor/inference/synthetic_method_scanner.rb))
  — the pre-pass that populates the index from project source.
- Per-library survey, dry-struct section:
  [`docs/notes/20260515-macro-expansion-library-survey.md`](../../docs/notes/20260515-macro-expansion-library-survey.md).
