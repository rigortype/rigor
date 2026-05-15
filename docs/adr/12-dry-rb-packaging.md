# ADR-12 — dry-rb plugin packaging

Status: **accepted, 2026-05-16.** Decides the packaging shape for
Rigor's dry-rb adapter plugins so individual `rigor-dry-*` work can
start without re-litigating fundamentals.

## Context

The dry-rb gem family is a tree of complementary gems: `dry-types`,
`dry-struct`, `dry-validation`, `dry-monads`, `dry-schema`,
`dry-effects`, `dry-events`, `dry-system`, `dry-files`, and several
others. They share idioms (constructor-style classes, struct-based
attribute lists, Monad-like return envelopes) but each gem exposes
its own DSL surface. The [`20260509-dry-plugins-roadmap.md`](../design/20260509-dry-plugins-roadmap.md)
survey is the binding inventory of which gems matter for static
analysis, their inter-gem dependencies, and the type-shaping
surface each one publishes.

[`rigor-dry-struct`](../../examples/rigor-dry-struct/) shipped in
v0.1.5 as the first dry-* plugin, exercising the
[ADR-16](16-macro-expansion.md) Tier C (heredoc-template) substrate.
The shape of `rigor-dry-types`, `rigor-dry-validation`,
`rigor-dry-monads`, … is enough like `rigor-dry-struct` that the
packaging question — **one mega-gem? per-gem? mid-grain bundles?
meta umbrella?** — needs an explicit answer before the next plugin
ships.

The same question was answered for the Rails plugin family in
[`docs/design/20260508-rails-plugins-roadmap.md`](../design/20260508-rails-plugins-roadmap.md):
per-gem plugins staged under `examples/rigor-<id>/` and extracted
via `git subtree split` once each plugin's contract stabilises,
with a future `rigor-rails` meta-gem listing the Tier 1+2 plugins
as gem dependencies. The same pattern works for dry-rb.

## Decision

**Per-gem plugins + meta umbrella, matching the Rails plugin
family pattern.**

- Each dry-* gem gets its own Rigor plugin: `rigor-dry-types`,
  `rigor-dry-struct`, `rigor-dry-validation`, `rigor-dry-monads`,
  `rigor-dry-schema`, … one-to-one with the upstream gem boundary.
- Plugins are staged under `examples/rigor-dry-<id>/` per the
  [`rigor-plugin-author`](../../.codex/skills/rigor-plugin-author/SKILL.md)
  SKILL discipline.
- When a plugin's contract stabilises it is extracted via
  `git subtree split` into its own published gem, on the same
  schedule and readiness checklist the Rails plugin family uses.
- A future `rigor-dry-rb` meta-gem will declare the in-tree
  plugins as gem dependencies so a single Gemfile line opts the
  user into the whole stack.

Rejected alternatives are recorded under "Alternatives considered".

## Sequencing

The bottom-up dependency order from the
[`20260509-dry-plugins-roadmap.md`](../design/20260509-dry-plugins-roadmap.md)
survey carries over:

1. **`rigor-dry-types`** (Tier A foundation). Recognises
   `Types::String` / `Types::Coercible::Integer` / `Types::Strict::Bool`
   / … constants and contributes `Nominal[String]` / etc. as the
   per-attribute type. Foundation for every higher-tier plugin.
2. **`rigor-dry-struct`** (Tier A, LANDED v0.1.5). Already ships
   via ADR-16 Tier C substrate. The pre-ADR-12 packaging was
   already aligned with this decision; no re-packaging needed.
3. **`rigor-dry-validation`** (Tier A). Recognises
   `Dry::Validation::Contract` subclasses + their `schema`/`params`
   DSL. Builds on `rigor-dry-types` for the per-key type.
4. **`rigor-dry-monads`** (Tier B). Wraps return types in
   `Result[T, E]` / `Maybe[T]` envelopes. Independent of Tier A
   plugins but coexists when a Tier A plugin types the inner `T`.
