# ADR-3: Internal Type Representation

## Status

Draft.

ADR-3 records the design space for Rigor's internal type-object layout: the Ruby classes, modules, methods, and value objects that implement the type model. ADR-3 does **not** redefine semantics — those are owned by ADR-1 and the type specification — and it does **not** define the plugin contract — that is owned by ADR-2. ADR-3 fixes the analyzer-side data shapes that ADR-1 and ADR-2 attach to.

When this document and the type specification disagree on observable behavior, [`docs/type-specification/`](../type-specification/) is binding and ADR-3 must be updated to match. ADR-3 is authoritative only for *which Ruby objects exist, what methods they expose, and how they compose*.

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

The rest of this ADR fixes the parts of the design that follow from the type specification and the PHPStan reference, then records the remaining open questions.

## Working Principles

These principles are **decided** for the first implementation slice. They are not part of an Options Considered list because the type specification, ADR-1, or ADR-2 already constrain them.

1. **No inheritance between type classes.** Rigor type implementations do not extend each other. There is no `class Constant < String` analogue. Common surface is documented as a Ruby duck-type contract; concrete classes implement that contract independently. Module mixins MAY be used for narrow, mechanical sharing such as structural equality, hashing, freezing, or identity caches, but MUST NOT be used as a substitute for inheritance to express subtype relations.
2. **Type instances are immutable value objects.** Every type instance MUST be `freeze`d at construction. Equality MUST be structural (`==` and `eql?` agree) and `hash` MUST be derived from the same structural data so types can serve as hash keys. Mutation is an analyzer effect, not a property of the type representation.
3. **Capability queries return `Rigor::Trinary`.** Methods that ask "does this type behave like a string / integer / array / etc." return a `yes`/`no`/`maybe` value, not a Ruby boolean. The trinary class itself is a flyweight value object with `yes?`, `no?`, `maybe?` predicates and the usual Boolean-like combinators (`and`, `or`, `negate`). The semantics are fixed by [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md): `maybe` is a real third value and never narrows or implies a complementary edge.
4. **Refinement projections return `Array<Type>`.** Methods that enumerate witnesses (constant strings, constant arrays, finite values, enum cases, …) return Ruby arrays. An empty array means "no proven witnesses for this projection"; a non-empty array means the analyzer can enumerate them. Unions and intersections compose by combining witness lists per the PHPStan pattern. This avoids inheritance-based dispatch (`is_a?(ConstantStringType)`) and matches the monadic style requested by the ADR.
5. **Compound forms are wrappers.** `Dynamic[T]`, refinements, unions, intersections, differences, complements, and generic position carriers hold inner `Type` references rather than extending a base type. The dynamic-origin algebra in [`value-lattice.md`](../type-specification/value-lattice.md) requires this: `Dynamic[A] | Dynamic[B] = Dynamic[A | B]` is implementable as a join over wrappers, not as a class-hierarchy operation.
6. **Relational queries return result value objects.** `subtype_of` and `accepts` return a small immutable result object that bundles a `Trinary` answer with reason metadata (the rules invoked, the dynamic-origin facts consulted, the budget cutoffs hit). This corresponds to PHPStan's `IsSuperTypeOfResult` and `AcceptsResult`. Simpler queries such as `consistent_with` or `equal_value?` MAY return a plain `Trinary` when there is no useful reason payload.
7. **Combinators are factories, not instance methods.** `Type.union(*types)`, `Type.intersect(*types)`, `Type.difference(a, b)`, `Type.complement_within(domain, t)` live on a separate factory module so that instances stay closed for value-semantics reasons. Refinement attachment (`refine(predicate)`) MAY be either a factory call or an instance method that returns a new value; the choice is part of open question 1's vertical slice.
8. **Normalization is the responsibility of factories.** Factories MUST route construction through the deterministic normalization rules in [`normalization.md`](../type-specification/normalization.md) so that two structurally-equivalent inputs produce identical (`==` and `equal?`-comparable when flyweighted) outputs. Direct constructor calls bypassing normalization are an internal escape hatch for tests and migration only.

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

## Method Surface Sketch

The first-cut public method surface every concrete `Rigor::Type` MUST satisfy is grouped below. Names use the naming convention from open question 2 and are written here without the `?` for readability; the final form follows whichever option resolves that question.

