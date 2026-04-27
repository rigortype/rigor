# ADR-1: Type Model and RBS Superset Strategy

## Status

Draft

## Context

Rigor is an inference-first static analyzer for Ruby. It must interoperate with the existing RBS ecosystem while supporting internal types that are more precise than RBS can express.

RBS already defines a rich type syntax, including nominal types, singleton class types, literal types, unions, intersections, optionals, records, tuples, proc types, type variables, `self`, `instance`, `class`, `bool`, `untyped`, `nil`, `top`, `bot`, and `void`.

Rigor should also learn aggressively from PHPStan, TypeScript, and Python's typing specification. Those systems demonstrate that practical static analysis benefits from literal types, finite unions, control-flow narrowing, negative facts, shape-like types, gradual typing discipline, and expressive type operators. Rigor should adapt those ideas to Ruby and RBS rather than copying their syntax uncritically.

The initial design requirement is:

- Every RBS type is a valid Rigor type.
- Rigor may infer richer types than RBS.
- Every Rigor-inferred type can be conservatively erased to valid RBS.
- Special RBS types such as `untyped`, `top`, `bot`, and `void` must be handled with type-theoretic clarity rather than as ad hoc aliases.
- Types that exceed RBS may be recorded in RBS annotations under a provisional `RBS::Extended` convention.

## Goals

- Preserve RBS compatibility for input and output.
- Keep application code free of Rigor-specific inline type syntax.
- Support precise control-flow and data-flow inference.
- Support PHPStan-, TypeScript-, and Python-style narrowing where it fits Ruby semantics.
- Make gradual typing boundaries explicit.
- Make exported RBS conservative and explainable.
- Keep room for plugin-provided type facts without baking framework behavior into the core.

## Non-Goals

- Rigor does not need to invent an incompatible signature language.
- Rigor does not need to expose every internal refinement in generated RBS.
- Rigor does not need to finalize every type operator syntax before implementing the underlying semantics.
- Rigor does not need to implement the complete final type lattice in the first MVP.

## Options Considered

### Option A: Use RBS Types Only

Rigor could represent exactly the types RBS can spell.

Benefits:

- Simple export path.
- Close alignment with existing tooling.
- Smaller initial implementation.

Drawbacks:

- Inference loses useful facts, such as literal sets, integer bounds, truthiness refinements, and dynamic-origin provenance.
- Diagnostics become less precise.
- `void` and `untyped` are likely to be treated as broad aliases too early.
- PHPStan-, TypeScript-, and Python-style refinements cannot be represented well.

### Option B: Use a RBS Superset with Conservative Erasure

Rigor can represent every RBS type and add internal-only refinements. Export converts those refinements back to conservative RBS.

Benefits:

- Keeps RBS as the interoperability format.
- Allows precise inference and diagnostics.
- Provides a principled path for gradual typing and advanced refinements.
- Supports control-flow analysis with positive and negative facts.
- Matches the project goal of inference-first analysis without application-code annotations.

Drawbacks:

- Requires a real erasure pass.
- Requires separate normalization, subtyping, and consistency logic.
- Users may need explanations when exported RBS is less precise than Rigor's internal type.
- The syntax for Rigor-only type operators must be designed carefully.

### Option C: Use RBS Plus `RBS::Extended` Annotations Only

Rigor could avoid an independent internal type model and represent every extension as RBS annotations.

Benefits:

- Keeps all explicit type metadata attached to RBS declarations, members, or overloads.
- Remains invisible to standard RBS parsers.
- Provides a migration path for advanced library signatures.

Drawbacks:

- Annotations are not enough for inferred facts produced by CFA.
- It risks turning annotations into an unstructured second language.
- It does not solve internal normalization, subtyping, or erasure.

### Option D: Create a Separate Rigor Signature Language

Rigor could define a new full signature language and optionally generate RBS.

Benefits:

- Maximum expressiveness.
- No need to fit internal concepts into RBS constraints.

Drawbacks:

- Splits the ecosystem.
- Adds learning and maintenance cost.
- Conflicts with the goal of using existing RBS types for dependencies.
- Encourages annotation workflows that Rigor is intentionally avoiding.

## Working Decision

Adopt Option B, with a constrained part of Option C: Rigor's type language is a strict superset of RBS with conservative RBS erasure, and `RBS::Extended` annotations may describe Rigor-only facts in `*.rbs` files.

RBS remains the boundary format. Rigor's internal type representation may include refinements that RBS cannot express, but those refinements must always have a valid RBS erasure.

`RBS::Extended` annotations are metadata layered on top of ordinary RBS. They are not a replacement for internal inference and should not require annotations in Ruby application code.

## Key Design Points

### Subtyping and Gradual Consistency Are Separate