5. **`rigor-dry-schema`** (Tier A). Similar to `dry-validation`
   but standalone. Lower priority than validation in practice.
6. **`rigor-dry-effects`** (Tier B). Effect-system DSL. Niche
   enough to be demand-driven.
7. **Tier C / D / E / F** — defer per the survey's classification.

The next slice is **`rigor-dry-types`** (the Tier A foundation).

## Plugin contract reuse

The four substrate Tiers from [ADR-16](16-macro-expansion.md) are
the building blocks:

| dry-* gem | Substrate Tier (likely) | Notes |
| --- | --- | --- |
| `dry-types` | Hand-rolled walker (constant resolution) | Each `Types::Foo` literal is a constant reference; no class-body DSL to ride a substrate Tier on. |
| `dry-struct` | Tier C (heredoc-template) | LANDED. `attribute :name, T` per-method emission. |
| `dry-validation` | Tier A (block-as-method) + walker | `schema { … }` block runs against a schema DSL receiver; combine block-as-method for the block surface with a hand-rolled walker for the keys. |
| `dry-monads` | `flow_contribution_for` | Return-type rewriting (`def x; Success(42); end` → `Result[Integer, untyped]`) is wholly a return-type computation; no class-body DSL. |
| `dry-schema` | Same as dry-validation | Symmetric DSL. |
| `dry-effects` | Tier A or Tier B | Depends on observed idiomatic usage — defer until concrete plugin starts. |

Plugin authors pick the substrate Tier per upstream DSL shape; the
packaging decision here is orthogonal to which Tier each plugin
ends up using.

## Cross-plugin fact dependencies

Higher-tier plugins consume Tier-A plugin facts via the
[ADR-9](9-cross-plugin-api.md) `Plugin::FactStore` channel. The
canonical channel names for dry-* plugins will be:

- `:dry_type_aliases` — published by `rigor-dry-types`, consumed
  by `rigor-dry-struct` / `rigor-dry-validation` / `rigor-dry-schema`
  so a `MyTypes::Email = Types::String.constrained(format: …)`
  alias is visible across plugins.
- `:dry_struct_attributes` — published by `rigor-dry-struct`,
  consumed by downstream plugins (e.g. a serializer plugin) that
  need to know each struct's attribute list.
- `:dry_validation_keys` — published by `rigor-dry-validation`,
  consumed by `rigor-actionpack` strong-params recognisers when
  a controller delegates its params validation to a dry-validation
  Contract.

The exact fact-store payload shapes are decided per plugin; this
ADR only commits to the cross-plugin coordination pattern.

## Public-API drift surface

ADR-12 itself adds no new code surface. The per-plugin gemspecs
will each grow public APIs that
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
must pin; per the Rails plugin family precedent, plugin-internal
classes (the walker, the fact-store payload class) stay outside the
drift snapshot — only the `Plugin::Base` subclass + its
`#manifest` shape are pinned.

## Working decisions

### WD1 — Why per-gem, not a mega `rigor-dry-rb` gem?

Three arguments together:

1. **Bloat.** A user analysing dry-types-only code would otherwise
   load the validation / monads / schema walkers they don't need.
   The walker tier ordering (RBS > `RBS::Extended` > plugins > …)
   per ADR-2 means every loaded plugin participates in dispatch
   even when its receiver classes never appear, so bundle size
   matters.
2. **Coupling.** dry-* gems version independently upstream
   (`dry-types` 1.7 vs `dry-monads` 1.6 etc.). A mega-gem would
   need to release whenever ANY of its dependencies bumped, even
   if only one plugin's walker changed.
3. **Precedent.** The Rails plugin family already chose per-gem +
   meta umbrella, with the meta-gem (planned `rigor-rails`)
   listing Tier 1+2 plugins as gem dependencies. Repeating the
   pattern for dry-rb keeps the ecosystem coherent.

