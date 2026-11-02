# A remover narrows only a local no seen holder can write, and a Symbol-key delete keeps a closed hash shape

- **PR:** [#2621](https://github.com/rigortype/rigor/pull/2621)
- **Issue:** [#2608](https://github.com/rigortype/rigor/issues/2608)
- **Class:** open-choice
- **Precedent:** [#2606](https://github.com/rigortype/rigor/pull/2606)
- **Decided:** 2026-11-02

## Background

#2608 asked removers (`compact!`, a literal-nil `delete`, nil-test `reject!` / `select!` blocks, a literal-key
`HashShape#delete`) to narrow the element type where Ruby guarantees it. Three readings were left open: what an alias
copy of the receiver reads after the call, which kinds of binding narrow, and what a closed hash shape becomes under a
literal-key `delete` (until now every `delete` erased a shape to a nominal).

## Options and trade-offs

- Writes that reach the object without going through the receiver's binding. A narrowing is a claim about the object,
  and any later write through another holder falsifies it; the narrowed reading then reports on correct code. The
  holders review found: an alias (`al = l`, `al = c ? l : []`, `al = l.push(1)`, `case l; in al`), a closure that runs
  later (`pr = proc { l << 1 }` before or after the filter), a container or a kept argument (`hh = { k: l }`,
  `Keep.new(l)`), and `send` / `instance_eval`. The options were full alias and capture tracking (#2335, not
  available), no narrowing at all, or narrowing behind a cheap conservative floor. Taken: a flow-insensitive scan per
  frame body (`RemoverHolderScan`) skips the narrowing for a local that is:
  - referenced inside a lambda or a block passed to anything but a catalogued iterator or `tap` / `then` /
    `yield_self`;
  - read anywhere inside the value of any write (variable, constant, index, attribute or operator write, a multiple
    assignment) or the subject of a `case`/`in`, `=>` or `in` pattern, with no attempt to tell a receiver-position read
    apart (`n = l.size` counts), together with the local that write or pattern binds unless its value is a fresh
    literal or `new` / `[]` on a constant;
  - read inside an Array element, a Hash key or value, a splat, or an argument of any call, `yield` or `super`, except
    as the receiver of a #2555 `ConstructionEscape::READERS` reader (the per-class union less `to_a` / `to_h` /
    `to_set`, which return self on another class), so `puts(l.size)` and `dump_type(l.dup)` keep it;
  - the receiver of a reflective call (`send`, `public_send`, `__send__`, `instance_eval`, `instance_exec`, `tap`,
    `then`, `yield_self`, `itself`, `method`, `define_singleton_method`);
  - or in a body that calls `binding`, `eval`, `local_variable_get` or `local_variable_set` on any receiver, or a
    receiverless `instance_variable_set`.
  Such a receiver keeps the reading it had before this change. What stays reachable is a holder the body never names
  in any of those positions: an object reached through global state (`ObjectSpace.each_object(Array) { |o| o << 1 }`),
  which needs alias tracking (#2335).
- The floor costs precision on correct code that copies, captures, stores or passes a collection and never writes
  through the other holder (`n = l.size; l.compact!` does not narrow). And narrowing a receiver an unseen holder can
  write loses the true positive that holder's later store causes, accepted because a missed report outranks a false
  one.
- Binding kinds: locals only (taken), or instance variables too. An instance variable's object is reachable from every
  method of the class and from any object it was handed to (`@b = @a` in `initialize`, `W.new(@a)`, `-> { @a << 1 }`,
  `self.add`, `z = add`), none of which one body's scan sees, so an ivar receiver never narrows. Class variables and
  globals are shared more widely still and keep today's reading.
- A closed shape under `delete(:k)`: erase it as before, or keep the shape without the key. Keeping it is exact for a
  closed shape and lets the shape's own rewrite rules keep working after the call (taken), for a Symbol key only:
  under `compare_by_identity` an equal String or a large Integer need not be the stored key. An open shape, a
  read-only key and a non-literal key keep the erasure.

## Decision

Narrow a local receiver only when the body scan finds no closure, write, pattern, container, argument, reflective
call or frame access that could hand it on, never an instance variable, and keep a closed shape minus a Symbol key a
literal `delete` names. The corpus A/B (`lib/`, haml, mail, kramdown, yard) moved no diagnostic and the `lib/` census
is unchanged. One #2606 control moved with it: the #1289 alias control now closes its literal with a `delete` of an
untyped key.

## To undo

Make `RemoverNarrowing.narrow_shape` answer `nil` to restore the erasure, or widen or narrow `RemoverHolderScan`'s
holder positions. Nothing else depends on them; alias tracking (#2335) would replace the scan.
