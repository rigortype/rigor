# A call with a positional splat re-types a user method body with no positional correspondence instead of expanding a Tuple splat

- **PR:** [#3097](https://github.com/rigortype/rigor/pull/3097)
- **Issue:** [#1237](https://github.com/rigortype/rigor/issues/1237)
- **Class:** open-choice
- **Precedent:** [#1236](https://github.com/rigortype/rigor/pull/1236)
- **Decided:** 2026-11-12

## Background

The tiers that re-type a user `def` body for a call's return bound a call-site `*splat` as one positional
argument, so `def count(*keys) = keys.size` folded `r.count(*idx)` to `1`. Under a splat the body is now re-typed
with no positional correspondence: every positional parameter is `Dynamic[top]`, the rest parameter is
`Array[untyped]`, and the keywords come from a keyword hash the call writes. The coordinator ruled on that shape
after review. The lane brief left open whether a splat of known length (`m(*[1, 2])`, a `Tuple`-typed local)
should instead be expanded into positionals.

## Options and trade-offs

- Expand a `Tuple` splat into its element types. This keeps per-parameter precision for literal and tuple
  splats, but it needs a second argument path in `call_arg_types`, which every dispatch tier and the ADR-84
  return memo read.
- Treat a Tuple splat like any other splat: no positional correspondence. This is the smaller change. It costs
  the element types: `def first(*xs) = xs.first` called `first(*[1, 2])` answers `untyped`, not `1`.

## Decision

Treat every positional splat alike. It is the smaller sound change, and #1236 set the same rule (no positional
binding under a splat) for the compound index read.

## To undo

Teach `call_arg_types` to expand a `Tuple` splat, and narrow `ExpressionTyper#splat_arguments?` to the splats it
did not expand.
