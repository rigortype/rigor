# A call with a positional splat declines user-body return inference instead of expanding a Tuple splat

- **PR:** [#3097](https://github.com/rigortype/rigor/pull/3097)
- **Issue:** [#1237](https://github.com/rigortype/rigor/issues/1237)
- **Class:** open-choice
- **Precedent:** [#1236](https://github.com/rigortype/rigor/pull/1236)
- **Decided:** 2026-11-12

## Background

The tiers that re-type a user `def` body for a call's return bound a call-site `*splat` as one positional
argument, so `def count(*keys) = keys.size` folded `r.count(*idx)` to `1`. The lane brief left open whether a
splat whose length is known (`m(*[1, 2])`, a `Tuple`-typed local) should be expanded into positionals or declined
like the unknown-length case.

## Options and trade-offs

- Expand a `Tuple` splat into its element types. This keeps precision for literal and tuple splats, but it needs a
  second argument path in `call_arg_types`, and every dispatch tier and the ADR-84 return memo read that list.
- Decline every positional splat. This is one guard per body tier and matches `try_literal_send` and #1236's
  compound index read. It costs precision on tuple splats, which used to fold (wrongly).

## Decision

Decline every positional splat. It is the smaller sound change, and #1236 set the same rule for the index read.

## To undo

Teach `call_arg_types` to expand a `Tuple` splat and narrow `ExpressionTyper#splat_arguments?` to splats it did not
expand. `spec/integration/call_site_splat_return_spec.rb`'s literal-array example then needs a new expectation.
