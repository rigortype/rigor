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

## Shipped DSL signature (`sig/graphql.rbs`)

graphql-ruby ships no RBS of its own, so the manifest's
`signature_paths:` contributes the class-level DSL surface —
`field`, `argument`, `value`, `implements`, `description`,
`graphql_name`, the `Schema` registration macros, and friends —
following graphql-ruby's real `Member`-rooted ancestry. Return types
are the real carriers (`field` → `Schema::Field`, `argument` →
`Schema::Argument`, `Enum.value` → `Schema::EnumValue`), not `void`,
which the engine recovers as `top` in value position.

Two manifest fields make the signature reach subclass bodies:

- `rbs_complete_ancestors:` (ADR-43 WD4) lists the GraphQL base
  classes the sig covers completely, so a Ruby-source
  `class PostType < GraphQL::Schema::Object` resolves inherited DSL
  calls against the bundled sig — including through intermediate
  source base classes (`BaseObject < GraphQL::Schema::Object`).
- `open_receivers:` keeps the same classes exempt from
  `call.undefined-method` on members the sig does not declare, because
  graphql-ruby's surface stays open to `use`-able plugins and user
  base classes.

Deferred, per the sig file's header: `include
GraphQL::Schema::Interface`'s include-time `DefinitionMethods`
extension, zero-arity `field ... do ... end` `instance_eval` self
(the one-parameter `|f|` form types through the declared block
parameter), and `Schema.execute` result typing (#136).

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... produces:)` | Declares the four cross-plugin fact ids. |
| `manifest(... signature_paths:)` | Bundles `sig/graphql.rbs` — the class-level DSL surface (ADR-25). |
| `manifest(... rbs_complete_ancestors:)` | Lets source subclasses bridge inherited calls to the bundled sig (ADR-43 WD4). |
| `manifest(... open_receivers:)` | Keeps the declared classes exempt from `call.undefined-method` on non-declared members (ADR-26). |
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
