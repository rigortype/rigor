# ADR-1: Type Model and RBS Superset Strategy

## Status

Draft

## Context

Rigor is an inference-first static analyzer for Ruby. It must interoperate with the existing RBS ecosystem while supporting internal types that are more precise than RBS can express.

RBS already defines a rich type syntax, including nominal types, singleton class types, literal types, unions, intersections, optionals, records, tuples, proc types, type variables, `self`, `instance`, `class`, `bool`, `untyped`, `nil`, `top`, `bot`, and `void`.

Rigor should also learn aggressively from PHPStan and TypeScript. Those systems demonstrate that practical static analysis benefits from literal types, finite unions, control-flow narrowing, negative facts, shape-like types, and expressive type operators. Rigor should adapt those ideas to Ruby and RBS rather than copying their syntax uncritically.

The initial design requirement is:

- Every RBS type is a valid Rigor type.
- Rigor may infer richer types than RBS.
- Every Rigor-inferred type can be conservatively erased to valid RBS.
- Special RBS types such as `untyped`, `top`, `bot`, and `void` must be handled with type-theoretic clarity rather than as ad hoc aliases.
- Types that exceed RBS may be recorded in `*.rbs` comments under a provisional `RBS::Extended` convention.

## Goals

- Preserve RBS compatibility for input and output.
- Keep application code free of Rigor-specific inline type syntax.
- Support precise control-flow and data-flow inference.
- Support PHPStan- and TypeScript-style narrowing where it fits Ruby semantics.
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
- PHPStan- and TypeScript-style refinements cannot be represented well.

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

### Option C: Use RBS Plus `RBS::Extended` Comments Only

Rigor could avoid an independent internal type model and represent every extension as comments in RBS files.

Benefits:

- Keeps all explicit type metadata near RBS.
- Remains invisible to standard RBS parsers.
- Provides a migration path for advanced library signatures.

Drawbacks:

- Comments are not enough for inferred facts produced by CFA.
- It risks turning comments into an unstructured second language.
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

Adopt Option B, with a constrained part of Option C: Rigor's type language is a strict superset of RBS with conservative RBS erasure, and `RBS::Extended` comments may describe Rigor-only facts in `*.rbs` files.

RBS remains the boundary format. Rigor's internal type representation may include refinements that RBS cannot express, but those refinements must always have a valid RBS erasure.

`RBS::Extended` comments are metadata layered on top of ordinary RBS. They are not a replacement for internal inference and should not require annotations in Ruby application code.

## Key Design Points

### Subtyping and Gradual Consistency Are Separate

Rigor should distinguish ordinary subtyping from gradual consistency.

`top` is the greatest static value type. `bot` is the empty type. `untyped` is the dynamic type and should not be collapsed into `top`, even though RBS describes it as both a subtype and supertype of all types for gradual typing purposes.

This separation lets Rigor keep track of unchecked boundaries while still allowing gradual code to type-check.

The documentation should write the gradual-consistency relation as `consistent(A, B)`, not `A ~ B`, because `~T` is reserved for negative or complement types.

### Control-Flow Narrowing Is Central

Rigor should run appropriate CFA and data-flow analysis, similar in spirit to PHPStan and TypeScript.

For example, after `value == "foo"`, the true branch can narrow `value` to `"foo"` and the false branch can carry the negative fact displayed as `~"foo"`. The exact operator syntax is provisional, but the semantic capability is required.

### `void` Is a Return-Position Marker

RBS treats `void` as top-like but context-limited. Rigor should model `void` internally as a result marker that says the return value should not be used.

This enables diagnostics such as assigning the result of a `void` method call. In statement context, `void` is fine. In value context, Rigor reports a diagnostic and recovers with `top`.

### RBS Context Rules Are Preserved

`self`, `instance`, `class`, and `void` have context restrictions in RBS. Rigor may carry richer contextual information internally, but exported RBS must obey those restrictions.

### Refinements Are Internal

Rigor can infer refined types such as non-empty strings, positive integers, literal sets, truthiness-narrowed types, and hash/object shapes. These refinements improve diagnostics and flow analysis, but they erase to ordinary RBS.

### Type Operators Are Provisional

Rigor should support the semantics of complement, difference, indexed access, shape projection, and possibly conditional types. The final syntax is undecided.

The candidate `~T` operator means the complement of `T` within the current known domain, not necessarily every Ruby object except `T`.

The working notation policy is:

- Use `~T` as the concise display form for CFA-produced negative facts.
- Use `T - U` as the preferred explicit authoring form for difference types in `RBS::Extended` comments.
- Allow the implementation to normalize `T - U` to `T & ~U`.

### `RBS::Extended` Is a Comment-Based Metadata Layer

Advanced types may be attached to ordinary RBS declarations using comments in `*.rbs` files. This preserves compatibility with standard RBS tooling while giving Rigor a place to read refinements such as `String - ""`, `~"foo"`, or `String where non_empty`.

If `RBS::Extended` metadata conflicts with the ordinary RBS signature, Rigor should report a diagnostic.

### Erasure Must Be Conservative

If `T` is a Rigor type and `erase(T)` is the generated RBS type, every value accepted by `T` must be accepted by `erase(T)`.

Erasure can lose precision. It must not become narrower than the internal type.

## Consequences

Positive:

- Rigor can produce precise diagnostics while remaining compatible with RBS.
- Generated RBS can be consumed by existing RBS-aware tools.
- `untyped`, `top`, `bot`, and `void` retain distinct meanings internally.
- PHPStan- and TypeScript-style flow analysis becomes part of the core design.
- Advanced library facts can be added in `.rbs` comments without modifying Ruby application code.
- Future plugins can contribute precise facts without requiring new user-facing syntax.

Negative:

- The type engine needs more than a direct wrapper around RBS ASTs.
- RBS export requires loss-of-precision handling.
- Documentation must clearly explain why Rigor may infer more than it can export.
- `RBS::Extended` needs a careful grammar and conflict rules.
- Negative and complement types require domain-aware normalization.

## Open Questions

- Which Rigor-only refinements should be implemented first after the MVP union/no-method diagnostic?
- How much of the `~T` and `T - U` notation should be accepted in user-authored `RBS::Extended` comments in the first implementation?
- How should Rigor display dynamic-origin narrowed types such as `untyped & ~"foo"`?
- How aggressively should literal unions widen for performance and diagnostic readability?
- Should generated RBS include comments that explain erased refinements?
- Should `untyped` operations produce optional informational diagnostics in strict mode?
- What plugin API is needed for framework-specific object shapes and dynamic method resolution?

## Resulting Specification

The current draft specification is maintained in `docs/types.md`.