Rigor should distinguish ordinary subtyping from gradual consistency.

`top` is the greatest static value type. `bot` is the empty type. `untyped` is the dynamic type and should not be collapsed into `top`, even though RBS describes it as both a subtype and supertype of all types for gradual typing purposes.

This separation lets Rigor keep track of unchecked boundaries while still allowing gradual code to type-check.

The documentation should write the gradual-consistency relation as `consistent(A, B)`, not `A ~ B`, because `~T` is reserved for negative or complement types.

### Python Typing Compared with RBS

The `references/python-typing` tree is useful reference material, but Python typing is not a compatibility target. Rigor should borrow concepts only when they preserve Ruby semantics and can erase to RBS.

| Area | Python typing | RBS and Rigor implication |
| --- | --- | --- |
| Signature boundary | Python allows inline annotations and separate stubs. | Rigor keeps Ruby application code annotation-free and uses RBS as the external signature format. |
| Dynamic and top types | `Any` is an unknown gradual type, while `object` is the greatest fully static object type. | RBS already gives Rigor `untyped` and `top`; Python's materialization and assignability model reinforces keeping them separate. |
| Structural types | `Protocol` and `TypedDict` are structural type forms with explicit typing rules. | RBS interfaces and records cover part of this space; Rigor can infer richer object and hash shapes internally, then erase them to RBS interfaces, records, `Hash[K, V]`, or `top`. |
| Hash shape detail | `TypedDict` distinguishes required, non-required, read-only, open, closed, and extra items. | Rigor should reuse this vocabulary for Ruby hash, options-hash, and keyword-argument shapes, while remembering that ordinary Ruby hashes are mutable unless a separate fact proves otherwise. |
| Class objects and self types | Python uses `type[C]`, `Self`, and constructor-specific rules. | RBS already has `singleton(C)`, `self`, `instance`, and `class`; Rigor should prefer those forms and design any future instance projection around Ruby class objects. |
| Nil-like and bottom types | `None` is an ordinary value type; `Never` and `NoReturn` are bottom aliases. | RBS distinguishes `nil`, `NilClass`, `bot`, and `void`; Rigor should not import Python aliases, and `void` remains a RBS-specific no-use return marker. |
| Type predicates | Python has `TypeGuard` for positive-only narrowing and `TypeIs` for positive and negative narrowing. | RBS has no predicate return type form; Rigor should model these as flow effects in `RBS::Extended` annotations. |
| Metadata | `Annotated[T, ...]` is treated as `T` by tools that do not understand the metadata. | RBS `%a{...}` annotations give Rigor the same compatibility pattern for `RBS::Extended` metadata. |
| Callable precision | Python specifies overload matching, positional and keyword parameter kinds, `ParamSpec`, `TypeVarTuple`, and `Unpack[TypedDict]`. | RBS already has method and proc signatures, overloads, optional and keyword parameters, and block types. Rigor should borrow checking principles and keyword-shape ideas, not Python syntax. |
| Mutability and finality | Python has `Final`, `ClassVar`, `ReadOnly`, and `@final` qualifiers. | Rigor should model these, if needed, as symbol, member, or shape-write facts rather than ordinary value types. |

### Control-Flow Narrowing Is Central

Rigor should run appropriate CFA and data-flow analysis, similar in spirit to PHPStan, TypeScript, and Python type checkers.

For example, after `value == "foo"`, the true branch can narrow `value` to `"foo"` and the false branch can carry the negative fact displayed as `~"foo"`. The exact operator syntax is provisional, but the semantic capability is required.

Python's `TypeGuard` and `TypeIs` distinction supports the same design direction: predicate behavior is a flow effect. A true-only predicate is enough for `TypeGuard`-like behavior; paired true and false facts, or a false fact expressed as `T & ~U`, provide `TypeIs`-like behavior.

### `void` Is a Return-Position Marker

RBS treats `void` as top-like but context-limited. Rigor should model `void` internally as a result marker that says the return value should not be used.

This enables diagnostics such as assigning the result of a `void` method call. In statement context, `void` is fine. In value context, Rigor reports a diagnostic and recovers with `top`.

### RBS Context Rules Are Preserved

`self`, `instance`, `class`, and `void` have context restrictions in RBS. Rigor may carry richer contextual information internally, but exported RBS must obey those restrictions.

### Refinements Are Internal

Rigor can infer refined types such as non-empty strings, positive integers, literal sets, truthiness-narrowed types, and hash/object shapes. These refinements improve diagnostics and flow analysis, but they erase to ordinary RBS.

### Imported Built-Ins Follow Ruby Semantics

Rigor should import PHPStan, TypeScript, and Python typing ideas by semantic value, not by syntax compatibility.

