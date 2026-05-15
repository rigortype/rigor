# dry-rb Ecosystem Plugins — Survey

Status: **research, 2026-05-09.** This document is a one-shot survey
of the dry-rb gem family from a Rigor-plugin standpoint. It captures
inter-gem dependencies and the type-shaping surface each gem exposes,
so a follow-up design doc can decide whether to ship a single
`rigor-dry` plugin, a `rigor-dry-*` family, or a mid-grain split.

The corpus surveyed is the hanakai-rb guide tree at
[`references/hanakai-rb/content/guides/dry/`](../../references/hanakai-rb/),
which is the authoritative public guide for dry-rb after the
hanami / dry / rom organisations merged into hanakai-rb. Dependency
edges below are taken from prose claims in that corpus; gemspec
verification and version-pin decisions are deferred to the
per-plugin authoring step.

This document is informational. Binding plugin contracts will live
in each plugin's own `README.md` and integration spec, mirroring the
Rails-plugins roadmap discipline ([`docs/design/20260508-rails-plugins-roadmap.md`](20260508-rails-plugins-roadmap.md)).

## Why dry-rb is interesting for Rigor

dry-rb is the most type-conscious DSL family in idiomatic Ruby. Three
characteristics make it Rigor-relevant:

1. **Explicit attribute typing.** `dry-struct` / `dry-initializer` /
   `dry-schema` declare per-attribute types via real Ruby objects
   (`Types::String`, `Types::Coercible::Integer`, …) that a plugin can
   walk syntactically.
2. **Structured return shapes.** `dry-monads` and `dry-operation` give
   methods a known monadic envelope (`Result[T, E]`, `Maybe[T]`, …)
   that survives method boundaries — a clear win for narrowing.
3. **Compositional foundation.** Higher-level gems (`dry-validation`,
   `dry-operation`, `dry-rails`) compose lower-level ones
   (`dry-types`, `dry-schema`, `dry-monads`). A bottom-up plugin order
   maps directly onto the dependency edges; the cross-plugin API
   ([ADR-9](../adr/9-cross-plugin-api.md)) is exactly what a multi-gem
   `rigor-dry-*` family will consume for fact-sharing.

This survey pre-dates a commitment to any specific plugin. The goal
is to make subsequent scoping decisions evidence-based.

## Tiering

Each gem is sorted into one of six tiers by the kind of static fact a
Rigor plugin would emit for it.

| Tier | What plugins in this tier do | Members |
| --- | --- | --- |
| A — type system foundations | Declare typed attributes / readers / coerced shapes | dry-types, dry-struct, dry-schema, dry-validation, dry-logic, dry-initializer |
| B — control-flow shapes | Wrap return types in monadic envelopes Rigor can narrow | dry-monads, dry-operation, dry-effects |
| C — DI / configuration | Generate readers / class methods whose return types come from a container or default value | dry-auto_inject, dry-configurable, dry-system, dry-container |
| D — utilities | No static type-shape impact | dry-cli, dry-core, dry-events, dry-files, dry-inflector, dry-logger, dry-monitor |
| E — legacy / superseded | Listed for completeness; covered by replacement | dry-equalizer, dry-matcher, dry-transaction, dry-view |
| F — framework integration | Wires Tier A–C gems into Rails | dry-rails |

Tier A and Tier B are the core Rigor target. Tier C is a stretch
goal that becomes attractive once ADR-9 lands. Tiers D / E / F are
either out of scope (D, E) or thin wrappers over existing plugins
(F).

## Tier A — type system foundations

### dry-types

**Purpose.** Extensible value-type system with coercion, constraint,
and composition combinators.

**Plugin-relevant DSL.**

- `Types = Dry.Types()` opens a module of named types.
- `Types::String`, `Types::Coercible::Integer`, `Types::Strict::*`
  reach into a registry of pre-built carriers.
- `T.optional`, `T.constrained(gteq: 18)`, `T.constructor { … }`,
  `T | U`, `T.default(0)` are the everyday combinators.

**Static facts a plugin would emit.**

- A type expression maps to a Rigor type carrier:
  `Types::String` → `String`, `Types::Coercible::Integer` →
  `Integer`, `T.optional` → `T | nil`, `T | U` → union.
- `T.constrained(gteq: 18)` keeps the static type at `T` and adds a
  predicate fact that downstream narrowing can consume — a candidate
  for Rigor's refinement-name machinery once the v0.1.1 regex →
  refinement recogniser ships.
