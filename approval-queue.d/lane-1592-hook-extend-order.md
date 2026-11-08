# A class's own extends sit nearer than its hook-extended modules, with the other order as the retro world

- **PR:** pending
- **Issue:** [#1592](https://github.com/rigortype/rigor/issues/1592)
- **Class:** open-choice
- **Precedent:** [ADR-24](../docs/adr/24-self-method-call-resolution.md)
- **Decided:** 2026-11-09

## Background

Issue #1592 puts the modules a class's direct mixins extend it with through a hook (a concern's `ClassMethods`, an
`included do extend M end` block, a `self.included(base) = base.extend(M)` hook) on the class's singleton resolution
chain. Ruby inserts each where its statement ran, but the tables keep `extend` statements and `include` statements in
separate lists, so a class that has both has no recorded order between the two blocks. The issue did not say where
the hook modules go.

## Options and trade-offs

- Settle every such chain to master. Master's singleton answer is the class objects alone, so the hook modules would
  vanish from the typing read whenever the class also `extend`s anything, which is common in Rails models.
- Pick one order and count it as one fork, with the other order as the retro world. ADR-24's two-world rule then lets
  a reader stand where both orders give one answer. When both orders agree, only one block defines the name, so every
  interleaving agrees.
- Leave the hook modules out wherever the class has its own `extend`s. That keeps the false positive the issue
  reports.

## Decision

The second option. The chain puts the class's own `extend`s nearer, because the usual layout writes them after the
`include`s, and the retro world puts the hook modules nearer. Where the two worlds give different definers, the
class-side typing read types the call `Dynamic`, and a candidate-set read declines, rather than answering master's
class-object definer. ADR-24's retro world was built for a skipped include, and this reuses its rule for a second kind
of two-world fork.

## To undo

Drop `Builder#fork_hook_order(name, 1)` and the `:hook_order` mark in `lib/rigor/scope/resolution_chain.rb`, and
`ExpressionTyper#singleton_hook_order_split?`. Such chains then settle to master.
