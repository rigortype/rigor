# An `each_with_object` memo floors when a reader's value is used or a mutator takes a splat, instead of modelling the store

- **PR:** [#2415](https://github.com/rigortype/rigor/pull/2415)
- **Issue:** [#2411](https://github.com/rigortype/rigor/issues/2411)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-26

## Background

#2415 makes `recv.each_with_object(memo) { |x, acc| … }` answer the memo as its block's stores leave it, wherever the
call is used as a value, so sig-gen stops proposing `-> {}` / `-> []`. The join reads only the stores it can see.
Round 3 of the review found two shapes where a store goes unseen, and the joined type then reports on correct code
that master leaves silent.

- A reader whose value is used hands out an element, and the block mutates that element: `h[x] = []; h[x] << "s"`,
  `h.fetch(x) << "s"`, `h.values.first.push("s")`, `v = h[:k]; v << "s"`, `h[:k][:n] = "s"`. The join kept
  `Hash[1, []]`, so `.fetch(1).first.upcase` reported a call on `nil`.
- A content or seed mutator given a splat or `**` argument (`h.store(*kv)`, `h.[]=(*args)`, `a.insert(0, *xs)`)
  stores pairs or elements the join, reading arguments by position, never sees.

## Options and trade-offs

- **Model the element mutation and the splat's contents.** This is the most precise option. It needs a per-element
  alias analysis for readers, and splat-expansion typing for every mutator's parameter list. Both are large, and each
  is a new place where an unseen store would become a false positive again.
- **Floor coarsely (taken).** A used reader's value floors the memo's values: a Hash keeps its key type and its value
  type becomes `Dynamic[top]`, and an Array becomes `Array[Dynamic[top]]`. A splat or `**` argument on a mutator floors
  the whole memo to its content floor. This is sound, small, and the same shape as the escape floors earlier rounds
  added (an alias, a call with a receiver, `send`).

## Decision

The user ruled the conservative fix in round 3 of #2415. What is lost:

- An element mutated through a reader no longer keeps its precise type. A memo also floors its values when a reader's
  value is used even if nothing mutates it, unless every value or element is of a class no method mutates (Integer,
  Float, Symbol, nil, true, false, Rational, Complex). That exemption keeps master's `m[k] = m[k] + 1` at
  `Hash[Symbol, 0 | Integer]`; a String or collection value floors.
- Every splat store floors, including `a.push(*xs)`, whose positional reading was sound.

Against master, no sig-gen row over `lib/` loses precision; the rows that lose precision against round 2 are listed in
the PR body. ADR-5's false-positive discipline is the rule that favours a wider type over a joined one that can be
wrong.

## To undo

Remove `memo_value_floor` and the `:values` reach in `StatementEvaluator#memo_scan_reach` / `memo_receiver_call_modelled?`
for the reader floor, and `memo_splat_arguments?` for the splat floor. The rows in `ewo_reader_elements` and
`ewo_splat_stores` in `spec/integration/fixtures/block_captured_writeback.rb` pin both. A precise model would replace
them, not merely remove them.
