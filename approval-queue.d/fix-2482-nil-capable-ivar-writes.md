# DirectIvarWrites drops a nil write that a later straight-line top-level write overwrites

- **PR:** [#2585](https://github.com/rigortype/rigor/pull/2585)
- **Issue:** [#2482](https://github.com/rigortype/rigor/issues/2482)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-01

## Background

`Inference::DirectIvarWrites` names the instance variables a self-call's callee may leave `nil`. A named
variable keeps the #2039 statement reset unmarked, so a guarded read after the call keeps its
`call.possible-nil-receiver` report. Until now the census ignored write order. #2482 taught it more `nil`
spellings (`a || nil`, `@a, @tag = 1`, and others). Review then found that this widened a false positive.
In `@tag = @parts.first || nil; @tag = "x"; yield if block_given?`, the variable is `"x"` when the callee returns,
yet the read now reported. Base already reported the same shape for a plain `@tag = nil; @tag = "x"`. No order
rule existed to reuse.

## Options and trade-offs

- Land without an order rule and file the false positive. This costs a widened false positive in the PR that
  introduced it.
- A straight-line last-write rule over the top-level statements of the callee body. It only removes `nil`
  writes, so it can only remove reports. It gives up the drop wherever control flow is involved.
- A flow-sensitive rule through branches and loops. It would win more precision, but it is far more code and
  needs proofs that this module does not have.

## Decision

The coordinator ruled for the straight-line rule. Among the top-level statements of a `def` body (seen through
a lone parenthesised group), in source order, a `nil` write to `@x` is dropped when a later top-level
statement writes `@x` unconditionally with a value the module does not count as `nil`. A plain `@x = v`,
`@x ||= v` and a multiple-assignment target count; `@x &&= v` does not. A multiple assignment with a rest
target is not an overwrite, since the census declines it.

Nothing is dropped across a statement that may leave the method first: a `return`, `break`, `next`,
`redo`, `retry`, `yield` or `super`, a call with a block or `&` argument, or a `raise` / `fail` / `throw`
/ `exit` / `abort` call. A statement that may leave keeps its own `nil` writes. A write nested in a
conditional, a loop, a block or an `&&` / `||` is not unconditional. A body with a `rescue` or `ensure` is
read whole, as before. The rule is conservative by construction. It also quiets base's
`@tag = nil; @tag = "x"`, `@a, @tag = 1, nil; @tag = "x"` and `@tag = nil; @tag ||= "d"`.

## To undo

Replace `read_body` in `lib/rigor/inference/direct_ivar_writes.rb` with the former single `collect` over the
body. Then delete the two order examples in `spec/rigor/inference/direct_ivar_writes_spec.rb` and the
`OverwrittenWrites` class and `r_return` / `probe_return` rows in the ivar guard fixtures, which moves the
`statement_call_rewriters.rb` quiet count back from 24 to 20. Widening the rule to branches is future work
and would build on this one.
