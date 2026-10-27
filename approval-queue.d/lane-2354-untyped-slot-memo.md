# A value-position index `||=` widens unless its receiver is a local the current body binds

- **PR:** [#2435](https://github.com/rigortype/rigor/pull/2435)
- **Issue:** [#2354](https://github.com/rigortype/rigor/issues/2354)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-27

## Background

#2351 widened a memoizing `h[k] ||= v` (slot read wholly `Dynamic`) only when the receiver's type held a `Dynamic` /
`Top`. An instance variable seeded `{}` in another method, a parameter declared `Hash[Symbol, untyped]`, and the inner
`||=` of `((h[a] ||= {})[b] ||= 1)` all have tracked types, so they still read the fresh literal and reported
`call.undefined-method` on `nil` or `1` for code that runs. A rule keyed on the slot type alone was withdrawn in
#2351 because it broke `pool = {}; %w[a b].find { |s| (pool[s] ||= s) == "b" }`. The coordinator settled that the
receiver's origin decides the reading.

## Options and trade-offs

- Key on the receiver expression: a local the current body binds keeps the literal, and anything else widens. This
  fixes all six spellings and keeps the `pool` fold. The cost is that a nest rooted at a body-local literal,
  `def m(a, b); h = {}; ((h[a] ||= {})[b] ||= 1).upcase; end`, goes silent. It is a true positive today, since the
  call raises NoMethodError at runtime. Its inner receiver is an expression, and widening it is what fixes the
  parameter-rooted nest. A local any parameter of the enclosing method names widens too, whatever the body writes
  (review round 2), so `def m(h, k); h = {}; (h[k] ||= 1).upcase; end` also goes silent though it raises at
  runtime. A name-only body test kept the literal for `h = h.dup if f`, a later `h = {}` or a block parameter
  shadowing `h`, all of which run fine on a caller's table. The test is by name, so a block parameter or block-local
  that shadows a method parameter's name widens inside the block too: `ys.each { |h| (h[k] ||= 1).upcase }` and
  `xs.map { |x; h| h = {}; (h[x] ||= 1).upcase }` raise on `1` at runtime and are silent. Both are rare. Block parameters, pattern binds, ivar aliases
  (`c = @cache`) and `define_method`-captured locals keep the literal reading; the coordinator files those.
- Carry the outer `||=`'s widened value as `Dynamic[...]` so that the type test rejects it. This was not needed
  once the receiver test covers expressions. It would also reach every local bound to such a value.
- The lane also exempted an object fresh at every run (`Hash.new[k] ||= v`, `RepeatedOrWrites.fresh_object?`) from
  the widening. That keeps the existing `block_return_scope_threading_spec.rb` control
  (`(Hash.new[:first] ||= e) == 2` reports `flow.always-truthy-condition`).

## Decision

Receiver-origin test with the parameter rule and the fresh-object exemption. ADR-5 ranks the false positives on
running memo code above the true positives lost. The trade-offs are pinned as `ACCEPTED TRADE-OFF` examples in
`spec/rigor/inference/index_or_write_memo_value_spec.rb`.

## To undo

Remove `body_bound_memo_receiver?` from `StatementEvaluator#tracked_memo_receiver?`; the spec examples for #2354 then
fail. Restoring the nested true positive alone would need the inner receiver's root to be traced through the
parenthesised `||=` to a body-bound local.