Reserved built-in refinement names use `kebab-case` spellings when they are recognizable and map cleanly to Ruby, such as `non-empty-string`, `positive-int`, `lowercase-string`, `literal-string`, `numeric-string`, `decimal-int-string`, and `non-empty-array[T]`. The hyphen is intentional because it cannot appear in Ruby constants or RBS alias names, so these names are visibly Rigor-reserved.

Parameterized type functions should use one canonical lower_snake Rigor spelling with square brackets. For example, `key_of[T]` is preferred over accepting both PHPStan-style `key-of<T>` and TypeScript-style `keyof T`. Type functions compute, project, or transform another type or literal set; they avoid hyphens because `-` is also the difference operator in Rigor's type syntax. Additional spellings should require a concrete migration or readability benefit.

RBS names remain canonical when they already exist. `bot` is the bottom type; PHPStan aliases such as `never`, `noreturn`, `never-return`, `never-returns`, and `no-return`, and Python aliases such as `Never` and `NoReturn`, should not be added as initial aliases.

Class-name string types are deferred. Ruby can pass class and module objects directly, and RBS already has `singleton(C)`. A PHPStan `new`-like type operation or Python `type[C]`-like projection remains a future candidate, but it should be designed around Ruby class objects and factory APIs rather than class-name strings.

### Type Operators Are Provisional

Rigor should support the semantics of complement, difference, indexed access, shape projection, and possibly conditional types. The final syntax is undecided.

The candidate `~T` operator means the complement of `T` within the current known domain, not necessarily every Ruby object except `T`.

The working notation policy is:

- Use `~T` as the concise display form for CFA-produced negative facts.
- Use `T - U` as the preferred explicit authoring form for difference types in `RBS::Extended` annotations.
- Allow the implementation to normalize `T - U` to `T & ~U`.

### `RBS::Extended` Is an Annotation-Based Metadata Layer

Advanced types may be attached to ordinary RBS declarations, members, and overloads using RBS `%a{...}` annotations. This preserves compatibility with standard RBS tooling while giving Rigor a place to read refinements such as `String - ""`, `~"foo"`, or `String where non_empty`.

The canonical form should use a `rigor:` annotation key followed by a payload, for example:

```rbs
%a{rigor:predicate-if-true value is String}
def string?: (untyped value) -> bool
```

Predicate targets should initially be limited to RBS parameter names and `self`. RBS parameter names use the `_var-name_ ::= /[a-z]\w*/` grammar, so Rigor does not need to encode arbitrary Ruby Symbol names in directive identifiers. Hyphenated directive names such as `predicate-if-true` are safe because they are parsed from the annotation payload by Rigor.

If `RBS::Extended` metadata conflicts with the ordinary RBS signature, Rigor should report a diagnostic.

Type guard and assertion effects should be modeled as flow effects, not as ordinary return types. This keeps signatures RBS-compatible while still allowing TypeScript-style narrowing, PHPStan-style assertion behavior, and Python `TypeGuard`/`TypeIs`-style predicates.

### Erasure Must Be Conservative

If `T` is a Rigor type and `erase(T)` is the generated RBS type, every value accepted by `T` must be accepted by `erase(T)`.

Erasure can lose precision. It must not become narrower than the internal type.

## Rejected and Deferred Candidate Decisions

This ADR keeps explicit notes for candidate ideas that were discussed but not accepted as the current direction.

