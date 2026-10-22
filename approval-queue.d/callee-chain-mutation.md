# Close the callee floor over self-call hand-offs of the same parameter, and read a hand-off it cannot follow as none

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

- **Graph and bound.** A first cut walked every hand-off of every parameter of every def it reached, up to 16 defs,
  and counted a hand-off past the cap as a mutation. Review showed that sixteen calls handing an unrelated parameter
  elsewhere, an 18-leaf fan-out, or a 17-deep chain with no mutation all exhausted the cap. Each then floored the
  argument to `Array[Dynamic[top]]`, which fails a declared tuple: a new false positive, and about 300 roots in
  Rigor's own `lib` hit the cap. Chosen: a parameter-flow graph. A node is one parameter of one def, the walk follows
  only the hand-offs of that parameter, and it takes the least fixpoint over at most 32 nodes
  (`CalleeMutationChain::MAX_NODES`). Recursive chains terminate, and a cycle with no mutation on it mutates nothing.
- **A hand-off to a node past the cap.** Reading it as a mutation floors on evidence the walk never saw, which is
  the false positive above. Reading it as none keeps the literal shape, which is the same answer the one-level floor
  (#68) gives a callee it cannot resolve, and it misses a mutation past the first 32 parameter nodes read breadth
  first, including a wide fan-out of one parameter. Chosen: none.
- **A self-call that resolves to no def in the class** (inherited, mixed in, `method_missing`). Chosen: no hand-off,
  as #68 reads it.
- **A self-call inside a block that runs on another `self`** (`instance_exec`, `class_exec`, `Class.new { … }`, …).
  It does not call the method's receiver. Chosen: not a hand-off. A `define_method` / `define_singleton_method`
  block keeps an instance of the class as `self`, but it is a method body that runs later, if ever. Chosen,
  conservatively: not a hand-off either.
- **A positional argument after a splat or `...`.** Its index says nothing about the parameter it binds. Chosen: it
  may bind any positional parameter of the callee. An argument before the first splat keeps its index.
- **Keyword parameters.** The census was positional only. Chosen: keyword parameters join it under their keyword,
  on the one-level floor too, because a keyword hand-off needs the callee's keyword slot.
- **The incremental effects surface** (`content_mutated_parameter_positions`). The session's empty scope resolves no
  callee, so it cannot see the transitive census, and an edit that starts or stops forwarding would leave the
  effects unchanged. Chosen: the surface also lists every parameter the def passes to a self-call, resolved or not.
  For a forwarding def, a snapshot taken before this change differs once, which keeps its dependents.

## Decision

Where the walk can see a hand-off of the parameter to a mutating callee, the argument is floored. Where it cannot
(past the cap, an unresolved callee, a block on another `self` or a `define_method` body), the argument keeps its literal shape, as under
#68. The new floors are the only new ones: a chain the walk reads to a mutation. The floor only removes a literal
shape, so it can remove a finding but cannot add one, except that a floored array no longer matches a declared tuple.
herb and haml show no new rows.

## To undo

Revert `Inference::CalleeMutationChain` and the census changes in `StatementEvaluator`. The spec
`spec/integration/callee_chain_mutation_spec.rb` pins each choice.
