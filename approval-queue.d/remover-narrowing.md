# A remover narrows only a receiver no seen holder can write, locals and instance variables, and a Symbol-key delete keeps a closed hash shape

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

- Writes that reach the object without going through the receiver's binding. A narrowing is a claim about the object
  that a later write through another holder falsifies, and the narrowed reading then reports on correct code: a write
  through an alias (`al = l; l.select! { |x| x.is_a?(String) }; al << 1; l.last.even?`), through a closure that runs
  later (`pr = proc { l << 1 }` before or after the filter, then `pr.call`), or through `send` / `instance_eval`.
  The options were full alias and capture tracking (#2335, not available), no narrowing at all, or narrowing with a
  cheap floor. Taken: a flow-insensitive scan per frame body (`RemoverHolderScan`) skips the narrowing for a binding
  referenced inside a lambda or a block passed to anything but a catalogued iterator or `tap` / `then` /
  `yield_self`, for both names of a copy into a variable (`al = l`, `@x = l`, a multiple assignment), for the
  receiver of a reflective call (`send`, `public_send`, `__send__`, `instance_eval`, `instance_exec`, `tap`, `then`,
  `yield_self`, `itself`, `method`, `define_singleton_method`), and for every binding of a body that calls
  `binding`, `eval`, `local_variable_set` or `instance_variable_set`. Such a receiver keeps the reading it had
  before this change. What the scan does not see stays a known false positive: a holder built from a container or an
  argument (`hh = { k: l }; ...; hh[:k] << 1`, `Keep.new(l)` keeping it in an ivar), until #2335.
- The floor costs precision on correct code that copies or captures a collection and never writes through the copy,
  and narrowing a receiver some unseen holder can write loses the true positive that holder's later store would
  cause (accepted: the narrowed reading is what the code states, and a missed report outranks a false one).
- Binding kinds: locals only, locals and instance variables, or every kind `MutationWidening` widens (class variables,
  globals). A guard already narrows a local or an ivar, and the intervening-call reset (B2.2) restores an ivar
  narrowed below its class seed, so locals and ivars match the guard rule (taken). Class variables and globals are
  shared more widely and keep today's reading.
- A closed shape under `delete(:k)`: erase it as before, or keep the shape without the key. Keeping it is exact for a
  closed shape and lets the shape's own rewrite rules keep working after the call (taken), for a Symbol key only:
  under `compare_by_identity` an equal String or a large Integer need not be the stored key. An open shape, a
  read-only key and a non-literal key keep the erasure.

## Decision

Narrow a local or instance-variable receiver only when the body scan finds no closure, copy, reflective call or frame
access that could write it, and keep a closed shape minus a Symbol key a literal `delete` names. The writes through a
container or an argument the scan does not see remain a known false positive (PR body, "Known limits"). The corpus
A/B (`lib/`, haml, mail, kramdown, yard) moved no diagnostic and the `lib/` census is unchanged. Two #2606 controls
moved with it: the #1289 alias control now closes its literal with a `delete` of an untyped key, and a closed
`plain.delete(:a)` reads `{}`.

## To undo

Restrict `RemoverNarrowing::NARROWING_RECEIVERS` to `LocalVariableReadNode` for locals only, make
`RemoverNarrowing.narrow_shape` answer `nil` to restore the erasure, or widen or narrow `RemoverHolderScan`'s holder
list. Nothing else depends on them; alias tracking (#2335) would replace the scan.
