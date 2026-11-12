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

### Also decided

- A `f(...)` call with no forwarding frame to expand it from counts as a splat (`ExpressionTyper#splat_arguments?`),
  so it also gets the binding with no positional correspondence. This covers a `def m(...)` body re-typed for a
  splat call, and the main walk of a `def m(...)` body. Without it, `def fwd(...) = count(...)` re-typed for
  `fwd(*idx)` binds the inner `...` as one argument again.
- The #1125 RECORDED DECISION pin "declines a bare *args forwarding" in
  `spec/rigor/inference/keyword_splat_forwarding_binding_spec.rb` (now titled "does not expand a bare *args
  forwarding") moves. Before: `forward(1, 2)` through `def forward(*args) = target(*args)` answered
  `Dynamic[top]`. After: it answers `[Dynamic[top], Dynamic[top]]`. The new answer is more precise, and the Tuple
  is still not expanded.
- A splat call stores its return-memo entry under a key of its own (the coordinator ruled this in review). The
  ADR-89 return summary carries such a key as `[receiver, arg_types, true]`, and the incremental gate re-drives it
  with no positional correspondence. Because of that new key shape, the incremental snapshot SCHEMA moves from 47 to
  48: a pre-48 summary holds a splat call under a positional key that was bound as one argument. The cost is one
  cold rebuild of every incremental snapshot.

## To undo

Teach `call_arg_types` to expand a `Tuple` splat, and narrow `ExpressionTyper#splat_arguments?` to the splats it
did not expand.
