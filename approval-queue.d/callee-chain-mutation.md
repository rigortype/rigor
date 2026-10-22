# Close the callee floor over self-call hand-offs, count a hand-off the closure cannot read as a mutation, and keep an unresolved self-call silent

- **PR:** [#2295](https://github.com/rigortype/rigor/pull/2295)
- **Issue:** [#2104](https://github.com/rigortype/rigor/issues/2104)
- **Class:** open-choice
- **Precedent:** [#68](https://github.com/rigortype/rigor/pull/68)
- **Decided:** 2026-10-22

## Background

#2104 asked for a collection passed to a callee chain that may mutate it to lose its literal shape. It asked for
the chain to be bounded or closed by a fixpoint, and for a conservative answer where a callee body cannot be read.
It left three questions open: what "cannot be read" covers, how keyword arguments bind, and what the incremental
session's effects surface should record now that a def's census depends on other defs.

## Options and trade-offs

- **Bound.** A depth bound alone misses a mutation one hop past it. A per-root least fixpoint costs one graph walk
  per def. Chosen: a least fixpoint over at most 16 defs per closure (`CalleeMutationChain::MAX_DEFS`). A recursive
  or mutually recursive chain then terminates, and a cycle with no mutation on it mutates nothing.
- **A hand-off into a def past the cap.** Reading it as no mutation keeps the literal shape, which is the
  false-positive direction. Reading it as a mutation loses only precision. Chosen: mutation.
- **A self-call that resolves to no def in the class** (inherited, mixed in, `method_missing`). Reading it as a
  mutation would floor every argument a method passes to an inherited helper, which the one-level floor (#68) has
  never done. Chosen: no hand-off, the same reading the one-level floor gives it.
- **A positional argument after a splat or `...`.** Its index says nothing about the parameter it binds. Chosen:
  it can bind any mutated parameter of the callee.
- **Keyword parameters.** The census was positional only. Chosen: keyword parameters join it under their keyword,
  on the one-level floor too, because a keyword hand-off needs the callee's keyword slot.
- **The incremental effects surface** (`content_mutated_parameter_positions`). The session's empty scope resolves no
  callee, so it cannot see the transitive census, and an edit that starts or stops forwarding would leave the
  effects unchanged. Chosen: the surface also lists every parameter the def passes to a self-call, resolved or not.
  For a forwarding def, a snapshot taken before this change differs once, which keeps its dependents.

## Decision

Each choice above is the option that cannot keep a stale literal shape where the census can see the hand-off. None
of them floors an argument that the one-level floor of #68 would keep.

## To undo

Revert `Inference::CalleeMutationChain` and the census changes in `StatementEvaluator`. The spec
`spec/integration/callee_chain_mutation_spec.rb` pins each choice.
