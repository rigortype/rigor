# A hand-off the callee floor cannot resolve floors every argument it passes

- **PR:** [#2649](https://github.com/rigortype/rigor/pull/2649)
- **Issue:** [#2336](https://github.com/rigortype/rigor/issues/2336)
- **Class:** open-choice
- **Precedent:** [#2570](https://github.com/rigortype/rigor/pull/2570)
- **Decided:** 2026-11-03

## Background

The callee mutation floor widens a caller's literal argument when a project def may write it. Several hand-offs
reached code the floor has no def node for: `yield h`, `blk.call(h)`, `method(:poke).call(h)`, a lambda's `call`,
`send(name, h)` with a computed name, and a method a `define_method`, `define_singleton_method` or `alias_method`
call defines. Each left the literal narrow, so correct code reported a false `flow.always-truthy-condition`. The
issue left open what such a hand-off should read as.

## Options and trade-offs

- Follow nothing (the status quo): every such shape keeps its false positive.
- Resolve each target exactly: read the block the caller passes to a `yield`, track which Proc or Method a local
  holds, read a `define_method` block as a def. Exact, but each is its own inference, and a computed `send` name
  cannot be resolved at all.
- Read the handed argument as written, as #2570 reads an inherited def and a `method_missing` (floor-all): one
  rule for every shape, at the cost of a lost true positive when the unseen code only reads.

## Decision

The floor. Inside a callee, the write census counts a parameter (or an alias of one) passed to `yield`, to `call` on
an explicit receiver, to `instance_exec` / `class_exec` / `module_exec` on any receiver, to a non-literal `send`, or to any call
inside a `define_method` block, and a parameter that is the receiver of `method`. At a call site, such a call that
resolves to no def floors every local argument (`OPAQUE_CALLEES`). A call no def answers floors every argument when
an ownerless definition row gives the name a body: a `define_method`, `define_singleton_method` or `alias_method`
call of the literal name, and also any def in a block or outside every class, so a top-level def counts. The row is
not tied to the receiver's class: a top-level `def store` floors `Bag.new.store(:k, acc)` on a project `Bag < Hash`,
whose inherited core method answers the call, and loses that true positive. A name RBS declares on `Object` (`Class`
on the singleton side) or on the class itself is left out, since that method answers first. The `instance_eval` / `Class.new` block guards of #2104 stay: a
self-call there is not a call on the method's receiver.

The spec that pinned a non-literal `send` as unfollowed (`callee_singleton_send_floor_spec.rb`) now expects the
floor; Ruby prints "X" there, so the old expectation was the false positive.

## To undo

Drop `opaque_arguments` from `CalleeWriteCensus`, `OPAQUE_CALLEES` and `ownerless_body?` from
`StatementEvaluator`, and `Scope#ownerless_definition?`. The rows of `callee_hand_off_shapes_spec.rb` under "a
hand-off to code no def shows" and "a method body no def table holds" then fail.
