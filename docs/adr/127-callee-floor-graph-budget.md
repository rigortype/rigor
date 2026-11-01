# ADR-127 — The callee mutation floor answers a graph property, not a walk

Status: **Accepted, 2026-11-01, with K = 64.** Nothing is implemented yet. The prototype measurements below were taken
on `a53b68c4d` with an env-switched prototype and a reference patch. The work closes
[#2520](https://github.com/rigortype/rigor/issues/2520) and leaves
[#2521](https://github.com/rigortype/rigor/issues/2521) and
[#2522](https://github.com/rigortype/rigor/issues/2522) open (WD4).

Grounding: the #2104 bullet in [`inference-engine.md`](../internal-spec/inference-engine.md). The
memo-key defects fixed in [#2516](https://github.com/rigortype/rigor/pull/2516),
[#2524](https://github.com/rigortype/rigor/issues/2524) and
[#2558](https://github.com/rigortype/rigor/pull/2558).

## Context

The callee mutation floor drops a local literal's shape facts when a callee the literal is handed to
may write it. To decide that, it walks each parameter's hand-off graph. A node is one parameter of one
def under one owner context. The walk reads at most `MAX_NODES` (32) nodes per parameter, and a node
still unread at the cut counts as mutated (#2516). That reading is conservative, but it loses true
positives on a wide read-only fan-out (#2520): a literal handed to 40 pure leaves is floored.

The obvious fix is a memo of settled answers. A walk that persists each node's answer lets later walks
skip it without spending budget. That prototype (V1/V2) cost −0.43% allocations against master and
regained the #2520 diagnostics at a 64-node budget. But it charges the budget for *fresh* nodes, so a
walk's answer depends on what earlier walks in the same file persisted. Example: `a(x)` hands `x` to
70 leaves and `b(x)` hands it to 40 of the same leaves. Walking `a` first floors `a`'s argument;
walking `b` first leaves only 30 fresh leaves for `a`, which fit, so `a`'s argument is not floored.
The same call then reports in one file and not in another.

This subsystem has had three memo-key defects in one month, each an order-dependent false positive:
the singleton side, the caller's constant narrowings in the typed-receiver memo, and the same
narrowings in the per-def census memo. A fourth, history-shaped one is the wrong direction.

Two measured facts shape the decision (`lib/`, `--no-cache --workers 0`):

- **The graph is small.** Across 27,980 (root, parameter) walks the union of all reaches is 22,340
  nodes. The largest reach is 400 nodes, and only 130 pure walks reach more than 64.
- **Visits are not the cost.** An uncapped walk visits only 16% more than cap 32. The cost is
  `compute_forwarding_edges` on newly reached defs: about 2.0M objects, 4.8% of the run. Every file
  that reaches a far def pays this again, because the census and edge memos are keyed by the file's
  `DiscoveryIndex`. So they are per file, not per run (`ScopeIndexer.index` builds a fresh one per
  file).

## Decision

**Criterion: a memoised answer in the callee floor is a function of its key, and the budget counts
only quantities the graph defines, never what earlier walks did.** The spec states the floor as a
property of the parameter-flow graph, and the implementation is any computation of that property.

The property, for a parameter `r`: **`r` is floored iff an own-mutated node is reachable from `r`
through nodes the def does not itself mutate, or more than K distinct nodes are reachable from `r`.**
That is what master already means, since a cut counts as mutated. The change is that no input depends
on visit history.

### WD1 — The walk

Per parameter, breadth first with a walk-local `seen` set:

- A node is counted, and its own mutation checked, when it is first discovered.
- The walk stops with *mutated* at the first own-mutated node.
- It stops with *cut* when more than K nodes have been discovered. The frontier's edges are then never
  computed, which is where the saving comes from.
- It answers *not mutated* when the reach is exhausted.

No settle loop is needed, because the least fixpoint is reachability. The floor answer is independent
of breadth-first and edge order. Only the label (an exact answer or a cut, and so the
`BudgetTrace::CALLEE_CHAIN_CAP` count) can vary. **K = 64.**

### WD2 — What is persisted

Only graph facts:

- the def's own census (`def_census`, AST only, already shared across files);
- the forwarding edges (`resolved_census(:edges)`, already memoised);
- a new successor store `def → owner-or-context → name → [callee, name, owner, …]`.

The successor store is a `RunScopedSlots` slot keyed by discovery and bypassed under
`hand_off_memo_bypassed?` (constant narrowings or an active dependency recorder). No walk's conclusion
is persisted. The per-def closure memo stays, because the closure is now a function of (discovery,
side, class, def, K). There is no persistent cache-format change.

The key is complete. Every input the walk reads is the def node, the census kind, the discovery, the
environment (one per run), the self type's side and class, the constant narrowings (bypassed), or the
recorder (bypassed). The lexical nesting is overridden from the class name before any constant is
typed. The rooted `::K` arm reads no nesting.

### WD3 — Order-dependence is caught mechanically

- **Memo-audit mode.** A spec- and CI-only switch, like `BudgetTrace`. On every hit in
  `resolved_census`, `hand_off_memo`, the successor store and `def_census`, it recomputes the value
  and asserts that it equals the stored one. This finds a key that misses an input without needing to
  find the order that exposes it. #2516's and #2524's defects would each have failed it. CI runs it
  over the callee specs and over `rigor check --no-cache --workers 0 lib`.
- **A permutation spec.** The adversarial programs (the #2516 and #2524 probes, the fan-outs, the
  witness above) run under every in-file def order, under different file-name orders, and under
  `workers: 0` and `workers: 2`, asserting one diagnostic set.
- **A property test on `CalleeMutationChain`.** Over random small graphs, the answer equals the
  reference property and is invariant under prior walks sharing the store.
- **The `callee_chain_mutation_spec.rb` cap example** is rewritten to a `K + 9` chain.

### WD4 — Inherited and owner-switching defs stay floored

They keep `FLOOR_ALL`. Walking them needs two things that are not available mode-independently today:

- the defining class's nesting. `discovered_def_nestings` exists, but it is identity-keyed and absent
  from the cache snapshot, so using it would make `--incremental` and `--no-cache` disagree (#2522);
- instance-side self-call resolution through ancestors.

The node key (def, owner, name) already accommodates an owner that carries both identities, so #2521
builds on this ADR once those land.

### WD5 — Spec text

The #2104 bullet's "reads at most 32 nodes, breadth first; a node still unread at the cut MUST count as
mutated" becomes the graph property with K = 64. It also notes that `CALLEE_CHAIN_CAP` counts labels,
which may vary with order, while the floor itself does not.

## Rejected alternatives

| Alternative | Why not |
|---|---|
| Settled-answer memo with a fresh-node budget (prototype V1/V2) | The answer depends on walk history (the `a`/`b` witness above), and that cannot be stated in the spec. |
| No cap | +1.87% allocations: each file reaching a far def recomputes its edges. |
| Eager per-SCC pre-pass over discovery | Computes edges for every def on every run, pays on projects that never floor, and gains no precision at equal K. |
| A per-SCC budget | It does not bound the edge cost, and it over-floors recursion. |
| Persisted reach sets or summed reach sizes | Order-independent, but they over-cut diamonds or cost memory, and visits are not the cost. |
| Out-degree or depth caps | They cut exactly #2520's fan-outs. |
| An edges memo shared across files (keyed by the project seed) | The real cost lever (an estimated −1.4%), but a textbook key-completeness risk: the per-file table wins and editor buffers diverge. Deferred until the WD3 audit mode can guard it. |

## Consequences

- **Positive:** the floor is order-independent by construction, across in-file order, files, worker
  partitions and cache modes. Measured on `lib/`: −0.12% allocations against master (K = 32 would be
  −0.42%, K = 128 +0.24%). Cut walks drop from 645 to 130. Diagnostics on `lib/`, kramdown and haml
  are identical, and both #2520 fixtures regain their diagnostics.
- **Negative:** 130 pure walks on `lib/` are still floored at K = 64. The `CALLEE_CHAIN_CAP` count is
  no longer stable across orders. The cost stays about 0.3 points above the pre-#2516 level
  (`b48ed7393`); K = 48 would roughly meet it, at the price of floored walks rising to about 276.
- **Carry-over:** the cross-file edges memo (rejected above) once the audit mode exists. #2521 after
  #2522 and instance-side ancestor self-calls. A separate decision on whether an inherited def that
  only reads keeps the literal (the pinned reading in `approval-queue.d/callee-floor-inherited-no-walk.md`).

## Relationship to other ADRs

[ADR-5](5-robustness-principle.md): a cut floors, so the robustness direction is unchanged.
[ADR-46](46-incremental-dependency-graph.md) and [ADR-85](85-seed-bundles-and-lazy-def-node-handles.md):
cache-mode agreement follows from discovery agreement, which `--verify-incremental` already asserts.
