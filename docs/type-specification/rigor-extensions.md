# Rigor Extensions

Rigor MAY infer types that RBS cannot spell directly. These types MUST always have an RBS erasure (see [rbs-erasure.md](rbs-erasure.md)).

This document is the catalog of internal-only forms that the analyzer uses but that do not appear in surface RBS. Reserved built-in **names** for refinements are in [imported-built-in-types.md](imported-built-in-types.md). Operator forms (`~T`, `T - U`, `key_of[T]`, etc.) are in [type-operators.md](type-operators.md).

## Catalog

| Rigor extension | Purpose | RBS erasure |
| --- | --- | --- |
| Refined nominal type, such as `String where non_empty` | Predicate-proven subtype of a nominal type | Nominal base, such as `String` |
| Integer range, such as `Integer[1..]` | Numeric comparisons and bounds | `Integer` |
| Finite set of literals | Precise branch and enum tracking | RBS literal union when possible, otherwise nominal base |
| Truthiness refinement | Branch-sensitive nil/false elimination | Erased underlying type |
| Relational fact, such as `x == "foo"` | Captures a guard that may not be soundly reducible to a value type because Ruby equality is dispatch | Erased marker |
| Object shape | Known methods or singleton-object capabilities inferred locally | Named interface if available, otherwise `top` or nominal base |
| Inferred capability role | Minimum structural interface required by a method body, such as readable and rewindable stream behavior | Named interface when available, otherwise object-shape erasure |
| Hash shape refinements beyond RBS records | Required keys, optional keys, read-only entries, open or closed extra-key policy, and key presence after guards | RBS record when exact, otherwise `Hash[K, V]` |
| Fact stability marker | Records whether a local, member, shape entry, or hash key fact survives assignment, calls, or mutation | Erased marker |
| Dynamic-origin wrapper, such as `Dynamic[T]` | Tracks precision lost through `untyped` while preserving the current static facet | `untyped` at unchecked boundaries; marker erased only after a checked non-dynamic contract |
| Negation or complement type, such as `~"foo"` | Represents values in the current domain except a type | Erased domain type |
| Conditional type | Models type-level branching when needed for library signatures | Conservative union or bound |
| Indexed access type | Projects member, tuple, record, or shape component types | Projected RBS type when expressible, otherwise conservative base |
| Template literal-like string refinement | Tracks formatted string families | `String` |

## Authoring rules

Rigor extensions MUST NOT leak into generated RBS syntax. Erasure is the contract that keeps export compatible with ordinary RBS-aware tools.

A small subset of these forms MAY be authored explicitly by users, restricted to `RBS::Extended` annotation payloads (see [rbs-extended.md](rbs-extended.md)):

- `T - U` is the preferred explicit authoring form for difference types.
- `~T` is reserved primarily for negative facts and compact diagnostic display; authors MAY use it where the surrounding context names the domain.
- Reserved built-in refinement names (see [imported-built-in-types.md](imported-built-in-types.md)) are accepted in `RBS::Extended` payloads.

Rigor extensions that are not user-authored — refined nominal types proved by guards, hash-shape stability markers, dynamic-origin wrappers, capability-role inference results — are produced by the analyzer from the source program, accepted signatures, generated metadata, plugin contributions, and `RBS::Extended` annotations. They MUST NOT be authored directly in `*.rb` files.

## How extensions interact with the rest of the type system

- **Refined nominal types** are subtypes of their base for subtyping queries. The refinement adds a check that the base does not already prove. Diagnostics and narrowing keep the refinement until normalization, mutation, or budget exhaustion forces a widening.
- **Integer ranges** participate in subtyping by interval inclusion (within `Integer`). They erase to `Integer` because RBS cannot spell the range. See [imported-built-in-types.md](imported-built-in-types.md) for naming and the rationale for keeping ranges integer-only.
- **Finite literal unions** participate in subtyping as ordinary unions. They are bounded by the union-size budget (see [inference-budgets.md](inference-budgets.md)); when the budget is exceeded, Rigor widens to the nominal base.
- **Truthiness refinements** are flow-sensitive (`false | nil` versus the rest of the domain). They are not value types in their own right; they are scope facts that compose with other refinements. See [control-flow-analysis.md](control-flow-analysis.md).
- **Relational facts** are scope facts that capture comparisons whose value-type effect is not yet justified. They MUST NOT introduce a positive domain from the right-hand side of the comparison. They are retained for diagnostics, contradiction detection, and later promotion when stronger evidence appears.
- **Object shapes** describe known members for a value at a program point. The members themselves carry kind, signature, visibility, source/provenance, stability, and certainty. The full schema is in [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md).
- **Inferred capability roles** are summaries of what a method body actually requires from a parameter or receiver. They are anonymous shape requirements until Rigor proves a named interface is a good representation; the matching procedure is bounded and deterministic (see [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md) and [inference-budgets.md](inference-budgets.md)).
- **Hash shape refinements** add required/optional/extra-key policies and read-only markers on top of RBS records. The erasure algorithm is in [rbs-erasure.md](rbs-erasure.md).
- **Fact stability markers** record whether facts survive assignments, mutations, escapes, unknown calls, and yielded blocks. They live in scope snapshots. See [control-flow-analysis.md](control-flow-analysis.md).
- **`Dynamic[T]`** is described in [special-types.md](special-types.md); the algebra is in [value-lattice.md](value-lattice.md).
- **Negation and difference types** display under the diagnostic display contract in [type-operators.md](type-operators.md).
- **Conditional types** and **indexed access types** are the type-level computation forms Rigor MAY support for library signatures. They erase conservatively.
- **Template-literal-like string refinements** describe formatted string families. They are inferred when the analyzer can prove the family; they erase to `String`.
