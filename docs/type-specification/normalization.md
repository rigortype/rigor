# Normalization

Rigor normalizes types before comparison and reporting. Normalization MUST be deterministic so diagnostics, caches, and exported signatures are stable.

This document is the authoritative list of normalization rules. The lattice that backs them is in [value-lattice.md](value-lattice.md). Operators referenced here (`~T`, `T - U`, `T?`) are defined in [type-operators.md](type-operators.md). The `Dynamic[T]` algebra is in [special-types.md](special-types.md).

## Rules

- Flatten nested unions and intersections.
- Remove duplicate union and intersection operands.
- Drop `bot` from unions (`T | bot = T`).
- Drop `top` from intersections (`T & top = T`).
- Expand `T?` to `T | nil` internally.
- Normalize finite set difference and complement when the domain is known.
- Preserve negative facts as scope facts over a positive domain; do not introduce a positive domain from the excluded value alone.
- Budget retained negative facts for large domains and widen display when the budget is exceeded (see [inference-budgets.md](inference-budgets.md)).
- Preserve hash-shape openness and read-only markers until RBS erasure (see [rbs-erasure.md](rbs-erasure.md)).
- Collapse `true | false` to `bool` for **display** when that is clearer.
- Preserve literal precision until it becomes too large or expensive; then widen to the nominal base.
- Preserve dynamic-origin wrappers explicitly rather than normalizing `untyped` to `top`.
- Normalize dynamic-origin unions, intersections, and differences by transforming the static facet and keeping the wrapper.

## Special-result identities

`void | bot` collapses to `void` in result summaries because the `bot` path contributes no normal value. See [special-types.md](special-types.md) for the full `void`-versus-`bot` rule.

## Determinism

Normalization MUST be deterministic. Equivalent inputs MUST produce identical outputs across runs and across analyzer instances, modulo configured budgets and authoritative signature changes. This determinism is what makes diagnostics, caches, and exported signatures comparable across edits and CI runs.

## Interaction with display

Normalization is the engine-internal canonicalization. The diagnostic display contract for difference, complement, and dynamic-origin types lives in [type-operators.md](type-operators.md) and [diagnostic-policy.md](diagnostic-policy.md). Display rules MAY render a normalized type more readably (for example showing `bool` instead of `true | false`), but they MUST NOT change the underlying type identity.
