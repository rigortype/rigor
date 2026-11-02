# Rigor starts reporting a Hash#[] miss on a local Hash the method built with no default

- **PR:** [#0](https://github.com/rigortype/rigor/pull/0)
- **Issue:** [#2555](https://github.com/rigortype/rigor/issues/2555)
- **Class:** open-choice
- **Precedent:** [#1278](https://github.com/rigortype/rigor/pull/1278)
- **Decided:** 2026-11-02

## Background

`Hash#[]` reads past core RBS's `%a{implicitly-returns-nil}`, so `h[k]` answers `V` and an unguarded miss never
reports (#2526). Honouring the annotation everywhere drew 25 false positives on `lib/` (`Hash.new(0)`,
`Hash.new { }`, `default_proc`, `Array#max`) and was rejected. Lever L3 of #2555 carves out the one receiver the
engine can vouch for: a local whose binding carries slice 1's `:synthesised` construction fact and no new
`:defaulted` fact. The brief settled the mechanism; three readings were left to the lane: what stamps `:defaulted`,
how it joins, and which receiver types the carve-out covers.

## Options and trade-offs

- What stamps `:defaulted`. Recognise only `Hash.new(x)` and `Hash.new { }`, or treat every constructor call
  with an argument or block as defaulted. The second (taken) also covers `Hash.new(capacity: n)`, which has no
  default in Ruby 4.0: it costs those reads their `nil`, and buys not having to tell a capacity keyword from a
  default value. After construction, `default=` and `default_proc=` stamp it, and so does `replace`, which copies
  the other hash's default (`{}.replace(Hash.new(0))[:k]` is `0`). A setter could instead drop the fact; stamping
  keeps slice 1's precise re-growth for the same local.
- How it joins. Intersection, the rule `:synthesised` uses, would let a plain arm and a defaulted arm join to a
  plain local, reporting a miss the defaulted arm answers. Union (taken), the rule `:grown` uses: either arm with a
  default keeps the read optimistic.
- Which receivers. The `Hash` nominal and a union of `Hash` nominals (the join of two literal arms). A `HashShape`
  keeps the shape tier's answer (a computed key on a closed shape already reads `V | nil`, per #1278). A gradual
  `V` (`Dynamic[top]`) is left alone: a `nil` beside it fires nothing. `KeyPresenceGuard` (#1703) now admits a
  `Hash` nominal so a `key?` guard keeps the read quiet.
- Partially gradual carriers. `Hash.new(0)` is `Hash[Dynamic[top], Integer]`; `keep_precise_parameters` restored the
  `Integer` over a `"s"` store and drew a false `undefined method 'upcase' for Integer`. On a synthesised binding
  such a Hash now re-grows through `MutationRejoin.widen_synthesised`, as a precise one does since slice 1.

## Decision

Take the options marked above. The precedent is #1278, which gave a closed shape's computed-key read its `nil`
because the shape is the whole key set; here the construction fact is the evidence that no default answers the
miss. `call.possible-nil-receiver` still fires only on a bare local receiver, so the chained `h[k].upcase` stays
quiet; widening the rule's receiver set is not part of this decision.

## To undo

Delete the `PlainHashMiss.applies?` guard in `RbsDispatch#record_optimistic_nil_free` and the
`ExpressionTyper#plain_hash_miss_type` call; the `:defaulted` stamps and the join rule then do nothing. Revert the
`partially_gradual_hash?` arm in `MutationRejoin.widen_nominal` to bring back the `Hash.new(0)` false positive.
