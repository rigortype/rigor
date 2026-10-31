# A callee-chain walk cut at its node cap now floors the argument, reversing #2295's "read as no hand-off"

- **PR:** [#2516](https://github.com/rigortype/rigor/pull/2516)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-31

## Background

#2295 (commit a905ca304, issue #2104) made the callee floor transitive and decided that a hand-off the walk reaches
past `CalleeMutationChain::MAX_NODES` reads as no hand-off, as an unresolved callee does, so the argument keeps its
literal. Its reason: the walk then also followed unrelated calls, and flooring on evidence the walk never saw dropped
literal shapes on correct code. #2516 adds constant-receiver, instance-receiver and cross-class hand-offs, which put
many more nodes on the graph, and the shared 32-node budget starved one parameter's walk with another's. A cut that
reads as "not mutated" turned that starvation into a false positive.

## Options and trade-offs

- Keep "read as no hand-off" and only make the budget per parameter. Cheapest, but any chain or fan-out past the cap
  still reports `flow.always-truthy-condition` on a hash a callee does write.
- Floor on a cut (taken). A cut is a hit on the new `BudgetTrace::CALLEE_CHAIN_CAP` category, and the argument loses
  its literal shape. Flooring drops facts, so it removes the `flow.always-truthy-condition` reports a kept literal caused; it can still surface a mismatch against a declared type (a floored `Array[Dynamic[top]]` against a declared tuple, the case #2295 cited). It costs true positives: a literal
  collection that fans out to more than 32 non-mutating callees now loses its shape (the reviewer's `c1_fanout_tp.rb`
  and `c3_fanout_opts.rb`).

## Decision

Floor on a cut. The walk now follows only the parameter-flow graph (a node is one parameter of one def, reached only
by a hand-off of that parameter) and has a budget per parameter, so #2104's "sixteen unrelated calls" problem cannot
recur: unrelated calls are not nodes. With that, a cut is rare and the FP-safe direction is the right one. On Rigor's
own `lib` the cap is hit 629 times across 256 (def, parameter) pairs, with no visible diagnostic change.

## To undo

Make `Flow#visit` in `lib/rigor/inference/callee_mutation_chain.rb` leave the unread frontier out instead of adding it
as mutated nodes, and restore the two specs in `spec/integration/callee_chain_mutation_spec.rb` (the 40-deep chain
expects the true positive again). The `callee_chain_cap` trace category can stay.
