# Normalization

Rigor normalizes types before comparison and reporting. Normalization MUST be deterministic so diagnostics, caches, and exported signatures are stable.

This document is the authoritative list of normalization rules. The lattice that backs them is in [value-lattice.md](value-lattice.md). Operators referenced here (`~T`, `T - U`, `T?`) are defined in [type-operators.md](type-operators.md). The `Dynamic[T]` algebra is in [special-types.md](special-types.md).

## Rules

- Flatten nested unions and intersections.
- Remove duplicate union and intersection operands.
- Drop a union member that another member absorbs; § "Member absorption" is the complete list.
- Drop `bot` from unions (`T | bot = T`).
- Drop `top` from intersections (`T & top = T`).
- Expand `T?` to `T | nil` internally.
- Normalize finite set difference and complement when the domain is known.
- Preserve negative facts as scope facts over a positive domain; do not introduce a positive domain from the excluded value alone.
- Budget retained negative facts for large domains and widen display when the budget is exceeded (see [inference-budgets.md](inference-budgets.md)).
- Preserve hash-shape openness and read-only markers until RBS erasure (see [rbs-erasure.md](rbs-erasure.md)).
- Collapse `true | false` to `bool` for **display** when that is clearer.
- Preserve literal precision until it becomes too large or expensive; then widen to the nominal base.
- Do not subsumption-collapse a value-pinned union member into a co-member nominal base: `1 | Integer` stays `1 | Integer`. The value-pinned member records a reachable exact value with distinct provenance — typically a zero-iteration seed or a recursion base case (`result = 1` ahead of a `0..N`-iteration accumulator body; the `n <= 1` arm of a recursive return summary) — and collapsing would erase that evidence from display and from value-aware consumers, while buying nothing (the union is already extensionally equal to the base). Widening such members is the job of the explicit cap/budget widening rules, not of union construction.
- Preserve dynamic-origin wrappers explicitly rather than normalizing `untyped` to `top`.
- Do **not** fold a dynamic-origin operand into a combined type: a `Dynamic[T]` operand of a union stays a distinct union arm (`T | Dynamic[U]` normalizes to `T | Dynamic[U]`, not `Dynamic[T | U]`). The founding-era static-facet transform is superseded — see [value-lattice.md](value-lattice.md) § "Algebraic rules" and [ADR-83](../adr/83-dynamic-origin-algebra.md).

## Member absorption

A union drops any member that another member already contains, so the join after a guard names one set instead of several readings of it. Absorption never changes which values the union admits — only how many arms the display and every consumer that walks members have to carry. The relation is deliberately narrow: the list below is complete, and a pair outside it keeps both members even where one is extensionally a subset of the other (`1 | Integer`, `Integer | Integer[0..5]`, `String | lowercase-string` all stay as written).

- `bot` is absorbed by every member, and `top` absorbs every member.
- A member is absorbed by a union member that already lists it — flatten-and-dedupe read one level down.
- A `FloatRange` is absorbed by a bare `Float` member and by a `FloatRange` that contains it. The rule and its Integer exclusion are in [imported-built-in-types.md](imported-built-in-types.md) (`Float` comparison narrowing widens only the truthy edge, so the falsy edge keeps `Float` and the join would otherwise carry both readings; both `Integer` edges narrow, so `IntegerRange` keeps both members).
- A structural carrier is absorbed **element-wise over an identical spine**, asking this same list one level down. Two `Tuple` members of **equal arity** absorb when every element of one is equal to, or absorbed by, the element at that position in the other. Two `HashShape` members absorb when their spine — key set, extra-key policy, and required / optional / read-only classification — is identical and every value type is equal to, or absorbed by, the value at that key.

Differing arity and differing spine are never absorbed: `[A]` and `[A, B]`, or two hash shapes that disagree on a key or on openness, describe differently-shaped values, so neither is a reading of the other.

The element-wise clause grants no absorption of its own. It asks this list again one level down, so it fires for exactly the elements a direct union member would collapse for, at any nesting depth. `[Float, String] | [Float[0.0..], String]` collapses to `[Float, String]`, and so does `[[Float, String], Integer] | [[Float[0.0..], String], Integer]`. `[1, String] | [Integer, String]` keeps both arms, because a value-pinned member is not absorbed by its nominal base and the element-wise clause cannot outrun the direct rule; `[Integer, String] | [Integer[0..5], String]` and `[String, Integer] | [lowercase-string, Integer]` keep both arms for the same reason, as do a `Tuple` and a `Nominal[Array]` member, which are different carriers rather than two readings of one spine.

A member is removed only when some **other** member absorbs it, so two members neither of which absorbs the other both survive: the join of two disjointly guarded arms stays `[Float[...0.0], String] | [Float[0.0..], String]`. The relation MUST be a strict partial order over distinct members, so no pair can absorb each other and vanish together.

## Special-result identities

`void | bot` collapses to `void` in result summaries because the `bot` path contributes no normal value. See [special-types.md](special-types.md) for the full `void`-versus-`bot` rule.

## Determinism

Normalization MUST be deterministic. Equivalent inputs MUST produce identical outputs across runs and across analyzer instances, modulo configured budgets and authoritative signature changes. This determinism is what makes diagnostics, caches, and exported signatures comparable across edits and CI runs.

## Interaction with display

Normalization is the engine-internal canonicalization. The diagnostic display contract for difference, complement, and dynamic-origin types lives in [type-operators.md](type-operators.md) and [diagnostic-policy.md](diagnostic-policy.md). Display rules MAY render a normalized type more readably (for example showing `bool` instead of `true | false`), but they MUST NOT change the underlying type identity.
