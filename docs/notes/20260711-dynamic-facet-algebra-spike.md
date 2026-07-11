# Dynamic-origin algebra — implementation spike + measurement (2026-07-11)

Grounding note for [ADR-83](../adr/83-dynamic-origin-algebra.md). The 2026-07-11 spec-vs-implementation
audit ([type-spec ledger](20260711-docs-audit-type-spec.md)) flagged that `value-lattice.md` § "Algebraic
rules" states a dynamic-origin algebra the engine does not implement. This note records the spike that
measured whether implementing it is worth it. Verdict: **no** — implement nothing, revise the spec.

## The divergence

`value-lattice.md` states three normative identities:

```text
Dynamic[A] | Dynamic[B] = Dynamic[A | B]        (join / union)
T | Dynamic[U]          = Dynamic[T | U]         (join / union)
Dynamic[T] & U          = Dynamic[T & U]         (meet / intersection)
Dynamic[T] - U          = Dynamic[T - U]         (difference)
```

`Type::Combinator` (`lib/rigor/type/combinator.rb`) applies none of them: `union`, `intersection`, and
`difference` treat a `Dynamic` operand as an ordinary member. So the engine yields:

| expression | spec | engine (today) |
| --- | --- | --- |
| `Dynamic[Int] \| Dynamic[Str]` | `Dynamic[Integer \| String]` | `Union[Dynamic[Integer], Dynamic[String]]` |
| `String \| Dynamic[Int]` | `Dynamic[Integer \| String]` | `Union[String, Dynamic[Integer]]` |
| `untyped & String` | `Dynamic[String]` | `Intersection[Dynamic[top], String]` |

## The spike

Implemented all three identities in `Combinator` (unwrap `Dynamic` operands to their static facet, combine,
re-wrap via `dynamic(...)`). Confirmed the transform reproduces the spec:

```
Dynamic[Int] | Dynamic[Str] → Dynamic[Integer | String]
String | Dynamic[Int]       → Dynamic[Integer | String]
untyped & String            → Dynamic[String]
top | Dynamic[Int]          → Dynamic[top]
```

Then measured the impact on real code:

| measurement | baseline (master) | spike | delta |
| --- | --- | --- | --- |
| self-check `rigor check lib` (error/warning lines) | 0 | 0 | **identical** |
| coverage `precise_ratio` on `lib` | 0.5632 | 0.5632 | **identical** (dynamic_opaque +26 — slightly *more* opaque) |
| Mastodon `app/models` diagnostics | 5 | 5 | **identical** |
| broken `spec/rigor/{type,inference}` unit specs | — | 3 | encode current union-arm behaviour |

**Zero user-visible effect.** The transform only reshuffles union↔dynamic representations; it changes no
diagnostic and no precision ratio, on Rigor's own code or a real Rails corpus.

## Why the three rules do not pay off

1. **Join (`T | Dynamic[U] = Dynamic[T|U]`)** absorbs a concrete union arm *into* `Dynamic` — the
   precision-negative direction (dynamic_opaque rose on `lib`), against the protection-first direction of
   ADR-82/ADR-67. Keeping distinct union arms is more precise *and* carries better provenance (you know
   which arm is dynamic). The current behaviour is the better design.
2. **Meet (`Dynamic[T] & U = Dynamic[T&U]`)** is the only precision-positive rule (narrow `untyped` to a
   usable facet), but flow narrowing already does *more*: `narrowing.rb:2317` narrows a `Dynamic[top]`
   receiver under `is_a?(String)` to `Nominal[String]` — full concretization, which makes the guarded
   receiver **protected**. The provenance-preserving `Dynamic[String]` form matters only for a future
   strict-dynamic discipline (ADR-75 WD4, demand-gated) and adopting it today would *regress* protection
   (a narrowed receiver would fall back to `Dynamic` = unprotected).
3. **Difference** has one in-tree caller (`narrowing.rb:613`, refinement narrowing); the transform is moot
   there.

## Cost / risk of implementing anyway

`union` / `intersection` are the hottest paths; the transform adds a `Dynamic`-scan + recursion to every
call for zero gain. It also changes a fundamental type-combination invariant (large blast radius) and would
silently degrade any latent path that relies on `Union[concrete, Dynamic]` keeping its concrete arm.

## Verdict

Do not implement. Resolve the divergence by revising the spec to describe the actual (deliberately better)
behaviour: the join keeps union arms distinct, and narrowing concretizes a guarded `Dynamic`. The
founding-era dynamic-origin join algebra is superseded. Recorded as ADR-83.
