# ADR-83 — Dynamic-origin algebra: keep union arms over absorbing into `Dynamic`

Status: **Accepted, 2026-07-11.** The founding-era dynamic-origin **join** algebra in
[`value-lattice.md`](../type-specification/value-lattice.md) (`T | Dynamic[U] = Dynamic[T | U]`) is
**superseded** — the engine deliberately does not implement it, and a spike confirmed implementing it has
zero user-visible value and points the wrong way (it absorbs concrete union arms into `Dynamic`). The
normative behaviour becomes what the engine actually does: `union` keeps distinct arms, and flow narrowing
concretizes a guarded `Dynamic`. The spec is revised to match in the same change.

Grounding: [2026-07-11 dynamic-facet algebra spike](../notes/20260711-dynamic-facet-algebra-spike.md)
(measurement) + the [2026-07-11 spec audit ledger](../notes/20260711-docs-audit-type-spec.md) that surfaced
the divergence.

## Context

`value-lattice.md` § "Algebraic rules" states, as normative, a dynamic-origin algebra for the value-lattice
operators:

```text
Dynamic[A] | Dynamic[B] = Dynamic[A | B]     T | Dynamic[U] = Dynamic[T | U]     (join)
Dynamic[T] & U = Dynamic[T & U]              Dynamic[T] - U = Dynamic[T - U]      (meet / difference)
```

`Type::Combinator` (`lib/rigor/type/combinator.rb`) applies none of it — `union` / `intersection` /
`difference` treat a `Dynamic` operand as an ordinary member, so `String | Dynamic[Integer]` stays
`Union[String, Dynamic[Integer]]` (not `Dynamic[Integer | String]`) and `untyped & String` stays
`Intersection[Dynamic[top], String]` (not `Dynamic[String]`). The 2026-07-11 audit flagged this as a
spec-vs-implementation divergence. This ADR decides which side is authoritative.

## Decision

**Do not implement the founding dynamic-origin join algebra; keep the engine's behaviour and revise the
spec to match.** The current behaviour is not an oversight — it is the better design, and a spike proves the
spec form is inert at best and precision-negative at worst.

**Criterion — a value-combination rule earns its place only if it improves precision or protection
somewhere measurable; a rule that only re-canonicalizes representation, or that trades precision for
provenance no consumer reads, is not adopted.** The dynamic-origin join fails this on all three operators:

- **Join** (`T | Dynamic[U]`) absorbs a *concrete* arm into `Dynamic` — the precision-negative direction,
  against the protection-first arc of [ADR-82](82-dynamic-provenance-wiring.md) / [ADR-67](67-parameter-type-inference.md).
  Keeping distinct union arms (`Union[String, Dynamic[Integer]]`) is strictly more precise and carries
  finer provenance (which arm is dynamic is known). This is the authoritative behaviour.
- **Meet** (`Dynamic[T] & U`) is the only precision-positive rule, but flow narrowing already does *more*:
  `narrowing.rb:2317` narrows a `Dynamic[top]` receiver under `is_a?(String)` to `Nominal[String]` — full
  concretization, which makes the guarded receiver **protected**. The provenance-preserving `Dynamic[String]`
  form only matters for a future strict-dynamic discipline ([ADR-75](75-dynamic-provenance.md) WD4,
  demand-gated) and adopting it today would *regress* protection.
- **Difference** has one in-tree caller (`narrowing.rb:613`); the transform is moot.

The spike (grounding note) implemented all three and measured **zero delta**: self-check `lib` diagnostics
identical, coverage `precise_ratio` on `lib` identical (0.5632; dynamic_opaque actually rose), Mastodon
`app/models` diagnostics identical — while adding a `Dynamic`-scan + recursion to the hottest paths
(`union` / `intersection`).

## Rejected / deferred alternatives

| Option | Why not |
| --- | --- |
| Implement the founding algebra to match the spec | Zero measured value; precision-negative (absorbs concrete arms); perm cost on the hottest paths; large blast radius on a fundamental invariant. |
| Mark the algebra "planned / not yet wired" (the [ADR-41](41-inference-budget-design.md) honesty-marker pattern) | Misleading — it is not *pending* work, it is a design Rigor deliberately does *not* want. "Superseded" is the honest label. |
| Adopt only the meet rule (provenance-preserving narrowing `Dynamic[T] & U → Dynamic[T&U]`) | Would require changing *narrowing* (not just `Combinator`) to stop concretizing, regressing protection today; its only payoff is the demand-gated strict-dynamic discipline. Deferred to [ADR-75](75-dynamic-provenance.md) WD4 if that ships. |

## Consequences

- **Positive:** the spec stops asserting behaviour the engine does not have; the more precise,
  protection-friendly union-preserving behaviour is now the documented contract; no engine change, no risk.
- **Negative / carry-over:** if the strict-dynamic discipline (ADR-75 WD4) is ever built, it must revisit
  provenance-preserving narrowing then — the meet rule is deferred, not permanently closed, and that ADR
  owns the re-open trigger.
- The `RBS`-boundary round-trip (`Dynamic[top] ↔ untyped`, preserved generic slots) is unaffected — this
  ADR is about *combining* dynamic-origin types, not representing or erasing them.

## Relationship to other ADRs

- [ADR-75](75-dynamic-provenance.md) — owns `Dynamic[T]` provenance and the deferred strict-dynamic
  discipline that is the only future consumer of provenance-preserving narrowing.
- [ADR-82](82-dynamic-provenance-wiring.md) / [ADR-67](67-parameter-type-inference.md) — the protection-first
  direction the join rule contradicts.
- Normative home: [`value-lattice.md`](../type-specification/value-lattice.md) and
  [`normalization.md`](../type-specification/normalization.md), revised alongside this ADR.
