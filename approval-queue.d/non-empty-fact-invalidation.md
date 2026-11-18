# Give a variable handed to unread code the literal-shape floor, not the bare-carrier floor

- **PR:** [#3347](https://github.com/rigortype/rigor/pull/3347)
- **Issue:** [#3340](https://github.com/rigortype/rigor/issues/3340)
- **Class:** open-choice
- **Precedent:** [#2677](https://github.com/rigortype/rigor/pull/2677)
- **Decided:** 2026-11-19

## Background

#3340 lists forms that hand a collection to code the engine cannot read: `yield xs`, `xs.send(name)` with a computed name, `xs.instance_eval { clear }`, and `xs.method(name).call`. After each, the binding kept a fact the unread code can falsify (`non-empty-array[T]` past an emptiness guard, a literal's shape), so `xs.size == 0` folded on correct code. The issue says the fact must go and does not say how much else of the binding goes with it. The engine has two floors for "unread code may have written this object", and they differ on a binding that is already a nominal.

## Options and trade-offs

- The bare-carrier floor (`content_floor_for`, what `pr.call(xs)` and a helper that mutates its parameter apply under `FLOOR_EVERY`): every Array, Hash and String local becomes `Array[untyped]`, `Hash[untyped, untyped]` or `String`. It is the floor of the nearest neighbour, `blk.call(xs)`, and it covers a block that stores a value of another class. It would erase the element type of every collection local a method passes to `yield`, which is far more common than a proc call with a collection argument.
- The literal-shape floor (`AliasMutationFloor.callee_floor`, #2335): one unknown store, applied only to a `Tuple`, a `HashShape`, a literal String or Set, or an empty-witness refinement. Those become their nominal with a gradual element; a nominal such as `Array[String]` is left as it is. It drops every fact #3340 names and nothing else. It leaves `xs = File.readlines(f); yield xs` reading `Array[String]` although the block may have pushed an Integer, which is the claim #2335 already leaves standing for a local another holder may write.
- Decline the emptiness narrowing for a local that is ever handed on. It needs no floor at the call, and loses the fact in code that never mutates.

## Decision

The second option, for `yield`, a computed `send`, `instance_eval` / `instance_exec` and a computed `Method` object. #2677 chose the same floor for the same reason, in `AliasMutationFloor.floor_after_written_local`, whose comments record: "a nominal `Array[String]` is a claim the named path's unknown store leaves as it is too", after flooring every local at every opaque hand-off "cost precision across the corpus for no finding". The precedent fits closely: both floor a local whose object unread code may have written, and this change calls the same function. On this repository's `lib` no expression moved to `Dynamic` (238,005 precise before and after), and no diagnostic moved on `lib` or on seventeen survey projects.

## To undo

In `Inference::OpaqueMutation.floor_reads`, replace `AliasMutationFloor.callee_floor` with `UnknownStoreWidening.content_floor`; the two `.floor_after_call` examples in `spec/rigor/inference/opaque_mutation_spec.rb` state the current answers and would change. `yield xs` and `blk.call(xs)` then floor alike. Nothing else depends on the choice.