- **Capability predicates (return `Rigor::Trinary`):** `string`, `integer`, `float`, `symbol`, `boolean`, `nil_value`, `array`, `hash`, `tuple`, `record`, `proc`, `callable`, `iterable`, `void`, `dynamic`, `class_object`, `module_object`. These mirror the trinary-returning capability methods on PHPStan's `Type`.
- **Refinement projections (return `Array<Rigor::Type>`):** `constant_strings`, `constant_integers`, `constant_floats`, `constant_symbols`, `constant_booleans`, `constant_arrays`, `arrays`, `tuples`, `records`, `hashes`, `enum_cases`, `finite_values`. Empty array means "no proven witnesses". Unions, intersections, and `Dynamic` wrappers MUST forward into their inner types and combine results consistently with [`value-lattice.md`](../type-specification/value-lattice.md).
- **Relational queries (return result objects):** `subtype_of(other)` and `accepts(other, mode:)` return a result value bundling a `Trinary` and a reason payload. `consistent_with(other)` and `equal_value(other)` return a plain `Trinary` when there is no useful reason payload to expose.
- **Structural queries:** `has_method(name)` (returns `Trinary`), `method(name, scope:)` (returns a method-reflection result or a sentinel), `members` (returns the structured shape from [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)), `key_type`, `value_type`, `tuple_arity`, `iterable_key_type`, `iterable_value_type`. Where PHPStan returns specific reflection objects, Rigor returns the analyzer's reflection objects (defined separately, in line with ADR-2).
- **Operations (combinators on the factory module):** `Rigor::Type.union(*)`, `Rigor::Type.intersect(*)`, `Rigor::Type.difference(a, b)`, `Rigor::Type.complement_within(domain, t)`, `Rigor::Type.refine(base, predicate)`. Instances do not expose mutating combinators; an instance method such as `with_refinement` MAY be added once the refinement model from open question 1 is settled.
- **Meta:** `describe(verbosity)` returns the diagnostic representation under [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md) and [`type-operators.md`](../type-specification/type-operators.md); `erase_to_rbs` returns the conservative RBS erasure under [`rbs-erasure.md`](../type-specification/rbs-erasure.md); `normalize` is idempotent and returns `self` when already normalized; `traverse(&block)` walks inner types for combinators and wrappers; `==`, `eql?`, and `hash` are structural and consistent.

This list is intentionally narrower than PHPStan's `Type` interface. Operations that are PHP-language-specific (the array-mutation helpers, PHP coercion casts, `looseCompare`, `isSmallerThan`) are deferred until a corresponding Ruby need surfaces. The intent is to start with a small surface that matches the type specification, then grow with concrete user stories.

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

Every entry MUST satisfy the *Method Surface Sketch* above. Wrappers (`Dynamic`, refinements, combinators, generic carriers) MUST forward queries into their inner types according to the algebraic rules in [`value-lattice.md`](../type-specification/value-lattice.md).

## Module Layout

Proposed Ruby layout, subject to refinement during implementation:

- `Rigor::Type` is a documentation-only module that names the duck-type contract. It is **not** a base class; concrete types do not `include Rigor::Type` to gain behavior.
- Concrete type classes live under `Rigor::Type::*` in `lib/rigor/type/*.rb`. One file per type form.
- `Rigor::Trinary` is a top-level value object in `lib/rigor/trinary.rb` because it is shared with non-type code (CFA results, plugin Scope queries) and does not belong inside the type namespace.
- Combinators and constructors live on a factory module (working name `Rigor::Type::Combinator`) in `lib/rigor/type/combinator.rb`, which routes through the normalization rules.
- Result objects (`Rigor::Type::SubtypeResult`, `Rigor::Type::AcceptsResult`) live alongside the relational methods that produce them.
- `sig/rigor.rbs` will describe these once the surface stabilizes; ADR-3 itself does not block on the RBS work.

## Identity, Equality, Hashing, Normalization

- Every type instance MUST be `freeze`d at construction.
- `==`, `eql?`, and `hash` MUST be derived from the same structural data so two structurally-equivalent types compare equal and produce the same hash. Equality MUST NOT depend on instance identity.
- Construction routes through the factory module, which applies the deterministic normalization rules in [`normalization.md`](../type-specification/normalization.md). Two equivalent inputs produce the same normalized output. Direct constructor calls that bypass normalization are an internal escape hatch.
- Flyweighting is permitted where it is observably an optimization. `Rigor::Trinary` instances MUST be a flyweight (three singletons). Other types MAY be cached when caching is safe and demonstrably useful; caching is never required for correctness.

## Diagnostics and Display Contract

`describe(verbosity)` is the single entry point for diagnostic rendering. It MUST follow:

- The `Dynamic[T]` display rules in [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md), including the `dynamic.*` family carve-out.
- The negative-fact and operator display contract in [`type-operators.md`](../type-specification/type-operators.md), including the omission rules that keep negative-fact diagnostics readable.
- The hash-shape and tuple display rules in [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) and [`rbs-erasure.md`](../type-specification/rbs-erasure.md).

Type instances MUST NOT format themselves with ad hoc `inspect`-style strings; `describe(verbosity)` is the binding output for diagnostics and explanations, and `inspect` is for development convenience only.

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