- Custom-type builders (`.constructor { ... }`) shift the carrier to
  the result type of the block; precise inference there is
  out-of-scope for v1 and can degrade to `Dynamic[T]` per the
  robustness principle.

**Documented dry-* dependencies.** None — dry-types is a foundation.

**Plugin coupling.** Foundational. dry-struct, dry-schema,
dry-validation, dry-initializer, and dry-monads (its `Validated`
monad) all sit downstream.

### dry-struct

**Purpose.** Immutable value objects defined by typed attributes.

**Plugin-relevant DSL.**

```
class User < Dry::Struct
  attribute :name, Types::String
  attribute :age, Types::Coercible::Integer
  attribute :address do
    attribute :city, Types::String
  end
end
```

**Static facts a plugin would emit.**

- Each `attribute :name, T` declares a reader `#name` returning the
  carrier resolved from `T` by the dry-types plugin.
- Block-form attributes (`attribute :address do ... end`) define a
  nested anonymous `Dry::Struct` subclass; the plugin emits both the
  inner class shape and the outer reader returning that class.
- Constructor signature derives from the union of declared attributes.
- `transform_keys(&:to_sym)` and similar do not change the static
  attribute set.

**Documented dry-* dependencies.** Built on dry-types.

**Plugin coupling.** Hard consumer of dry-types facts.

### dry-schema

**Purpose.** Validation and coercion for hash-shaped input. Two
flavours: `Schema.Params` (web-form coercion: strings → integers
/ booleans), `Schema.JSON` (no string coercion). The `_index.md`
states explicitly: *"`dry-schema` uses coercion types from
`dry-types`."*

**Plugin-relevant DSL.**

```
UserSchema = Dry::Schema.Params do
  required(:name).filled(:string)
  required(:age).value(:integer, gt?: 18)
  required(:tags).array(:string)
  required(:address).hash do
    required(:street).filled(:string)
  end
end
```

**Static facts a plugin would emit.**

- A schema constant maps to a typed input → output contract.
- The output of `schema.call(input)` is a result whose `#to_h` /
  `[]` keys are typed per declaration: `:name` → non-empty
  String, `:age` → Integer, `:tags` → Array[String], `:address.street`
  → non-empty String.
- Predicate suffixes (`gt?: 18`) feed Rigor's refinement-name
  catalogue (positive-int et al.) once v0.1.1 lands.
- The Params vs. JSON distinction matters: only Params coerces
  strings — the plugin must record which builder produced the schema
  before resolving coerced types.

**Documented dry-* dependencies.** dry-types (coercion backend),
dry-logic (predicate engine).

**Plugin coupling.** Hard consumer of dry-types and (lightly) dry-logic.

### dry-validation

**Purpose.** Domain validation contracts: a typed `params { ... }`
schema (delegated to dry-schema) plus rule blocks for business logic.

**Plugin-relevant DSL.**

```
class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
    required(:age).value(:integer)
  end

  rule(:email) do
    key.failure('has invalid format') unless EMAIL_RE.match?(value)
  end
end

contract.call(email: 'jane@doe.org', age: '17')
# => Dry::Validation::Result with typed :email / :age
```

**Static facts a plugin would emit.**

- `Contract#call` returns `Dry::Validation::Result`; `#success?` and
  `#failure?` narrow the result; `.to_h` exposes the schema-typed
  hash.
- `params { ... }` and `json { ... }` blocks are dry-schema schemas
  in disguise — the plugin can defer to dry-schema's plugin for the
  inner shape.
- `rule(:email) { ... }` does not change the type of `:email`; it
  only adds business-rule facts.

**Documented dry-* dependencies.** dry-schema (schema engine),
dry-types (coercion).

**Plugin coupling.** Hard consumer of dry-schema (and transitively
dry-types).

### dry-logic

**Purpose.** Predicate composition primitives — `Rule::Predicate`,
`&` / `|` combinators, curried predicates. Used internally by
dry-types (constraints) and dry-schema (predicate suffix DSL).

**Plugin-relevant DSL.** Not commonly hand-written in user code; it
is a library substrate.

**Static facts a plugin would emit.** None at the user-code surface.
A dedicated `rigor-dry-logic` plugin is unlikely to be valuable; the
plugins for dry-types and dry-schema can carry whatever
predicate-aware logic they need internally.

