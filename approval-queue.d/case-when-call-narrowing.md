# Forget a global case subject's binding after a calling when test, and narrow a variable a case subject writes

- **PR:** [#2260](https://github.com/rigortype/rigor/pull/2260)
- **Issue:** [#2211](https://github.com/rigortype/rigor/issues/2211)
- **Class:** open-choice
- **Precedent:** [#2202](https://github.com/rigortype/rigor/pull/2202)
- **Decided:** 2026-10-21

## Background

#2211 asks that a call in a `when` test forget a global subject's narrowing, as the scope index's walk does, before a value-position `case` is evaluated by the recording evaluator. Two choices were left open. The global in the issue's fixture holds `nil` from a write, not from a narrowing, and the statement walk keeps a global's binding past an ordinary call (`$g = nil; reset!; $g + 1` still reports), so "forget the narrowing" alone did not clear the report. And evaluating a value-position `case` imported a statement-form false positive the walk had hidden: `case (x = v) when String then x.upcase end` did not narrow `x`.

## Options and trade-offs

- **Forget the global's binding, not only its narrowing, from a calling test on (taken).** Matches the walk's `forget_called_subject` and the issue's fixture; inside a `case` it reads a global more loosely than the same global after a call in straight-line code, which still keeps its binding (a broader policy the coordinator is filing separately).
- **Forget only the narrowing.** Leaves the issue's report in place.
- **Narrow a variable a `case` subject writes (taken),** in `Narrowing.case_when_scopes`, so both positions are right; it also silences two false positives on herb. The alternative, declining to evaluate a value-position `case` whose subject writes, would keep the statement form's false positive and the value form's imprecise `Dynamic[top]`.

## Decision

Both taken options read less where the analysis cannot prove more or prove what Ruby does, the AGENTS.md false-positive rule; #2202 set the shape of matching the value position to the statement form.

## To undo

Drop `forget_called_global_subject` from `StatementEvaluator#subject_when_scopes`, and `case_subject_slot` from `Narrowing.case_when_scopes` (back to `receiver_slot`); update `spec/integration/fixtures/case_when_value_position.rb` and its snapshot.
