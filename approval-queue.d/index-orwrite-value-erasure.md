# Value-position index `||=` widening is keyed on an untracked receiver, not on the slot type

- **PR:** [#2351](https://github.com/rigortype/rigor/pull/2351)
- **Issue:** [#2292](https://github.com/rigortype/rigor/issues/2292)
- **Class:** open-choice
- **Precedent:** [#2288](https://github.com/rigortype/rigor/pull/2288)
- **Decided:** 2026-10-26

## Background

A value-position `h[k] ||= v` whose slot read is wholly `Dynamic` read as the fresh rvalue, so on an untyped `h`
`(h[k] ||= {})[:name].upcase` reported a call on `nil` and `(h[k] ||= 1).upcase` one on `1`. The brief asked to
erase the literal whenever the slot was wholly `Dynamic`. A slot-keyed rule also reached block folds over a captured
`pool = {}`, whose in-place widening reads `Hash[Dynamic[top], Dynamic[top]]`, the same type #2288's local bind gives
`x = (h[k] ||= {})`. The coordinator delegated the choice to this lane.

## Options and trade-offs

- Key on the slot type: fixes every spelling, but `%w[a b].find { |s| (pool[s] ||= s) == "b" }; f.upcase` reported
  `call.possible-nil-receiver` (runtime `"b"`, `block_return_scope_threading_spec.rb` :982 and :994), and about
  twenty block-fold and straight-line examples lost their precise answers.
- Key on the receiver having an untracked (`Dynamic` / `Top`) constituent, #544's `fully_tracked_receiver_type?`:
  fixes the issue's spellings on an untyped parameter or ivar and keeps the block folds. One level below a local
  #2288 erased, `(x[:j] ||= 1).upcase` still reads `1`.
- Track a receiver's origin (memo-bound vs widened literal): beyond the issue.

## Decision

The second option. False positives outrank precision, and the first option added two. The residual is pinned by the
`RESIDUAL` example in `spec/rigor/inference/index_or_write_memo_value_spec.rb`, so a later change sees it.

## To undo

Drop the `fully_tracked_receiver_type?` early return in `StatementEvaluator#index_compound_write_value` to key on the
slot type, and adjudicate the block-fold examples listed above; the `RESIDUAL` example then flips.