**Documented dry-* dependencies.** None.

**Plugin coupling.** Embedded in dry-types and dry-schema.

### dry-initializer

**Purpose.** `extend Dry::Initializer; param :foo, T; option :bar, T`
generates a typed constructor and accessors without inheritance.

**Plugin-relevant DSL.**

```
class User
  extend Dry::Initializer

  param  :name, proc(&:to_s)
  param  :role, default: proc { 'customer' }
  option :admin, default: proc { false }
  option :phone, optional: true
  option :emails, [] do
    option :address, proc(&:to_s)
  end
end
```

**Static facts a plugin would emit.**

- Each `param` / `option` produces an instance reader; the type is
  the type constraint argument.
- Three reader-type sources need handling:
  - A `Dry::Types['…']` constraint → defer to dry-types plugin.
  - A `proc(&:to_s)` / similar coercer proc → result type is the
    method's return (often known for built-ins like `to_s` →
    `String`, `to_i` → `Integer`).
  - No constraint / a `default:` only → reader returns the default
    expression's type, or `untyped` if absent.
- `optional: true` widens to `T | nil` (unset readers default to
  `Dry::Initializer::UNDEFINED`, but at the user-visible boundary
  `nil` is the right Rigor approximation).
- Nested `option ... do option ... end` defines an inner anonymous
  struct-like class whose readers are themselves typed.

**Documented dry-* dependencies.** None hard. Compatible with
dry-types when the user opts in.

**Plugin coupling.** Optional consumer of dry-types facts. A standalone
`rigor-dry-initializer` plugin remains useful even without
`rigor-dry-types`.

## Tier B — control-flow shapes

### dry-monads

**Purpose.** Algebraic data types for return values: `Result`
(Success/Failure), `Maybe` (Some/None), `Try` (capture exceptions),
`List`, `Task`, `Validated`, `Unit`. Plus `do`-notation for binding
chains.

**Plugin-relevant DSL.**

```
include Dry::Monads[:result]

def call(input)
  Success(input.upcase)
rescue ArgumentError => e
  Failure(e)
end
```

**Static facts a plugin would emit.**

- A method whose returns are `Success(x)` or `Failure(e)` has return
  type `Result[T, E]` where `T` is the union of `Success` argument
  types and `E` the union of `Failure` argument types.
- `Maybe(x)` returns `Some[T] | None` (== `Maybe[T]`).
- `result.value_or(default)` narrows to `T | typeof(default)`;
  `result.bind { |v| ... }` flat-maps over `Success`.
- `case result; in Success[v]; ...; in Failure[k, v]; ...` is
  pattern-matching that Rigor's narrowing already understands at the
  primitive level — the plugin needs to teach it the `Success` /
  `Failure` deconstructions.
- `do`-notation (`yield Success(...)`) binds a value with implicit
  short-circuit on `Failure`; equivalent to `bind` chains for
  inference.

**Documented dry-* dependencies.** None.

**Plugin coupling.** Foundation for dry-operation. Once
`rigor-dry-monads` lands, `Result` / `Maybe` become first-class
narrowing targets across any dry user.

### dry-operation

**Purpose.** Step-based DSL for business operations. Each `step ...`
unwraps a `Result` and short-circuits on `Failure`.

**Plugin-relevant DSL.**

```
class CreateUser < Dry::Operation
  def call(input)
    attrs = step validate(input)
    user  = step persist(attrs)
    step notify(user)
    user
  end
end
```

**Static facts a plugin would emit.**

- `Dry::Operation#call` always returns a `Result[T, E]`. `T` is the
  type of the final non-`step` expression in `call`; `E` is the
  union of failure types from inner `step` calls.
- `step expr` narrows `expr` from `Result[T, E]` to `T` (the
  `Success` payload).
- A bare value at the end of `call` (`user` above) is implicitly
  wrapped in `Success`.

**Documented dry-* dependencies.** dry-monads (the guide opens with
*"lightweight DSL around dry-monads"*).

**Plugin coupling.** Hard consumer of dry-monads facts.

### dry-effects

**Purpose.** Algebraic effects — `Dry::Effects.State(:counter)`,
`Dry::Effects::Handler.State(:counter)`, etc. Side-effect tracking
with composable handlers.