| Candidate | Status | Reason |
| --- | --- | --- |
| Treating `untyped` as another name for `top` | Rejected | `untyped` marks a gradual boundary and loss of precision; `top` is the greatest static value type. Collapsing them would lose diagnostics and provenance. |
| Writing gradual consistency as `A ~ B` | Rejected | The `~T` form is reserved for negative or complement types, so gradual consistency is written as `consistent(A, B)`. |
| Free-form `# @rigor ...` comments in `*.rbs` | Rejected | RBS `%a{...}` annotations are parsed into the RBS AST and attach to declarations, members, and overloads. Free-form comments would require a parallel attachment model. |
| Encoding type predicates as ordinary return types | Rejected | Predicate and assertion behavior changes the flow environment, not the runtime return value. Rigor records those effects through `RBS::Extended` annotations. |
| Arbitrary predicate target syntax in the first version | Rejected for now | Initial targets are limited to RBS parameter names and `self`; shape paths, instance variables, and block parameters can be added later with explicit path syntax. |
| Importing `class-string`, `interface-string`, `trait-string`, or `enum-string` | Deferred | Ruby can pass class and module objects directly, and RBS already has `singleton(C)`. String-based class names are less central than they are in PHP. |
| Importing PHPStan's `new` operation as a class-name-string operation | Deferred | A `new`-like projection may be useful for factory APIs, but it should be designed around Ruby class objects rather than class-name strings. |
| Adding `never`, `noreturn`, `never-return`, `never-returns`, and `no-return` as aliases for `bot` | Rejected for now | RBS already provides `bot`; adding aliases would increase notation without improving expressiveness. |
| Adding Python `Never` and `NoReturn` as aliases for `bot` | Rejected for now | They map conceptually to `bot`, but Rigor should keep RBS spelling canonical at the boundary. |
| Importing Python `Any` and `object` spellings | Rejected | RBS already provides `untyped` for the dynamic type and `top` for the greatest static type. |
| Importing Python `Protocol`, `TypedDict`, `Annotated`, `TypeGuard`, `TypeIs`, `Final`, or `ClassVar` syntax directly | Rejected | Their useful ideas map to RBS interfaces, records, `%a{...}` annotations, flow effects, and separate symbol or member facts. |
| Accepting both `key-of<T>` and `keyof T` | Rejected for now | Rigor should use one canonical type-function spelling, currently `key_of[T]`, unless compatibility aliases show concrete value. |
| Importing PHPStan-style integer ranges such as `int<1, 10>` | Rejected for now | Rigor should use its own range notation, such as `Integer[1..10]`, to stay closer to Ruby and RBS naming. |
| Adding lower_snake aliases for built-in refinement names, such as `non_empty_string` | Rejected for now | Hyphenated refinement names are intentionally reserved for Rigor built-ins. Lower_snake names should remain available for ordinary RBS type aliases. |
| Adding `lower-string` as an alias | Rejected for now | `lowercase-string` is the established spelling and is clearer. |
| Adding `non-falsy-string` or `truthy-string` | Rejected | Every Ruby `String` value is truthy, so these types do not add precision. |
| Importing PHP truthiness types such as `empty`, `empty-scalar`, `non-empty-scalar`, and `non-empty-mixed` | Rejected | They are tied to PHP's truthiness model. Rigor models Ruby truthiness through `false | nil` flow facts and explicit string/collection refinements. |
| Importing `list<T>` and `non-empty-list<T>` as separate surface types | Rejected for now | Ruby `Array[T]` already has list-like indexing semantics; `non-empty-array[T]` provides the useful additional refinement. |
| Adding `non-decimal-int-string` as a named built-in | Rejected for now | It can be expressed as `String - decimal-int-string` without adding another built-in name. |
| Adding `Exclude`, `Extract`, and `NonNullable` as surface aliases | Rejected for now | Rigor can express them directly as `T - U`, `T & U`, and `T - nil`. |
| Using TypeScript syntax `T extends U ? X : Y` as the canonical conditional type syntax | Rejected for now | Rigor should avoid copying TypeScript syntax unless it fits the rest of the type language. The current candidate is `if T <: U then X else Y`. |

## Consequences

Positive:

- Rigor can produce precise diagnostics while remaining compatible with RBS.
- Generated RBS can be consumed by existing RBS-aware tools.
- `untyped`, `top`, `bot`, and `void` retain distinct meanings internally.
- PHPStan-, TypeScript-, and Python-style flow analysis becomes part of the core design.
- Advanced library facts can be added in `.rbs` annotations without modifying Ruby application code.
- Future plugins can contribute precise facts without requiring new user-facing syntax.

Negative:

- The type engine needs more than a direct wrapper around RBS ASTs.
- RBS export requires loss-of-precision handling.
- Documentation must clearly explain why Rigor may infer more than it can export.
- `RBS::Extended` needs a careful annotation payload grammar and conflict rules.
- Negative and complement types require domain-aware normalization.

## Open Questions

- Which Rigor-only refinements should be implemented first after the MVP union/no-method diagnostic?
- How much of the `~T` and `T - U` notation should be accepted in user-authored `RBS::Extended` annotations in the first implementation?
- Which imported built-in refinements should be accepted in the first parser milestone beyond `non-empty-string` and integer ranges?
- How quickly should predicate targets grow beyond `parameter-name` and `self`?
- How should Rigor display dynamic-origin narrowed types such as `untyped & ~"foo"`?
- How aggressively should literal unions widen for performance and diagnostic readability?
- Which Python `TypedDict`-inspired shape facts, such as read-only keys and open or closed extra-key policies, should ship first?
- Should Rigor model finality and read-only member facts separately from value types in the first signature metadata grammar?
- Should generated RBS preserve `RBS::Extended` annotations that explain erased refinements when users request an annotated export?
- Should `untyped` operations produce optional informational diagnostics in strict mode?
- What plugin API is needed for framework-specific object shapes and dynamic method resolution?

## Resulting Specification

The current draft specification is maintained in `docs/types.md`.
