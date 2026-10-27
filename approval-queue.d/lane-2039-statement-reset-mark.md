# A self-call that writes nil only through reflection or metaprogramming no longer makes a guarded ivar read report

- **PR:** [#2469](https://github.com/rigortype/rigor/pull/2469)
- **Issue:** [#2039](https://github.com/rigortype/rigor/issues/2039)
- **Class:** open-choice
- **Precedent:** [ADR-58](../docs/adr/58-ivar-field-typing.md)
- **Decided:** 2026-10-28

## Background

After `return unless @tag`, an implicit-self or `self.` statement call widens `@tag` back over its class-ivar seed.
When the seed holds `nil` because some other method writes `@tag = nil`, the read after the call used to report
`call.possible-nil-receiver` even when the call (`items.any?`, `respond_to?(:x)`) never touched `@tag`. #2039 marks
the widened binding with the ADR-58 declaration mark, so that `nil` no longer fires, whenever the #1596 write proof
cannot clear the call. The proof declines for many reasons unrelated to the variable: a `yield` or a call on a
parameter in the callee, or `include Comparable`, `method_missing` or a reopening in another file on the class. The
first version of the PR therefore also silenced callees that visibly assign `@tag = nil`, where Ruby raises.

## Options and trade-offs

- Mark only when the proof declines (first version): fixes the false positive, but loses the report for any
  nil-writing callee the proof cannot read, including ones whose `@tag = nil` is plain to see.
- Mark when the proof declines and the callee's body, followed through its own self-calls, shows no write node
  assigning the variable a value that may be `nil` (`DirectIvarWrites`): keeps those reports, as on `master`.
  Callees that write `nil` through no write node still lose the report: a `define_method` body, an `attr_writer`
  (`self.tag = nil`), `instance_variable_set`, `send` / `public_send`, and `method_missing`.
- Do not mark at statement position at all: keeps every report and every false positive.

## Decision

The second option. It is the coordinator's round-2 ruling on the PR. The remaining loss is the one ADR-58 WD1 and
#1963 / #2036 already accept for a declaration-sourced `nil`: under ADR-5, a guarded read past a call that writes
the variable through metaprogramming is assumed to keep the program's invariant.

## To undo

Remove the `direct_writes:` argument and `DirectIvarWrites` to return to the first version, or pass `mark: false`
for self-calls in `StatementEvaluator#invalidate_ivars_for_intervening_call` to return to `master`'s behaviour.
The `statement_calls.rb` and `statement_call_writers.rb` fixtures pin the current split.