### WD2 — Why not mid-grain bundles (e.g. `rigor-dry-data` for types + struct + validation + schema)?

Mid-grain bundles look attractive because the dry-rb survey
clusters the family into Tiers A through F. But the clustering is
**by analytical shape** (what a plugin does), not by **what a user
installs**. A user might use `dry-struct` (Tier A) without
`dry-validation` (Tier A) — the cluster doesn't predict
co-installation. Per-gem stays faithful to actual Gemfile
patterns.

The exception is when two upstream gems are so coupled that
splitting their plugin walkers is awkward (e.g.
`dry-schema` + `dry-validation` share a key-coercion DSL).
Plugin authors MAY merge two plugins into one when the *walker
code* genuinely duplicates; the packaging decision stays per-gem
in all other cases.

### WD3 — Subtree-split readiness checklist (inherits from Rails)

A `rigor-dry-<id>` plugin is ready for `git subtree split` when:

1. The plugin's `manifest`, walker, and integration spec are
   stable enough that the next month of changes will be additive
   (no breaking signature changes).
2. There's a worked integration spec under
   `spec/integration/examples/<plugin_name>_plugin_spec.rb` that
   would CI against an external clone of the plugin.
3. `public_api_drift_spec.rb` pins the plugin's `Plugin::Base`
   subclass + manifest shape.
4. The plugin's `README.md` includes a "What this plugin DOES /
   DOES NOT do" section so users can decide whether they need it.

The checklist matches the Rails plugin readiness conditions; no
dry-specific carve-outs.

### WD4 — Meta umbrella `rigor-dry-rb` deferred

The umbrella gem is **planned but not committed**. It lands when:

1. Three or more `rigor-dry-*` plugins have shipped via subtree
   split; AND
2. Users have requested "one-line install for the whole stack"
   in a way that justifies the maintenance overhead of a
   meta-gem (release coordination, dep version pins across
   sub-gems).

Before then, users can list individual gems in their `Gemfile`.

### WD5 — `rigor-dry-types` is the next concrete slice

The next implementation step is `examples/rigor-dry-types/`. It's
the foundation every higher-tier dry-* plugin reads. The plugin's
work is concentrated in a hand-rolled walker that recognises the
`Types::String` / `Types::Coercible::Integer` / `Types::Strict::Bool`
constant references and contributes per-attribute types so
downstream plugins (`rigor-dry-struct`, `rigor-dry-validation`)
can pick them up via the [ADR-9](9-cross-plugin-api.md)
`:dry_type_aliases` channel.

## Alternatives considered

- **Single `rigor-dry-rb` mega-gem.** Rejected per WD1.
- **Mid-grain bundles by tier.** Rejected per WD2.
- **Inline merging two plugins (e.g. `rigor-dry-schema-validation`)** —
  permitted per WD2 *only* when walker code genuinely duplicates;
  default stays per-gem.
- **Ship `rigor-dry-rb` umbrella up-front before individual plugins
  exist** — rejected; the umbrella is a convenience, not a
  prerequisite. Per WD4.

## Open questions

- **`dry-rails` adapter handling.** `dry-rails` wires dry-* into
  Rails; do we need `rigor-dry-rails` separately, or does
  `rigor-rails` (the planned meta-gem) absorb it? Decision
  deferred to when `rigor-rails` lands.
- **dry-monads `Result[T, E]` carrier.** A faithful Result /
  Maybe carrier inside `Rigor::Type::*` would let `rigor-dry-monads`
  contribute precise narrowing on `.success?` / `.failure?`
  predicates. Today the plugin contributes via
  `flow_contribution_for` returning `Dynamic[T]`-tagged unions.
  Carrier introduction is a separate ADR (ADR-3 amendment) and
  out of scope here.

## Revision history

- 2026-05-16 — initial proposal + acceptance, locking in
  per-gem + meta umbrella for the dry-rb plugin family. Triggered
  by the v0.1.6 cycle scoping discussion after v0.1.5 release.
