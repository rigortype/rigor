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

The same PR also declines a narrowing, on the coordinator's ruling of 2026-11-19 (review round 1 of [#3347](https://github.com/rigortype/rigor/pull/3347)), recorded here because it is a narrowing that checks less. An emptiness guard no longer narrows a local to `non-empty-array[T]` when a closure that may run later, anywhere in the same method, class or file body, can empty it (`f = -> { xs.clear }; return if xs.empty?; f.call`). The alternatives were to floor such locals at every call that may run the closure, which is unbounded once the closure is handed on, and to leave the shape as a known limit, which #3339 (`pop` on a non-empty array answers `T`) cannot land beside. Precedent: `control-flow-analysis.md` § "Closure captures" ("facts about locals it can write become unstable after the escape point") and the remover narrowing's holder rule from [#2608](https://github.com/rigortype/rigor/issues/2608), which does not narrow a local a later-running closure references. It is bounded to closures that can empty the local: one that only reads it or appends to it, a block that ran at once, and the closure holding the guard do not count. To undo it, delete the `DeferredMutation.empties?` line in `Narrowing::PresencePredicates.analyse_array_emptiness_predicate` and `lib/rigor/inference/deferred_mutation.rb`; the "closure made before the guard" examples then fail.

What the PR leaves stale, the same list its specs and body carry. The emptiness fact, and a literal's shape, are dropped where the engine sees the mutation or the escape; a mutation through an alias the engine does not link can leave them stale. Not covered:

- a closure that empties the object through a holder made outside it (`ys = xs; f = -> { ys.clear }`, an element of a container holding it, an instance variable holding it), through an alias made inside it, or through a callee it passes the local to;
- a closure that holds the guard and calls itself, so re-enters past the guard: the exemption for the guard's own closure assumes it does not;
- an instance variable in a method outside a class (`self` is `main`, which has no class seed for the reset to read), one mutated through a local alias (`q = @xs; q.clear`) or by a callee on another receiver (`Util.drain(@xs)`), and one mutated in place in a loop body or in a `begin` body before its `rescue`; the later-running-closure rule covers locals only;
- an emptier behind a call that hands the receiver back (`-> { xs.tap(&:clear) }`, `xs.instance_eval { tap(&:clear) }`);
- a `yield` of a literal holding the local (`yield [xs]`, `yield(*[xs])`, `yield({ a: xs })`);
- a `Method` object kept in a variable and called later (`m = xs.method(:clear); m.call`), and a block passed as a value over a literal Array of locals (`[xs].each(&blk)`);
- any of the opaque forms written as an operand of another call (`puts(yield(xs))`, `log(xs.send(name))`);
- a literal assigned to the local after an emptying closure is made, and a capture a `Kernel#loop` body rebinds.