**Plugin-relevant DSL.** Effects are mixed in with `include
Dry::Effects.X(...)` and handled with `include
Dry::Effects::Handler.X(...)`.

**Static facts a plugin would emit.** Effects do not change a
method's return type; they impose a capability requirement (a
matching handler must be in scope at the call site). Modelling that
in Rigor's type lattice is possible but not directly aligned with
v0.1.x carriers. **Recommendation: defer**; revisit once Rigor has
an explicit effect-row carrier (no current ADR for this).

**Documented dry-* dependencies.** None.

**Plugin coupling.** None — orthogonal to the rest of the family.

## Tier C — DI / configuration

### dry-auto_inject

**Purpose.** `Import = Dry::AutoInject(Container); class X; include
Import["users.repo"]; end` — auto-generates `attr_reader :users_repo`
and constructor wiring.

**Static facts a plugin would emit.**

- `include Import["x.y.z"]` declares an instance reader whose name is
  the leaf component of the key (or a normalised form thereof) and
  whose return type is the type registered at that key in the
  container.
- The reader's type cannot be resolved without container introspection
  → requires a companion `rigor-dry-container` / `rigor-dry-system`
  plugin, OR the cross-plugin API ([ADR-9](../adr/9-cross-plugin-api.md))
  to consume container facts as a `FactStore`.

**Documented dry-* dependencies.** Compatible with `Dry::Container`
and `Dry::System`'s containers.

**Plugin coupling.** Cross-plugin (consumes container facts).

### dry-configurable

**Purpose.** `extend Dry::Configurable; setting :foo, default: 1,
reader: true` for class- or module-scoped configuration with optional
class-level reader generation.

**Static facts a plugin would emit.**

