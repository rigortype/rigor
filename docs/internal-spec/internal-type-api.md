# Internal Type API

This document specifies the public contract that every Rigor type object MUST satisfy: the immutability and equality discipline, the method surface, the result value objects, the wrapper-composition rules, and the routing of normalization, erasure, and diagnostic display.

This is the engine-internal counterpart of the type-language semantics in [`docs/type-specification/`](../type-specification/README.md). When a description here would conflict with type-language behavior, the type specification binds.

The decisions in this document are stable. The two open questions tracked in [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) — the constant scalar/object carrier shape and the trinary-returning method naming convention — are deliberately abstracted here so that the contract does not depend on either resolution.

## Scope

This document binds:

- The Ruby surface that engine code, plugins, CLI components, and tests use to reason about types.
- The identity, equality, hashing, and immutability rules every type instance MUST satisfy.
- The method-surface taxonomy (capability queries, refinement projections, relational queries, structural queries, combinators, meta) and the result-shape contract for each group.
- The composition rules for wrapper forms (`Dynamic[T]`, refinements, unions, intersections, differences, complements, generic position carriers).
- The routing rules from public methods into the type specification (`describe(verbosity)` to [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md), `erase_to_rbs` to [`rbs-erasure.md`](../type-specification/rbs-erasure.md), `normalize` to [`normalization.md`](../type-specification/normalization.md)).

This document does **not** bind:

- The exact set of concrete classes, since open question 1 in [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) is unresolved. The class catalogue draft in that ADR remains illustrative until a vertical-slice implementation chooses among the recorded options.
- Concrete Ruby method names where the trinary-returning naming convention (open question 2 in the same ADR) is unresolved. Where naming matters in this document, methods are written without the `?` suffix; the final convention applies uniformly.

## Identity and Immutability

- Every type instance MUST be `freeze`d at the end of construction. Mutating an instance after construction is a contract violation, even through internal accessors.
- Equality MUST be structural. `==` and `eql?` MUST agree, and both MUST return `true` for two instances that hold structurally equivalent data.
- `hash` MUST be derived from the same structural data so that `eql?`-equal instances produce identical `hash` values.
- Equality MUST NOT depend on object identity. Two type instances with equal structure MUST compare equal even when they are not the same Ruby object.
- A type instance MAY be reused as a hash key. Implementations MAY flyweight common instances when caching is observably useful, but flyweighting MUST NOT be relied on for correctness.

## Trinary Result Value

The `Rigor::Trinary` value object is the canonical three-valued result used by capability queries, relational queries, and any analyzer surface that distinguishes "proven yes", "proven no", and "cannot prove either" answers. Its semantics are normative in [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md); this section binds the public Ruby contract.

- `Rigor::Trinary` MUST expose three flyweight instances reachable through factories named `yes`, `no`, and `maybe`. The flyweights MUST satisfy `equal?` for the same value, `==` for the same value, and `eql?` for the same value.
- `Rigor::Trinary` MUST expose boolean predicates `yes?`, `no?`, `maybe?` that return `true` or `false`. These MUST be the only methods on `Trinary` that follow Ruby's `?`-returns-boolean convention.
- `Rigor::Trinary` MUST expose at least the standard combinators: `and(other)`, `or(other)`, and `negate` (the negation of `yes` is `no`, the negation of `no` is `yes`, the negation of `maybe` is `maybe`). The combinators MUST return `Rigor::Trinary` instances.
- A `Rigor::Trinary` value MUST NOT be silently coerced to a Ruby boolean. Callers that need a boolean MUST select an explicit predicate (`yes?`, `no?`, `maybe?`).
- `maybe` MUST NOT be promoted to `yes` by repeated evidence. The promotion rules in [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md) are the only sources of certainty change.

## Result Value Objects

Relational queries MUST return immutable result value objects, not bare booleans or bare `Rigor::Trinary` values, when the analyzer also has reason metadata that callers MAY consume.

- The subtype query (`subtype_of`) MUST return an object that exposes a `Rigor::Trinary` answer through a method named consistently with the trinary-naming convention chosen for the rest of the type API, plus reason metadata describing which rules fired, which dynamic-origin facts were consulted, and which budget cutoffs were hit.
- The acceptance query (`accepts`) MUST return an analogous object covering acceptance-specific metadata (mode, coercion path, dynamic-origin provenance). Slice 4 phase 2c binds this to the concrete `Rigor::Type::AcceptsResult` value object with the following shape:
  - `trinary` — the carried `Rigor::Trinary` answer.
  - `mode` — the boundary mode the answer was computed under (`:gradual` ships now; `:strict` is reserved for later slices).
  - `reasons` — a frozen `Array<String>` describing which rules fired in the order they fired.
  - Predicates `yes?`, `no?`, `maybe?` MUST delegate to the carried `Rigor::Trinary` and remain the only methods on `AcceptsResult` that follow the `?`-returns-boolean convention.
  - `with_reason(reason)` MUST return a new `AcceptsResult` with the same `trinary` and `mode` but with `reason` appended to `reasons`. It MUST NOT mutate the receiver. Passing `nil` or an empty string MUST be a no-op (same instance returned).
  - Structural equality on `(trinary, mode, reasons)` MUST hold, in line with the *Identity and Immutability* section.
  - The reasons MUST be treated as opaque by every caller except human-readable logging. Later slices MAY upgrade the entries to structured records (rule id, supporting facts, dynamic provenance) without further notice; callers that need a richer carrier MUST consume it through future named accessors rather than parsing the strings.
