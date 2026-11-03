# A callee's direct-write floor reached by over-approximation floors a String gradually, and a def read as written keeps the nominal String

- **PR:** [#2623](https://github.com/rigortype/rigor/pull/2623)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** [#2611](https://github.com/rigortype/rigor/pull/2611)
- **Decided:** 2026-11-03

## Background

The callee mutation floor (ADR-127) replaces a caller's literal fact with its carrier when a callee may write the argument. It has three channels in `floor_callee_escaped_args_for_call` (statement_evaluator.rb):

- the callee's own census of the parameters it writes directly;
- the splat channel (#2611);
- the block channel, for parameters a block in the callee writes (`UnknownStoreWidening.callee_block_floor`).

#2611 made the whole splat channel gradual: a `String` carrier floors to `Dynamic[String]`, both for type-matched locals and for the elements in the array's own type. Before #2623, the direct-write channel always floored a `String` to the nominal `String`.

#2623's review showed that this adds findings once that channel over-approximates. Take `mode = "r"`, passed to a callee that may not run or does not write, then to a parameter typed `("r" | "w")`. The floored `String` fails that parameter (`call.argument-type-mismatch`), although Ruby keeps `"r"`. The channel over-approximates in these cases:

- `FLOOR_EVERY`, the new owner for a top-level def that may not be the one that runs;
- `FLOOR_ALL`, which covers an inherited def, a def on a module or on a class with subclasses, a subclassing-opaque project, and the `method_missing` reading;
- a union of same-named instance defs (the #2607 local-receiver path and a top-level def's hand-off);
- the `[singleton, instance]` pair;
- any chain that reaches one of these through a hand-off.

Base already reported this false positive for an inherited non-writing def and for the #2607 local-receiver union. #2623 made the shape reachable far more often.

## Options and trade-offs

- **Nominal `String` everywhere (base).** Precise for a callee that really writes. It adds a false positive whenever the floor over-approximates, which breaks ADR-5.
- **`Dynamic[String]` everywhere**, as #2611 did for the splat channel. It closes the false positives, but it loses true positives where the callee is known and writes. After `def app(s) = s << "x"; app(m)`, a later `Integer` parameter or an undefined method on `m` no longer reports, although Ruby raises.
- **Split by certainty** (taken). Floor gradually when the floor is an over-approximation, and nominally when the def is read as written and writes the argument. `StatementEvaluator#over_approximating_callee?` holds when any of these is true:
  - the owner is `FLOOR_ALL` or `FLOOR_EVERY`;
  - the call resolves to more than one callee;
  - the callee hands a parameter on, through any hop, to such an owner or to more than one candidate. `CalleeMutationChain::Edge#approx` records this; it is set for a `UnionCallees` answer or for more than one callee.

  A union keeps each candidate's own census, so which arguments floor is unchanged. Only how far a String floors changes.

## Decision

Split by certainty, for the direct-write channel. It keeps every floor that #2607 and #2623 added and adds no finding: an over-approximated floor can only forget a fact. It keeps the true positives that exist only because a known callee writes, and it fixes the two false positives base already had on that channel. The cost is a hop walk, bounded by `CalleeMutationChain::MAX_NODES` and run only for String-carrier floors. Its own allocation cost was not measured apart from the rest of #2623, whose A/B reads +0.13%.

The splat channel stays gradual throughout, per #2611. It does not need to split, because an element there is matched by type, which is always a guess.

The block channel takes the same split. Before [#2646](https://github.com/rigortype/rigor/pull/2646), `callee_block_floor` floored a String to the nominal `String` whatever the owner, so a block-only writer reached through the #2607 union reported `got String` on correct code ([#2638](https://github.com/rigortype/rigor/issues/2638)). Now both channels go through `StatementEvaluator#callee_gradual_floor`. Under `FLOOR_ALL` and `FLOOR_EVERY` the block channel is never reached on its own, because the direct-write channel has already floored the String gradually.

The direct-write channel floors Hash and Array carriers to `Hash[untyped, untyped]` and `Array[untyped]`, which no record or tuple parameter rejects. The block and Set channels widen a container's literal elements the same way now (#2647): an element the unknown store widens reads `Dynamic[String]` (or `Dynamic[Integer]`, a Hash key's `Dynamic[Symbol]`), not `Dynamic[top] | String`, for a union and for a single def read as written alike, because the stored value is never shown at the call and the nominal class would fail a literal-typed parameter on correct code. The split of #2623 does not apply: it rests on a single def showing its stored value, and the block and Set channels never see that value (`unknown_arguments` is `untyped`). Keeping the literal beside `Dynamic[top]` (`"r" | Dynamic[top]`) would instead report a false positive on an overwrite writer, so the element is gradual for every owner. The cost is a lost true positive on an element read back out of a container a callee writes, for a single def and for a union owner alike, since the function does not look at the owner: a parameter the element's class fails, not only a literal-typed one (`def poke(a) = 2.times { a << "w" }; a = ["r"]; poke(a); Sink.new.num(a.first)` reported `got Dynamic[top] | String` and is silent), the Hash form (`Sink.new.num(h[:j])`), and an inferred class-level `Array[Integer]` passed to a `String` parameter. Any carrier the floor learns must answer the same question: does its floored type reject a value the callee never changed?

`docs/internal-spec/inference-engine.md` carries the normative sentence in the #2104/#2515 bullet.

## To undo

The rule lives in the String arm of `callee_content_floor` (statement_evaluator.rb):

- For the nominal reading, return it to `content_floor_for` alone.
- For the gradual reading, make it always apply `gradual_floor`.
- In either case, remove `over_approximating_callee?`, `Edge#approx`, `approximate_hand_off?` and `UnionCallees`.

`spec/integration/callee_toplevel_floor_spec.rb` pins both sides. The parent describe is "a floored String argument stays usable where a literal type is expected". Within it, "a def read as written that writes the String keeps the precise floor" pins the nominal side, and "a union resolution floors the String gradually" pins the union side.
