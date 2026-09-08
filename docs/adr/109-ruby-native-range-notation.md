# ADR-109 — Ruby range literals as the notation and the semantics of numeric range refinements

Status: **Accepted, 2026-09-08 — slice 1 landed with this ADR in
[#830](https://github.com/rigortype/rigor/pull/830); slice 2 landed 2026-09-09.** Slice 1 restores
ADR-1's decision for `Integer`: the carrier displays `Integer[1..10]` / `Integer[0..]` /
`Integer[..-1]`, the `%a{rigor:v1:…}` grammar accepts the same spelling, and `int<a, b>` stays
accepted as a deprecated input alias that nothing prints any more. Slice 2 adds the `Float[R]`
carrier (`Type::FloatRange`) with `non-nan-float` / `finite-float`, reachable through annotations
only. Slice 3 (Float comparison narrowing and folds) and the deprecation diagnostic are designed in
§ WD3 and § WD5, tracked in [#831](https://github.com/rigortype/rigor/issues/831), and not built;
the narrowing rule carries a *Reserved (as of this writing)* marker in the spec. Archetype: deliberative.
Stakes: mid — the annotation grammar is public surface ([ADR-50](50-release-engineering-and-stability-strategy.md)
WD1) so the old input form gets a deprecation window; the display is not contract; the Float
part touches the soundness envelope through NaN and is fixed here at design level only.

Grounding: [`docs/notes/20260908-ruby-range-notation-and-float-intervals.md`](../notes/20260908-ruby-range-notation-and-float-intervals.md)
(the drift timeline, the round-trip defect, and every Ruby 4.0.5 fact cited below, with
reproduction commands).

## Context

[ADR-1](1-types.md) rejected PHPStan's `int<1, 10>` and named `Integer[1..10]` as the range
notation "to stay closer to Ruby and RBS naming". The carrier that shipped five days later
(`2ad0d4c6`) printed `int<min, max>` anyway, and the 2026-06-21 docs-contradiction sweep
(`3a58eac3`) resolved the disagreement on the code's side, leaving ADR-1's rejection row and the
`Integer[1..]` row of `rigor-extensions.md` untouched. The binding corpus has contradicted itself
since; no commit records a decision to override ADR-1.

The imported spelling also failed on its own terms:

- **It does not round-trip.** `describe` prints `int<0, max>`, but the grammar accepts only
  integer literals as bounds, so copying a diagnostic into a signature yields
  `dynamic.rbs-extended.unresolved`. The handbook and the manual documented `int<min, max>` as the
  input form.
- **It cannot extend to `Float`.** `min` / `max` as bound keywords read as `Float::MIN` /
  `Float::MAX` to a Rubyist, and `Float::MIN` is the smallest positive *normal* double, not a lower
  bound of anything. A Float interval also needs the closed / half-open distinction that `..` and
  `...` already spell and that `int<a, b>` has no slot for. The spec's "future `finite-float` or
  non-NaN proof" had no notation to land in.
- **Ruby already owns the semantics.** `Range#cover?` decides every hard case a Float interval
  raises — NaN, ±∞, `-0.0`, the exclusive end, the unbounded range — and `rand(0.0...1.0)`,
  `x.clamp(0.0..1.0)` and `case x in 1..9` are the idioms Ruby programmers use for exactly these
  sets. The engine already reads `when 1...10` as `int<1, 9>`.

## Decision

**A refinement whose value set is exactly what a Ruby literal's own predicate accepts is spelled
with that literal and defined by that predicate.** An imported spelling (`non-empty-string`,
`positive-int`) is kept only where Ruby has no literal for the set. Applied here: a numeric range
is a Ruby `Range` literal, and the set is what `Range#cover?` says it is.

For a numeric class `C` (`Integer` now, `Float` in slice 2) and a Ruby `Range` literal `R`:

```
C[R]  =  { x | x.is_a?(C) && R.cover?(x) }
```

`R` is spelled as Ruby spells it: `Integer[1..10]`, `Integer[1...10]`, `Integer[1..]`,
`Integer[..-1]`, `Integer[nil..nil]`. The class head is mandatory: `(1..10).cover?(5.5)` is true, so a
bare range literal does not denote integers, and the engine already prints a bare `1..10` for the
`Range` *value* (`Constant<Range>`).

### Working decisions

**WD1 — Integer canonical form.** The carrier stays `Type::IntegerRange` with closed bounds.
`Integer[a...b]` canonicalises to `Integer[a..b-1]` (Ruby: `(1...10).to_a == (1..9).to_a`), so the
display is always closed; a missing or `nil` endpoint is the symbolic infinity; the universal range
displays as `Integer`, not `int`. The four ADR-1 aliases `positive-int`, `non-negative-int`,
`negative-int`, `non-positive-int` remain input names and remain the preferred display for their
ranges. An empty range (`Integer[5..1]`, `Integer[1...1]`) **declines** as an unresolvable payload
rather than resolving to `bot`: a typo that silently makes every caller dead code is the false
positive this repository weighs highest.

**WD2 — Where the grammar lives.** `Builtins::ImportedRefinements::Parser` gains a
`TypeNode::RangeLiteral` leaf (the value is the `Range` object itself, so `begin` / `end` /
`exclude_end?` have one representation); `parse_single_type_arg_ast` tries the range shape before
the bare integer. The resolver handles the `Integer` head with a single `RangeLiteral` argument before
the RBS `Nominal` fallback (`Resolver#try_range_head_builder`); under any other head the literal
lifts to `Constant<Range>` like the other leaf literals, so plugin resolvers
([ADR-13](13-typenode-resolver-plugin.md)) may consume it.

**WD3 — The deprecated alias.** `int<a, b>` remains accepted by the grammar for one deprecation
window and is never printed again. The warning-window step of ADR-50 WD7 is a
`dynamic.rbs-extended.deprecated-form` info diagnostic (follow-up); removal rides the next
compatibility break. Diagnostic text is non-contract (ADR-50 § Decision 3), so the display change
ships in a minor; a message-mode baseline that matched `int<` is regenerated.

**WD4 — `Float[R]` (slice 2, design).** A `Type::FloatRange` carrier holds two doubles (±`Float::INFINITY`
are ordinary values, never `nil`) and `exclude_end`; there is no exclusive begin because Ruby has
none. Endpoints are Integer or Float literals (Integer coerces, as `(0..1).cover?(0.5)` does),
`Float::INFINITY`, `-Float::INFINITY`, `Float::MAX`, `-Float::MAX`, or absent. `Float[nil..nil]`
normalises to `Float` because `(nil..nil).cover?(Float::NAN)` is true; every other range excludes NaN
because `cover?` compares. Two names are reserved for the ranges people mean most:

| Name | Range | Set |
| --- | --- | --- |
| `non-nan-float` | `Float[-Float::INFINITY..]` | every Float except NaN |
| `finite-float` | `Float[-Float::MAX..Float::MAX]` | every Float except NaN and ±∞ |

The display prefers the name, as WD1 does for `positive-int`; the range form is the definition.
There is no separate "NaN-ness" carrier: NaN exclusion is a property of every bounded range, so
"Float range versus `non-nan-float`" is not a choice, the second is an alias of the first.
`Float::NAN` is never a `Constant` carrier (`Float::NAN.eql?(Float::NAN)` is false, which
`ValueSemantics` cannot represent); the truthy edge of `x.nan?` keeps its entry type.

**WD5 — Float narrowing (slice 3, design).** Comparison narrowing is truthy-edge only: `x < c` →
`Float[...c]`, `x <= c` → `Float[..c]`, `x >= c` → `Float[c..]`, `x > c` → `Float[c..]`. The last is
a closed envelope one double wider than the exact set `(c, ∞]`; the exact form `Float[c.next_float..]`
exists (Ruby ships `Float#next_float`) and is deferred until a rule demands the removed point. The
falsy edge keeps the entry type in every case, because `!(x > c)` includes NaN. `x.nan?` falsy →
`non-nan-float`; `x.finite?` truthy → `finite-float`. Algebra (containment, join, meet) runs on
canonical closed doubles via `next_float` / `prev_float`; the display keeps the written `...`. This
mirrors the interval model the PHPStan float-range proposal reached
([phpstan/phpstan#6963](https://github.com/phpstan/phpstan/issues/6963)) minus the open begin, which
Ruby's literal does not have and Ruby's hazards do not need: `1.0 / 0.0` is `Infinity`, and what
raises is `to_i` / `round` / `JSON.generate` / `sort` on NaN or ±∞.

**WD6 — Spec homes.** Names and the `cover?` definition: `imported-built-in-types.md`. Grammar:
`rbs-extended.md`. The catalogue row: `rigor-extensions.md`. The display convention: `docs/types.md`
(square brackets after a numeric class hold a Ruby range literal). Every slice-2/3 form carries a
*Reserved (as of this writing)* marker per [ADR-92](92-normative-status-fidelity.md) until it lands.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Keep `int<min, max>` and add `float<min, max, closed-open>` | Fails the criterion; `min` misreads as `Float::MIN`; a third-argument boundary vocabulary re-invents `...`; the one-way syntax stays |
| A bare range literal as the type (`1..10`) | Collides with the `Constant<Range>` display, and `(1..10).cover?(5.5)` is true: the literal does not say "integer" |
| The hybrid `int<1..10>` | Keeps a head Ruby does not have; the angle bracket carried no information once the literal spells the bounds |
| ISO interval display `float<[0.0, 1.0)>` | Not Ruby, and not parseable by the grammar that reads the annotation back; the PHPStan review flagged that gap as Major |
| `Float[nil..nil]` as "non-NaN" | Ruby says the unbounded range covers NaN; the type follows `cover?`, not intuition |
| Empty range resolves to `bot` | A typo becomes dead code at every caller; decline instead |
| Extend the float model to `Rational` / `Complex` | `Complex` has no order; `Rational` is exact and may get its own ADR |

## Consequences

- **Positive.** Display and input are one spelling that parses; `Float` gets a notation and a
  definition without new vocabulary; the notation matches `case/when`, `rand`, `clamp` and
  `Range#cover?`, so the handbook teaches nothing a Rubyist does not know.
- **Negative.** Adopters with `int<a, b>` in signatures get a deprecation cycle; message-mode
  baselines that matched `int<` need regeneration; the PHPStan appendix loses its "identical syntax"
  row for ranges; about two hundred occurrences across lib, spec and docs churn in slice 1.
- **Carry-over.** Slice 2/3 tracking issue; the `dynamic.rbs-extended.deprecated-form`
  diagnostic; `n.clamp(1..9)` and `rand(0.0...1.0)` folds noted in the grounding note.

## Relationship to other ADRs

[ADR-1](1-types.md) made this decision; this ADR restores it and adds the definition.
[ADR-3](3-type-representation.md) owns the carriers (`IntegerRange`, the future `FloatRange`, the
`Constant<Range>` value). [ADR-5](5-robustness-principle.md) is why ranges are worth carrying.
[ADR-13](13-typenode-resolver-plugin.md) owns the `TypeNode` AST the new leaf joins.
[ADR-50](50-release-engineering-and-stability-strategy.md) sets the deprecation window.
[ADR-92](92-normative-status-fidelity.md) supplies the reserved-marker idiom.
[ADR-107](107-checked-types-and-typeless-comments.md) is the same value one level down: a type that
is written must be one Rigor can read back.
