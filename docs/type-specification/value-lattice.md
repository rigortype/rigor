# Value Lattice

This document defines the value lattice Rigor uses internally. It is the foundation on which subtyping, normalization, narrowing, and erasure all rest.

## Ordinary value lattice

The ordinary value lattice has:

- `top` as the greatest type for all Ruby values.
- `bot` as the empty type for unreachable or impossible values.
- Nominal, structural, literal, union, intersection, tuple, record, proc, and refined types between them.

Important identities:

```text
bot <: T
T <: top
T | bot = T
T & top = T
T | top = top
T & bot = bot
```

These identities are normative and feed normalization (see [normalization.md](normalization.md)).

## `Dynamic[T]` and the dynamic-origin algebra

`untyped` is deliberately outside the ordinary value lattice. Rigor represents values that crossed a dynamic boundary as `Dynamic[T]`, where `T` is the currently known static facet. Raw RBS `untyped` is `Dynamic[top]`.

`Dynamic[T]` is **not** surface RBS syntax. It MUST NOT be accepted as an ordinary user-authored type. It is an internal implementation form that combines two facts:

- the value crossed a gradual boundary or otherwise came from unchecked information;
- the current control-flow analysis can still prove the static facet `T`.

The detailed semantics of `untyped`, `Dynamic[T]`, gradual consistency, and the strict modes that build on dynamic-origin provenance live in [special-types.md](special-types.md). The relations themselves live in [relations-and-certainty.md](relations-and-certainty.md).

### Algebraic rules

Rigor does **not** fold a dynamic-origin operand into the combined type. A `Dynamic[T]` operand of a union stays a distinct union arm rather than absorbing the other operands into a single `Dynamic`:

```text
Dynamic[A] | Dynamic[B] = Dynamic[A] | Dynamic[B]   (distinct arms, NOT Dynamic[A | B])
T | Dynamic[U]          = T | Dynamic[U]            (the concrete arm T is preserved)
```

Keeping the arms distinct is more precise than absorbing them: the concrete arm `T` stays a concrete type — and, where every arm is concrete, a *protected* dispatch — while provenance stays per-arm (which arm crossed the boundary is known). A union with any dynamic-origin arm is still gradually valid at a dispatch, so the gradual-consistency guarantee is unchanged.

A guarded dynamic-origin value is narrowed by **concretizing** it, not by intersecting a marker: a trusted guard such as `x.is_a?(String)` narrows a `Dynamic[top]` receiver to `Nominal[String]` (a fully concrete, protected `String`), so the guarded call resolves against `String` method facts directly. See [control-flow-analysis.md](control-flow-analysis.md).

The founding-era dynamic-origin **join** algebra (`T | Dynamic[U] = Dynamic[T | U]`, absorbing concrete arms into `Dynamic`) and the **meet** rule (`Dynamic[T] & U = Dynamic[T & U]`, provenance-preserving narrowing) are **superseded** by this behaviour — see [ADR-83](../adr/83-dynamic-origin-algebra.md) for the measurement and rationale. Provenance-preserving narrowing is deferred to a future strict-dynamic discipline ([ADR-75](../adr/75-dynamic-provenance.md) WD4); until then narrowing concretizes.

### Generic positions

Generic positions preserve dynamic-origin slots. For example, `Array[untyped]` is internally `Array[Dynamic[top]]`, **not** `Array[top]`. Reading an element returns `Dynamic[top]`. Writing an element follows gradual consistency, and stricter modes MAY report that the collection stores unchecked values. The same rule applies to hashes, tuples, records, proc parameters and returns, and shape members.

### Round-trip preservation

The dynamic-origin wrapper is reversible at the RBS boundary. `Dynamic[top]` round-trips to `untyped`; preserved generic slots round-trip with the same shape. This is what makes the RBS→Rigor direction lossless even when `untyped` participates. See [overview.md](overview.md) for the lossless/lossy contract and [rbs-erasure.md](rbs-erasure.md) for the export side.

## Working with the lattice

- Subtyping uses the static facet on `Dynamic[T]`; gradual consistency governs unchecked crossings (see [relations-and-certainty.md](relations-and-certainty.md)).
- Normalization MUST be deterministic so diagnostics, caches, and exported signatures are stable. The full normalization rule set is in [normalization.md](normalization.md).
- Narrowing operates over the lattice through edge-aware scopes (see [control-flow-analysis.md](control-flow-analysis.md)). Negative facts are expressed using the operators in [type-operators.md](type-operators.md) and never introduce a positive domain from the excluded value alone.
