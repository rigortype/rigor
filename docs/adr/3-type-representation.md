# ADR-3: Internal Type Representation

## Status

Draft.

ADR-3 records the design space for Rigor's internal type-object layout: the Ruby classes, modules, methods, and value objects that implement the type model. ADR-3 does **not** redefine semantics — those are owned by ADR-1 and the type specification — and it does **not** define the plugin contract — that is owned by ADR-2. ADR-3 captures the rationale and the open questions that surround the analyzer-side data shapes that ADR-1 and ADR-2 attach to.

The decisions that have stabilized are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). When that document and this ADR disagree, the spec binds and this ADR is updated to match. The same precedence applies to the type specification: when [`docs/type-specification/`](../type-specification/) disagrees with this ADR on observable behavior, the type spec binds.

## Context

Rigor needs an internal type representation before any vertical-slice implementation can land. The type specification has stabilized enough to enumerate the forms the representation must cover (see [`docs/type-specification/rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md), [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md), [`docs/type-specification/special-types.md`](../type-specification/special-types.md), [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)). ADR-1 fixes the relations and the dynamic-origin algebra ([`docs/adr/1-types.md`](1-types.md), [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md), [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md)). ADR-2 fixes the extension surface that consumes type values ([`docs/adr/2-extension-api.md`](2-extension-api.md), in particular the *Type System Object Model* and *Scope Object* sections).

The remaining decision is *how* the analyzer represents those forms in Ruby code: which classes exist, how methods are grouped, how relational answers are returned, and where the boundary between "decided" and "deferred to implementation" should fall.

## Reference Model: PHPStan `Type`

The closest practical reference is PHPStan's `Type` interface and its `TrinaryLogic` companion in `phpstan/phpstan-src`. Indicative upstream paths:

- [`src/Type/Type.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Type.php) — the central interface every type implements.
- [`src/Type/Constant/ConstantStringType.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Constant/ConstantStringType.php) — a representative literal-value implementation.
- [`src/Type/Accessory/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Accessory) — refinement-only types that compose through `IntersectionType`.
- [`src/Type/Generic/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Generic) — template parameters, variance, and generic carriers.
- [`src/TrinaryLogic.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/TrinaryLogic.php) — the three-valued result class shared by capability and relational queries.
- [`src/Type/IsSuperTypeOfResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/IsSuperTypeOfResult.php) and [`src/Type/AcceptsResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/AcceptsResult.php) — result objects that bundle a trinary answer with reason metadata.

The `phpstan-src` repository is **not** part of Rigor's submodules — `references/phpstan` carries the website (`website/`) only — so these citations are external pointers. The `references/phpstan/website/src/developing-extensions/type-system.md` document inside the Rigor checkout is the closest in-repo description.

The patterns Rigor adopts from this reference, regardless of which open question is resolved later, are:

- **Never use `instanceof` to switch on a type.** PHPStan's interface comment is explicit: callers ask `$type->isString()->yes()` rather than `$type instanceof StringType`. Rigor follows the same rule. Concrete classes are implementation details.
- **Empty/non-empty array as a monad-like witness list.** Methods such as PHPStan's `getConstantStrings(): list<ConstantStringType>` return an empty array when the analyzer cannot prove any constant string witnesses, and a non-empty list otherwise. Unions and intersections compose by combining witness lists. Rigor adopts this pattern for refinement projections.
- **Trinary results, separated from booleans.** Capability questions return a three-valued result (`yes`/`no`/`maybe`); only specific result classes wrap that value with reasons. Rigor adopts the same separation but in Ruby idiom.
- **Compound types are wrappers, not subclasses.** PHPStan's `IntersectionType`, `UnionType`, `GenericObjectType`, `ConstantArrayType`, and the accessory types compose by holding inner `Type` references. Rigor's wrappers (`Dynamic`, `Refined`, `Union`, `Intersection`, `Difference`, generic carriers) follow the same composition.

PHPStan also uses class inheritance internally for code reuse (for example `ConstantStringType extends StringType`). Rigor deliberately diverges here: the Rigor type representation has **no inheritance between type classes**. The next section explains why.

## Ruby-Specific Framing

Rigor targets Ruby. Three properties of Ruby drive deviations from the PHPStan model:

- **Every value is an object.** PHP's split between scalar and object values does not exist in Ruby. The integer literal `1` already carries class information through `1.class == Integer`. A "constant string" type and a "constant integer" type can in principle share a single Ruby carrier whose discrimination is `value.class`, although a per-class layout is also possible. This is the substance of open question 1.
- **`?`-suffixed methods conventionally return booleans.** Ruby readers expect `string?` to return `true` or `false`. Rigor's capability queries return a three-valued result. The naming convention must either drop the `?`, redefine it locally, or expose two parallel surfaces. This is the substance of open question 2.
- **Mixin-based composition is idiomatic.** Ruby modules can share trait-like behavior without imposing a class hierarchy. Rigor uses modules narrowly for shared structural-equality and identity contracts, not as a type taxonomy.

The rest of this ADR records the design rationale, the open questions, and the planning checklist. The decisions that have stabilized are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md); when this ADR and that document appear to disagree, the spec binds.