- Simpler queries (`consistent_with`, `equal_value`) MAY return a bare `Rigor::Trinary` when no useful reason metadata exists.
- Result objects MUST be immutable and structurally comparable on the same rules as type instances.

The result-object surface mirrors PHPStan's `IsSuperTypeOfResult` and `AcceptsResult` design recorded in [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md).

## Method Surface

Every concrete type implementation MUST expose the method surface listed below. Method names without the `?` suffix follow the abstract form used in this specification; the final concrete spelling is fixed by the resolution of open question 2 in ADR-3 and applies uniformly across every method that returns `Rigor::Trinary`.

### Capability predicates

Capability predicates ask whether a type behaves as a particular Ruby kind. They MUST return `Rigor::Trinary`. The minimum surface is:

`string`, `integer`, `float`, `symbol`, `boolean`, `nil_value`, `array`, `hash`, `tuple`, `record`, `proc`, `callable`, `iterable`, `void`, `dynamic`, `class_object`, `module_object`.

Implementations MAY add capability predicates for additional kinds when the type specification gains a corresponding distinction. Implementations MUST NOT replace a capability predicate with a behaviorally weaker check.

### Refinement projections

Refinement projections enumerate witnesses for a particular refinement family. They MUST return a Ruby `Array<Rigor::Type>`. An empty array means "no proven witnesses for this projection". A non-empty array means the analyzer can enumerate the witnesses. The minimum surface is:

`constant_strings`, `constant_integers`, `constant_floats`, `constant_symbols`, `constant_booleans`, `constant_arrays`, `arrays`, `tuples`, `records`, `hashes`, `enum_cases`, `finite_values`.

Composition rules:

- A union MUST forward each projection into its members and concatenate the results, preserving order.
- An intersection MUST forward each projection into its members and intersect the results.
- A `Dynamic[T]` wrapper MUST forward projections into the static facet `T` per [`value-lattice.md`](../type-specification/value-lattice.md). Witnesses retrieved through `Dynamic[T]` MUST themselves carry dynamic-origin provenance.
- Refinement wrappers (refined nominal, integer range, finite literal union, …) MUST forward projections through the underlying type and add their own contribution where applicable (for example, a finite literal union of strings MUST contribute its members to `constant_strings`).

### Relational queries

Relational queries MUST return result value objects (when reason metadata is meaningful) or `Rigor::Trinary` (when it is not). The minimum surface is:

- `subtype_of(other)` — returns the subtype-result object; semantics in [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md).
- `accepts(other, mode:)` — returns the acceptance-result object; the `mode:` keyword carries the boundary mode (strict, gradual, plugin-supplied).
- `consistent_with(other)` — returns `Rigor::Trinary`; semantics in [`relations-and-certainty.md`](../type-specification/relations-and-certainty.md).
- `equal_value(other)` — returns `Rigor::Trinary`; intended for value-equality narrowing rather than type-set equality.

Relational queries MUST treat the static facet of `Dynamic[T]` per [`value-lattice.md`](../type-specification/value-lattice.md). Gradual consistency, not subtyping, governs whether a dynamic value crosses a typed boundary.

### Structural queries

Structural queries expose the member-level surface needed by ADR-2's extension API. The minimum surface is:

- `has_method(name)` returning `Rigor::Trinary`.
- `method(name, scope:)` returning a method-reflection result or a sentinel for "not available".
- `members` returning the structured shape from [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md).
- `key_type`, `value_type`, `tuple_arity`, `iterable_key_type`, `iterable_value_type` returning either a `Rigor::Type` or a sentinel for "not applicable".

Member-bearing types (object shapes, capability roles, hash shapes, records) MUST consult the schema in [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) when populating these results.

### Operations and combinators

Combinators MUST live on a factory module (working name `Rigor::Type::Combinator`) and route every public construction through the deterministic normalization rules in [`normalization.md`](../type-specification/normalization.md). The minimum surface is:

- `union(*types)`, `intersect(*types)`, `difference(left, right)`, `complement_within(domain, type)`.
- `refine(base, predicate)` for attaching a refinement to an existing type. The exact shape of `predicate` depends on the refinement family being applied (see [`rigor-extensions.md`](../type-specification/rigor-extensions.md)).
- `dynamic(static_facet)` for constructing a `Dynamic[T]` wrapper. `dynamic(top)` MUST be the canonical form for `untyped`.

Type instances MUST NOT expose mutating combinators. An instance method that returns a new type with an additional refinement (working name `with_refinement`) MAY be added once open question 1 in ADR-3 is resolved.

Direct constructor calls that bypass the factory normalization route are an internal escape hatch reserved for tests and migration. Production code paths MUST go through the factory.

### Wrapper composition

