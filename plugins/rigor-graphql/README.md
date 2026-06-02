# rigor-graphql

Tier 3D per the
[Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md):
recognises GraphQL-Ruby `Schema::Object` / `Schema::Enum` /
`Schema::InputObject` / `Schema::Mutation` subclasses and walks their
`field` / `value` / `argument` DSL declarations, publishing the
resulting type tables as [ADR-9](../../docs/adr/9-cross-plugin-api.md)
cross-plugin facts.

> **Using this plugin?** The user guide — the four published facts and
> their shapes, type mapping, nullability, and limitations — lives in
> the manual at
> [docs/manual/plugins/rigor-graphql.md](../../docs/manual/plugins/rigor-graphql.md).
> This README covers the plugin's internals.

## Published facts

One project walk publishes four independent facts, each suppressed when
its source class is absent:

| Fact | Source class | Value shape |
| --- | --- | --- |
| `:graphql_type_table` | `Schema::Object` | `field` → `{type, nullable, list}` |
| `:graphql_enum_table` | `Schema::Enum` | `value "..."` → ordered value list |
| `:graphql_input_object_table` | `Schema::InputObject` | `argument` → `{type, required, list}` |
| `:graphql_mutation_table` | `Schema::Mutation` | `{arguments:, fields:}` combined |

Per-mutation argument and field tables share the same value shape as
their standalone Input + Object equivalents, so consumers can treat
them uniformly.

## Why this is a metadata-recorder plugin (not ADR-16 substrate)

graphql-ruby's `field` DSL is a **pure metadata recorder** — it just
appends to the class's `own_fields` registry; it does NOT emit Ruby
methods. The user writes resolver methods themselves. This makes the
gem an unusual fit for the ADR-16 macro-expansion substrate (which
synthesises methods from manifest declarations).

The macro-expansion library survey at
[`docs/notes/20260515-macro-expansion-library-survey.md`](../../docs/notes/20260515-macro-expansion-library-survey.md)
§ "GraphQL-Ruby" documents the analysis: graphql-ruby is "neither
Lisp-macro nor PHPStan-trait" because there's no Ruby method to expand.
Rigor's value for graphql-ruby is therefore a STATIC TYPE TABLE
downstream consumers can cross-reference — not method synthesis.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... produces:)` | Declares the four cross-plugin fact ids. |
| `prepare(services)` + `scannable_paths(services)` | Scans every `paths:` entry's `.rb` files for schema-class shapes. |
| `services.fact_store.publish` (ADR-9) | Publishes each frozen table; empty tables are suppressed via `publish_if_present`. |
| `Rigor::Source::Literals.symbol_name` | Symbol/string argument extraction in the `field` / `argument` / `value` parse. |

## Related

- [Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)
  § 3D — the tiering entry for this plugin.
- [Macro expansion library survey](../../docs/notes/20260515-macro-expansion-library-survey.md)
  § "GraphQL-Ruby" — the analysis that grounded the metadata-recorder
  plugin shape rather than ADR-16 substrate.
- [ADR-9](../../docs/adr/9-cross-plugin-api.md) — the cross-plugin fact
  channel these tables use.