## Normative Contract

The decided parts of the internal type representation — immutable value objects, structural equality, no inheritance between type classes, capability queries returning `Rigor::Trinary`, refinement projections returning `Array<Type>`, compound forms as wrappers, relational queries returning result objects, factory-routed normalization, the method surface, the module layout, and the diagnostics-display routing — are normative in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). Engine and plugin code MUST follow that document. This ADR is retained for design rationale, the rejected/deferred options below, and the planning checklist; it MUST NOT be treated as binding for the contracts that have moved.

The engine-surface contract that surrounds those type objects (`Scope`, fact store, effect model, capability-role inference, normalization, RBS erasure routing, public stability rules) is normative in [`docs/internal-spec/implementation-expectations.md`](../internal-spec/implementation-expectations.md).

## Open Questions

Two questions are recorded here as Options Considered with explicit trade-offs. ADR-3 deliberately does **not** pick a Working Decision for either; both are deferred to the first implementation slice (see *Implementation Roadmap* below) so the chosen answer is exercised in real code before this document upgrades to a Working Decision.

### Open Question 1: Constant Scalar and Object Shape

When the analyzer can prove that a value equals a specific Ruby literal (`1`, `"aaa"`, `:sym`, `true`, `false`, `nil`), how should that fact be carried in the type representation?

**Option A — Unified carrier.**

A single `Rigor::Type::Constant.new(value)` class wraps any Ruby literal. Behavior dispatch reads `value.class` (and the value itself when needed).

- Benefits: very Ruby-idiomatic; uses the all-objects premise directly; minimal class count; new scalar-like literal kinds (for example future `Rational` literals) need no new class.
- Drawbacks: refinement projections (`constant_strings`, `constant_integers`, …) must filter the same class on `value.class`, which is mechanical but slightly less self-documenting than per-class projections; refinements that decorate a specific Ruby class (`non-empty-string`, `lowercase-string`) must compose against `Constant` and `Nominal::String` uniformly.

**Option B — Specialized per Ruby class.**

Distinct classes such as `Rigor::Type::String::Constant`, `Rigor::Type::Integer::Constant`, `Rigor::Type::Symbol::Constant`, with a separate boolean and nil treatment. This is closest to PHPStan's layout (`ConstantStringType`, `ConstantIntegerType`, …).

- Benefits: refinement projections become a direct `case` of "include all instances of `String::Constant`"; refinements specific to one Ruby class colocate naturally; static analyzers (including future plugin authors) can pattern-match the class without `value.class` dispatch.
- Drawbacks: more classes (one per supported literal kind plus their refinement neighbours); each new literal kind requires a new class even when the algebra is the same; a parallel hierarchy mirroring Ruby's value classes risks drift if we forget a class.

**Option C — Hybrid.**

Unified `Constant` for scalar-like literals (`String`, `Integer`, `Float`, `Symbol`, `Rational`, `Complex`, `true`, `false`, `nil`); dedicated classes for compound literal shapes (`Tuple`, `HashShape`, `Record`) because those carry inner `Type` references and shape policies that don't compress to a single Ruby value.

- Benefits: scalar carriage stays compact and Ruby-idiomatic; compound shapes get the structure they need anyway; matches the way [`rigor-extensions.md`](../type-specification/rigor-extensions.md) already separates "finite set of literals" from "object/hash shape refinements".
- Drawbacks: introduces a soft boundary between "scalar literal" and "compound literal" that has to be documented; a compound literal whose elements are all constants (`[1, 2, 3]`) needs a clear answer about whether it's a `Tuple` of `Constant`s or a constant-array shape carrying raw values.

**Trade-off axes to revisit during the slice.**

