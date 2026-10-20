# Read a block's callee by name across every project definition, and decline when any may rebind self

- **PR:** [#2183](https://github.com/rigortype/rigor/pull/2183)
- **Issue:** [#1817](https://github.com/rigortype/rigor/issues/1817)
- **Class:** open-choice
- **Precedent:** [ADR-34](../docs/adr/34-toplevel-unresolved-self-call-default.md)
- **Decided:** 2026-10-20

## Background

#1817 reported `call.unresolved-toplevel` on a bare call inside a top-level block that a project method runs with `module_eval(&blk)`: the block's `self` is the module, so the call is not a top-level call. The issue left one decision open. Rigor could read the callee's body for evidence, which is inter-procedural and makes the callee's file a dependency of every caller. Or it could decline inside any top-level block passed to a project method that takes an explicit `&blk`, which is cheaper and also silences callees that only call the block. The issue also did not say how the callee is found.

## Options and trade-offs

- **Read the callee's body, found by method name across every project definition (taken).** Every `def` of the name, on any class or side, is read. Rigor declines when any of them may pass the block on (an eval, another method, storage, `super`, `binding`), when the name has a body Rigor cannot read (`attr_*`, `alias_method`, `define_method`, a `pre_eval:` patch, a second `def` the one-body-per-slot table hides), or when a `send` names the method with a non-literal. A callee that only `yield`s or calls the block keeps reporting, as does a callee no project file defines. The cost is a false negative. An unrelated same-named method that rebinds silences a yield-only one, and a project forwarder that keeps `self` (`def each(&b) = @items.each(&b)`, common in `Enumerable` collections) silences the rule inside every block passed to a method of that name, `[1].each { typo }` included. Treating a forward to a core method that keeps `self` as a plain call would narrow that, but deciding which methods qualify by name alone could miss a gem's DSL method, which reports on correct code; it is filed as a follow-up rather than taken here. Incremental soundness is kept by recording `defines:<name>` and each read body's method edge.
- **Read the callee through the receiver's type.** This is more precise when it works. But it reads one class, and missing the definition Ruby actually dispatches to (an `extend`ed module, a subclass, a sibling file, a receiver Rigor types as `Dynamic`) reports on correct code, which AGENTS.md weighs above a lost report.
- **Decline inside any block passed to a project method with an explicit `&blk`.** This is cheaper and needs no body read. It loses the report for `def m(&b) = b.call`, it still misses an anonymous `&`, `...` and implicit `super` forwarding, and it does not handle a name defined twice.

## Decision

Read by name. ADR-34's revision history already chose the false negative over the false positive twice for this rule (#1383's `main` singleton methods inside top-level blocks, #1697's opaque `Object` mixins), and `BlockCallTiming.project_defines_anywhere?` reads project tables by name for the same reason. This entry also sets a precedent for how the rule finds a block's callee.

## To undo

Remove `CheckRules::RebindingBlockCallees` and the `lexically_declined_toplevel_call?` arm that calls it in `check_rules.rb`, the `block_calls` accessor in `lexical_method_sites.rb`, the two spec files, the census rows, and the sentence in `docs/internal-spec/inference-engine.md`. To switch to receiver typing instead, keep the hand-off reading (`def_may_rebind?`) and replace `project_may_rebind?`'s by-name loop. Nothing else depends on it.