Wrappers (`Dynamic[T]`, refinement carriers, `Union`, `Intersection`, `Difference`, `Complement`, generic position carriers) MUST hold inner `Rigor::Type` references rather than extend a base class. Behavior is delegated to the inner types according to:

- The dynamic-origin algebra in [`value-lattice.md`](../type-specification/value-lattice.md) for `Dynamic[T]`.
- The combinator algebra in [`type-operators.md`](../type-specification/type-operators.md) for negative and difference forms.
- The refinement composition rules in [`rigor-extensions.md`](../type-specification/rigor-extensions.md) for refinement carriers.
- The generic-slot preservation rules in [`value-lattice.md`](../type-specification/value-lattice.md) for generic position carriers.

A wrapper MUST forward capability and projection queries into its inner types, then apply its own contribution. A wrapper MUST NOT silently strip its provenance during forwarding (for example, `Dynamic[T]` MUST keep recording dynamic-origin provenance on the values it returns).

### Meta operations

Every type instance MUST expose:

- `describe(verbosity)` returning a string under the diagnostic display rules. The implementation MUST honour [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md) (including the `Dynamic[T]` family carve-out), [`type-operators.md`](../type-specification/type-operators.md) (negative-fact and operator omission rules), and [`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) and [`rbs-erasure.md`](../type-specification/rbs-erasure.md) (hash-shape and tuple display).
- `erase_to_rbs` returning the conservative RBS erasure under [`rbs-erasure.md`](../type-specification/rbs-erasure.md). Erasure MUST be at least as wide as the proven type and MUST be valid RBS syntax.
- `normalize` that is idempotent. A type that is already normalized MUST return `self`. A type built outside the factory route MUST normalize to the same instance the factory would have produced for the same input.
- `traverse(&block)` that walks inner type references for combinators and wrappers, yielding each inner type to the block in a deterministic order. Leaf types MAY implement `traverse` as a no-op.
- Structural `==`, `eql?`, and `hash` per the *Identity and Immutability* section above.

`inspect` MAY exist for development convenience. `inspect` MUST NOT be used as the diagnostic surface; `describe(verbosity)` is the binding contract for diagnostics and explanations.

## Module Layout

The Ruby module layout is fixed at the granularity needed for the contracts above. Names are placeholder and MAY be renamed during implementation.

- `Rigor::Type` MUST be a documentation-only module that names the duck-type contract. Concrete type classes MUST NOT inherit from `Rigor::Type`, and MUST NOT `include Rigor::Type` to gain behavior. Mixins MAY be used for narrow trait-like sharing (for example structural-equality helpers) but MUST NOT be used as a substitute for inheritance to express subtype relations.
- Concrete type classes live under `Rigor::Type::*`. The exact list depends on open question 1 in [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md).
- `Rigor::Trinary` is a top-level value object, distinct from the type namespace. It is shared with control-flow analysis, plugin Scope queries, and any other surface that returns three-valued certainty.
- The combinator factory (working name `Rigor::Type::Combinator`) is the entry point for normalized construction. Direct class constructors MUST NOT be used by production code paths.

`sig/rigor.rbs` MUST be kept consistent with the public surface described here once the surface stabilizes. The first vertical slice tracked in ADR-3 is the place to introduce the corresponding RBS signatures.

## Stability and Versioning

The contracts in this document are stable within a major version, in the same sense as [`implementation-expectations.md`](implementation-expectations.md). The following are additionally stable:

- The list of capability predicates, refinement projections, and meta operations.
- The result-value-object shape for `subtype_of` and `accepts`.
- The factory normalization routing.
- The wrapper composition rules.

The following are explicitly out of the stability contract until ADR-3 promotes them:

- The constant scalar/object carrier shape (open question 1 in ADR-3).
- The trinary-returning method naming convention (open question 2 in ADR-3).
- The exact catalogue of concrete classes under `Rigor::Type::*` beyond what the type specification requires.

Plugin authors and engine consumers MUST treat the listed stable contracts as binding and the listed unstable items as subject to refinement during the first vertical slice.

## Related Documents

- [`docs/internal-spec/implementation-expectations.md`](implementation-expectations.md) — engine-surface contract (Scope, fact store, effect model, capability-role inference, normalization, RBS erasure routing).
- [`docs/type-specification/relations-and-certainty.md`](../type-specification/relations-and-certainty.md) — subtyping, gradual consistency, trinary semantics.
- [`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md) — lattice identities and `Dynamic[T]` algebra.
- [`docs/type-specification/normalization.md`](../type-specification/normalization.md) — deterministic normalization rules used by the factory route.
- [`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md) — conservative RBS erasure routed through `erase_to_rbs`.
- [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md) — diagnostic identifier taxonomy and display rules routed through `describe(verbosity)`.
- [`docs/type-specification/type-operators.md`](../type-specification/type-operators.md) — operator surface and negative-fact display contract.
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) — interfaces, object shapes, capability roles, member-shape entries.
- [`docs/type-specification/rigor-extensions.md`](../type-specification/rigor-extensions.md) — refinement catalogue and composition.
- [`docs/adr/3-type-representation.md`](../adr/3-type-representation.md) — design rationale and open questions for the contracts in this document.
