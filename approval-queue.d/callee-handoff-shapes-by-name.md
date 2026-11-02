# A hand-off on any receiver the callee cannot type resolves by name

- **PR:** [#2649](https://github.com/rigortype/rigor/pull/2649)
- **Issue:** [#2336](https://github.com/rigortype/rigor/issues/2336)
- **Class:** open-choice
- **Precedent:** [#2607](https://github.com/rigortype/rigor/pull/2607)
- **Decided:** 2026-11-03

## Background

Inside a callee, a hand-off on a constant, a local or an ivar receiver was followed; one on any other receiver
(`new.store(h)`, `instance.helper(h)`, `itself.poke(h)`, `self.class.helper(h)`, `@w.send(:poke, h)`) was not, and
the caller's literal stayed narrow after a callee that wrote it.

## Options and trade-offs

- Spell out each receiver (`new`, `instance`, `itself`, `self.class`): exact for those, and every other spelling
  stays a false positive.
- Type the receiver inside the callee: a call result's type is a return-type inference the hand-off walk does not
  run, and it would not be a function of the graph node alone.
- Resolve by name, as #2607 resolves an untyped local and #2595 an ivar: every user instance def of the name, under
  that rule's floor-all owners and cap. A lost true positive when an unrelated same-named def writes.

## Decision

By name, for every explicit receiver other than a constant form and a local, which keep their typed resolution.
`itself` resolves as a self-call and `self.class` on the class object `self` types as, since both are exact. A
literal `send` / `public_send` / `__send__` on any receiver resolves as its target, one argument ahead.

## To undo

Restore `hand_off_receiver?` to its local, ivar and constant forms and drop `named_hand_off_callees`,
`itself_receiver?` and `class_of_self?`. The "a receiver the callee's body does not type" and "a send hand-off" rows
of `callee_hand_off_shapes_spec.rb` then fail.