- `setting :foo, default: 1, reader: true` generates `Klass.foo` /
  `instance.foo` returning `Integer` (the default's type).
- Nested `setting :db do setting :dsn, default: '…' end` produces a
  nested config object accessible as `Klass.config.db.dsn`.
- `setting :foo, constructor: Types::String` (when supported) feeds
  back into dry-types.

**Documented dry-* dependencies.** None.

**Plugin coupling.** Standalone, with a hook into dry-types if the
constructor form is used.

### dry-system

**Purpose.** Dependency container with auto-registration from
component directories — the basis for Hanami slices.

**Static facts a plugin would emit.**

- `container.register(:key, instance)` and component-directory
  auto-registration populate the container's key→type map.
- `container[:key]` / `container.resolve(:key)` returns the registered
  type.
- Hanami slices (`Hanami.app["users.create"]`) resolve through a
  parent dry-system container.

**Documented dry-* dependencies.** dry-core (Container), dry-auto_inject.

**Plugin coupling.** Producer of facts consumed by dry-auto_inject's
plugin. Likely needs the cross-plugin API
([ADR-9](../adr/9-cross-plugin-api.md)).

### dry-container

**Purpose.** Standalone, thread-safe DI container. Now bundled into
dry-core; the `dry-container` gem itself is a thin re-export.

**Static facts.** Identical surface to `dry-system`'s container, minus
the auto-registration.

**Plugin coupling.** Subsumed by dry-system in practice.

## Tier D — utilities (no static-type-shape impact)

These gems do not declare typed accessors, do not return
shape-bearing values via DSLs, and do not generate methods whose
return types vary by configuration. A Rigor plugin would have nothing
to emit beyond what the underlying RBS already covers.

- **dry-cli** — argument parsing for command classes; arguments are
  string-typed at runtime regardless.
- **dry-core** — assorted helpers (cache, class attributes,
  equalizer, container — see Tier E for the legacy split). Each
  helper is best handled in a plugin where its use shows up
  (e.g. `Equalizer` consumers in dry-struct).
- **dry-events** — pub/sub bus; subscribers receive event hashes
  whose shape is application-defined.
- **dry-files** — filesystem operations.
- **dry-inflector** — string transforms.
- **dry-logger** — structured logging.
- **dry-monitor** — instrumentation hooks.

## Tier E — legacy / superseded

Listed once; the live replacement carries the plugin work.

- **dry-equalizer** → folded into `dry-core` (`Dry::Core::Equalizer`).
- **dry-matcher** → superseded by `dry-monads` pattern matching.
- **dry-transaction** → superseded by `dry-operation`.
- **dry-view** → renamed to Hanami View (out of scope for the dry
  family; covered separately if a Hanami plugin track is opened).

## Tier F — framework integration

### dry-rails

dry-rails is the Rails railtie that wires the dry-rb gems into a Rails
app:

- `safe_params` controller helper (powered by dry-schema) replacing
  strong parameters.
- `ApplicationContract` (powered by dry-validation).
- `Deps` mixin for auto-injection (powered by dry-auto_inject).
- An auto-registered application container (powered by dry-system).

A `rigor-dry-rails` plugin would not add new DSL surface. It would
declare conventions — *"controllers in this app use `safe_params` from
dry-schema"* — so that Rigor knows where to look for the dry-rb
plugin facts in a Rails layout. From a plugin-author standpoint it is
a thin coordinator over the underlying `rigor-dry-schema` /
`rigor-dry-validation` / `rigor-dry-auto_inject` / `rigor-dry-system`
plugins. It also overlaps with the Rails-plugins roadmap; a future
decision should resolve whether `rigor-dry-rails` is a peer of
`rigor-rails-routes` etc., or a glue layer that depends on both
families.

## Dependency graph

Two kinds of edge are interleaved, each labelled:

- **runtime** — the gemspec or guide states a direct require.
- **plugin** — the Rigor plugin for the source must consume facts
  produced by the Rigor plugin for the target.

```
dry-types          — foundation; no dry-* deps.
dry-logic          — foundation; no dry-* deps.
dry-monads         — foundation; no dry-* deps.
dry-effects        — foundation; no dry-* deps.
dry-configurable   — foundation; no dry-* deps.

dry-struct         -> dry-types        (runtime, plugin)
dry-schema         -> dry-types        (runtime, plugin)
                   -> dry-logic        (runtime; plugin only if predicate facts surface)
dry-validation     -> dry-schema       (runtime, plugin)
                   -> dry-types        (runtime; transitively via dry-schema for plugin)
dry-initializer    -> dry-types        (no runtime; plugin if user opts into Types)
dry-operation      -> dry-monads       (runtime, plugin)

dry-container      -> dry-core         (runtime; plugin: low impact)
dry-auto_inject    -> dry-container OR dry-system  (runtime; plugin: container facts)
dry-system         -> dry-container    (runtime, plugin)
                   -> dry-auto_inject  (runtime; plugin: producer for it)

dry-rails          -> dry-system       (runtime, plugin)
                   -> dry-schema       (runtime, plugin)
                   -> dry-validation   (runtime, plugin)
                   -> dry-auto_inject  (runtime, plugin)
```

Two cycles to flag: **dry-system ↔ dry-auto_inject** (each gem's
guide references the other) and **dry-types ↔ dry-schema ↔
dry-validation** (validation contracts can declare ad-hoc types
inline that dry-schema interprets via dry-types). Both are dependency
*directions* a plugin author can resolve by ordering: build the
producer plugin first (`dry-types`, `dry-system`), then the consumer
(`dry-schema` / `dry-validation`, `dry-auto_inject`).

## Packaging strategies

Three plausible carve-outs, each with tradeoffs. **No recommendation
in this document** — the choice belongs to the design step that
follows. Notes below are tradeoff calls, not endorsements.

### Strategy 1 — single `rigor-dry`

One plugin gem covering Tiers A and B (and optionally C).

- **Pro.** Single Gemfile entry, single semver, no inter-plugin fact
  protocol needed (everything lives in one plugin's process).
- **Pro.** Simpler initial authoring — the v0.1.0 plugin contract is
  proven; no new cross-plugin API surface required.
- **Con.** Releases couple unrelated changes (a dry-monads tweak
  ships with a dry-struct fix).
- **Con.** Users on a partial dry-rb adoption (e.g. only dry-struct +
  dry-types) carry analyser cost for gems they do not use unless the
  plugin is explicitly modular internally.
- **Con.** When the upstream gems version-lockstep diverges (and they
  do — `dry-types` 1.7 vs 1.8 ship at different cadences), a
  monolithic plugin must follow the slowest gem.

### Strategy 2 — full `rigor-dry-*` family

One plugin per upstream gem (Tier A: 5 plugins, Tier B: 2, Tier C:
3 = 10 gems before dry-rails).

- **Pro.** Each plugin tracks its upstream gem's version cadence
  cleanly.
- **Pro.** Users opt in à la carte; the Gemfile lists exactly the
  dry-rb surface they actually depend on.
- **Pro.** Mirrors the dry-rb organisation principle — small, focused
  units that compose.
- **Con.** Requires the cross-plugin API ([ADR-9](../adr/9-cross-plugin-api.md))
  before plugins like `rigor-dry-validation` /
  `rigor-dry-auto_inject` can do their job. ADR-9 is queued for v0.1.x
  but not yet implemented.
- **Con.** Ten plugin repositories, ten CI pipelines, ten changelogs,
  ten subtree splits.

### Strategy 3 — mid-grain bundles

Three to four plugins grouped by tier:

- `rigor-dry-types-family` — covers dry-types, dry-struct, dry-schema,
  dry-validation, dry-initializer (Tier A minus dry-logic).
- `rigor-dry-monads-family` — covers dry-monads, dry-operation
  (Tier B minus dry-effects, which is deferred).
- `rigor-dry-system-family` — covers dry-container, dry-auto_inject,
  dry-system, dry-configurable (Tier C).
- `rigor-dry-rails` — coordinator gem depending on all three.

- **Pro.** Each bundle is internally cohesive: one shared internal
  fact bus, one release cycle, one author can hold the whole bundle
  in their head.
- **Pro.** Cross-bundle handoffs (Tier A ↔ Tier C in dry-rails, or
  dry-validation pulling from dry-types) are the only places that
  need the cross-plugin API — fewer ADR-9 dependencies than Strategy 2.
- **Con.** Bundle boundaries are partly conventional. A user who only
  uses dry-struct still pulls in the schema/validation plugin code.
- **Con.** Internal modularity inside each bundle still has to be
  designed — otherwise the bundle becomes a mini-monolith with the
  same versioning hazards as Strategy 1 at a smaller scale.

## Dependence on Rigor v0.1.x work

The packaging choice is sensitive to two upcoming pieces of analyser
work:

- **ADR-9 cross-plugin API** ([`docs/adr/9-cross-plugin-api.md`](../adr/9-cross-plugin-api.md))
  — required for any plugin that consumes another plugin's facts
  (dry-validation needing dry-schema's coerced shapes, dry-auto_inject
  needing dry-system's container map). Strategy 1 sidesteps it;
  Strategies 2 and 3 are blocked on it for the cross-plugin handoffs.
- **v0.1.1 regex → refinement-name recogniser**
  (see [`docs/ROADMAP.md`](../ROADMAP.md))
  — slice 1 has landed unreleased. Once the full recogniser ships,
  dry-schema predicates like `gt?: 18` and `format?: /\A.../` map to
  built-in refinement names cleanly. Until then, predicate facts
  are recorded but not type-narrowing.

Neither of these blocks an MVP that limits itself to dry-types
+ dry-struct + dry-monads (the three gems that produce facts
locally without needing to consume facts from another plugin). That
tight subset is plausibly the right v1 in any of the three
strategies.

## Resolutions and open items

Resolutions captured 2026-05-09 in the discussion that followed this
survey landing. Open items remain genuinely undecided.

1. **MVP timing — RESOLVED.** No rush on the dry plugins. Land
   [ADR-9 cross-plugin API](../adr/9-cross-plugin-api.md) first,
   then revisit packaging. This removes the pressure that would have
   forced Strategy 1 as the only viable pre-ADR-9 path; Strategies 2
   and 3 are live candidates once ADR-9 ships.
2. **`rigor-dry-rails` placement — DELEGATED.** No strong preference
   — implement under whichever family is easier to author. The
   decision can be made at the time the plugin is scaffolded rather
   than committed in advance.
3. **dry-effects — DEFERRED.** Effect-system support is wanted in
   principle but there is no concrete plan; revisit when an effect-row
   carrier or similar appears in the Rigor type lattice.
4. **Hanami / rom plugins — QUEUED.** Targeted for the version after
   the dry-rb plugins land. The Hanami plugin will pull in the
   dry-system plugin; rom plugin scope is unscoped here.
5. **dry-rb gemspec verification — OPEN.** No strong opinion yet.
   Likely worthwhile before locking a packaging strategy in
   ADR-12, but not blocking.

## Next step

Land [ADR-9 cross-plugin API](../adr/9-cross-plugin-api.md). Then
file ADR-12 capturing the dry-rb packaging strategy choice. The first
plugin to author — under any strategy — is `rigor-dry-types`, since
every other Tier A plugin depends on it.