- *Refinement composition cost* — how `non-empty-string`, `lowercase-string`, `numeric-string`, and `decimal-int-string` attach to a string constant in each option.
- *Plugin authoring surface* — what ADR-2 plugin authors see when they enumerate constant witnesses or build a literal-typed return.
- *RBS erasure handle* — how erasure for a `String` literal singleton ([`rbs-erasure.md`](../type-specification/rbs-erasure.md)) traverses each shape.
- *Normalization cost* — how the deterministic normalization rules in [`normalization.md`](../type-specification/normalization.md) route through each layout, and whether flyweighting is helpful or noisy.
- *Diagnostic display* — how the `describe(verbosity)` output in each option matches the rules in [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md) and [`type-operators.md`](../type-specification/type-operators.md).

### Open Question 2: Trinary-Returning Predicate Naming

Capability methods return `Rigor::Trinary`, not Ruby booleans. Ruby's convention is that `?`-suffixed methods return booleans. The two facts collide.

**Option A — Drop the `?`.**

`type.string`, `type.integer`, `type.subtype_of(other)`, `type.has_method(name)`. Reads as a noun/verb form; the name signals "the answer object", not "a yes/no question".

- Benefits: no ambiguity about return type; consistent with PHPStan's `isString()` (which is also not a Ruby `?`-style call); call sites that need a boolean continue with `type.string.yes?`.
- Drawbacks: less idiomatic Ruby; readers may instinctively type `type.string?` and get a `NoMethodError`.

**Option B — Keep the `?` and document the deviation.**

`type.string?`, `type.subtype_of?(other)` return `Rigor::Trinary` instead of a boolean. The deviation is recorded in this ADR and in `Rigor::Type` documentation comments.

- Benefits: idiomatic Ruby surface; readers reach for the natural form; the `?`-but-not-boolean rule is shared with libraries such as `RuboCop::Cop::Lint::AmbiguousBlockAssociation` etc. (though they remain rare).
- Drawbacks: silently returns a non-boolean from a `?`-suffixed method, which conflicts with widely-held expectations and may confuse contributors and downstream tools (RBS lint rules, type checkers, IDE inlay hints).

**Option C — Dual API.**

`type.string` returns `Trinary`; `type.string?` is sugar for `type.string.yes?` and returns a boolean. Both surfaces exist; call sites pick the appropriate ergonomics.

- Benefits: callers who only care about "is it definitely yes" stay in idiomatic Ruby; callers who need to handle `maybe` reach for the non-`?` form; nothing silently returns the wrong shape.
- Drawbacks: doubles the surface; raises the risk of drift between the two when refinements are added; tempts callers to default to `?` and silently lose `maybe`-aware behavior, which is exactly what [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md) warns against.

**Cross-cutting requirements for whichever option wins.**

- The `Rigor::Trinary` value object MUST itself have `yes?`, `no?`, `maybe?` methods; those *are* booleans by the ordinary Ruby convention.
- Whichever option is chosen, every `Rigor::Type` method that returns a trinary MUST follow the same convention (no per-class deviation).
- The capability surface and the relational surface MUST agree: if capability methods drop `?`, relational methods do too, and vice versa.

## Class Catalogue Draft

This catalogue is **not** normative. It is a checklist that the type specification is covered by the planned representation. Each entry cross-references the binding spec section.

- **Special**: `Top`, `Bot`, `Dynamic`, `Void`. `Untyped` resolves to `Dynamic[Top]` at construction; it is not a separate class. See [`special-types.md`](../type-specification/special-types.md) and [`value-lattice.md`](../type-specification/value-lattice.md).
- **Nominal**: `Nominal` (instance type for a class or module), `Singleton` (class-object type, RBS `singleton(C)`), `Self`, `Instance`, `ClassMarker`. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md).
- **Structural**: `Interface` (named RBS interface), `ObjectShape` (anonymous structural type), `Capability` (capability role), `MethodSignature`, `ProcSignature`, `BlockSignature`. See [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md).
- **Containers**: `ArrayShape`, `Tuple`, `HashShape`, `Record`. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md) for the RBS-derived forms and [`rigor-extensions.md`](../type-specification/rigor-extensions.md) for the refinements (required/optional keys, read-only entries, extra-key policy).
- **Constants**: shape depends on open question 1. Either `Constant` (Option A), `String::Constant` / `Integer::Constant` / `Symbol::Constant` / … (Option B), or a hybrid (Option C). The rest of the catalogue does not depend on the resolution.
- **Combinators**: `Union`, `Intersection`, `Difference`, `Complement`. See [`type-operators.md`](../type-specification/type-operators.md).
- **Refinements**: `RefinedNominal` (e.g. `String where non_empty`), `IntegerRange`, `FiniteLiteralUnion`, `TruthinessRefinement`, `RelationalFact`, `FactStability`, `TemplateLiteralLikeString`. See [`rigor-extensions.md`](../type-specification/rigor-extensions.md). Imported built-in refinement names are catalogued in [`imported-built-in-types.md`](../type-specification/imported-built-in-types.md).
- **Generic position carriers**: `Generic`, `TemplateParameter`, `Variance`. Variance is a tag, not a separate type form. See [`rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md).

Every entry MUST satisfy the method surface in [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md). Wrappers (`Dynamic`, refinements, combinators, generic carriers) MUST forward queries into their inner types according to the algebraic rules in [`value-lattice.md`](../type-specification/value-lattice.md).

## Implementation Roadmap

The roadmap is informational, not normative. It scopes the first vertical slice that exercises both open questions in real code.

The first slice should cover, end to end:

- `Rigor::Trinary` with `yes`, `no`, `maybe` flyweights and the standard combinators.
- `Top`, `Bot`, and `Dynamic[T]` wrapper.
- One nominal type (e.g. `Nominal` for `String`).
- One concrete answer to open question 1: a unified `Constant`, a specialized `String::Constant`, or the hybrid carved at the scalar/compound boundary.
- One concrete answer to open question 2: the chosen naming convention applied uniformly.
- `subtype_of` returning a `SubtypeResult`.
- `describe(verbosity)` and `erase_to_rbs` for each implemented form.

When the slice lands, ADR-3 is updated to record the resolved Working Decisions. Subsequent slices add unions, intersections, refinements, container shapes, structural interfaces, generic carriers, and the rest of the catalogue.

## References

Rigor documents:

- [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md) — normative public contract for the type-object surface decided by this ADR.
- [`docs/internal-spec/implementation-expectations.md`](../internal-spec/implementation-expectations.md) — engine-surface contract that surrounds the type objects.
- [`docs/adr/1-types.md`](1-types.md) — type-model semantics, dynamic-origin algebra, trinary certainty.
- [`docs/adr/2-extension-api.md`](2-extension-api.md) — extension surface that consumes Type values; *Type System Object Model* and *Scope Object* sections.
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary certainty.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — lattice identities and `Dynamic[T]` algebra.
- [`docs/type-specification/special-types.md`](../type-specification/special-types.md) — `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`/`NilClass`, `bool`/`boolish`.
- [`docs/type-specification/rbs-compatible-types.md`](../type-specification/rbs-compatible-types.md) — RBS forms and contextual rules.
- [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md) — refinements Rigor adds beyond RBS.
- [`docs/type-specification/imported-built-in-types.md`](../type-specification/imported-built-in-types.md) — reserved built-in refinement names.
- [`docs/type-specification/type-operators.md`](../type-specification/type-operators.md) — operator forms and display contract.
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) — interfaces, shapes, capability roles.
- [`docs/type-specification/normalization.md`](../type-specification/normalization.md) — deterministic normalization rules.
- [`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md) — conservative erasure to RBS.
- [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md) — identifier taxonomy and display rules.

External references (PHPStan source code; not part of Rigor's submodules — `references/phpstan` carries `website/` only):

- [`phpstan/phpstan-src` `src/Type/Type.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Type.php).
- [`phpstan/phpstan-src` `src/Type/Constant/ConstantStringType.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/Constant/ConstantStringType.php).
- [`phpstan/phpstan-src` `src/Type/Accessory/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Accessory).
- [`phpstan/phpstan-src` `src/Type/Generic/`](https://github.com/phpstan/phpstan-src/tree/2.2.x/src/Type/Generic).
- [`phpstan/phpstan-src` `src/TrinaryLogic.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/TrinaryLogic.php).
- [`phpstan/phpstan-src` `src/Type/IsSuperTypeOfResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/IsSuperTypeOfResult.php).
- [`phpstan/phpstan-src` `src/Type/AcceptsResult.php`](https://github.com/phpstan/phpstan-src/blob/2.2.x/src/Type/AcceptsResult.php).

Reference docs included in the Rigor checkout via the `references/phpstan` submodule:

- [`references/phpstan/website/src/developing-extensions/type-system.md`](../../references/phpstan/website/src/developing-extensions/type-system.md).
- [`references/phpstan/website/src/developing-extensions/trinary-logic.md`](../../references/phpstan/website/src/developing-extensions/trinary-logic.md).
