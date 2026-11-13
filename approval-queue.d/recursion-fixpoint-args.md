# A recursion summary answers `Dynamic[top]` for a re-entry its frame does not cover, instead of widening the frame's parameters

- **PR:** [#3183](https://github.com/rigortype/rigor/pull/3183)
- **Issue:** [#3162](https://github.com/rigortype/rigor/issues/3162)
- **Class:** open-choice
- **Precedent:** [#3158](https://github.com/rigortype/rigor/pull/3158)
- **Decided:** 2026-11-13

## Background

A recursive method's return summary was computed with the parameter bindings of the outer call
alone, and an in-cycle call read it as its own return whatever it passed. `def acc(n, k) = n <= 0 ?
k : acc(n - 1, k + 1)` called as `acc(rand(10), 1)` answered `1`, and `acc(...) == 5` was reported
as always false. The issue offers two fixes (widen the changed parameters in the fixpoint frame, or
join the summary with the widened retry) and the lane brief preferred the first with #3158's
syntactic scan, allowing another design if it was clearly sound and bounded. Which of them to
build was left to the lane.

## Options and trade-offs

- **Bind every parameter the scan calls rebound `Dynamic[top]` in the fixpoint frame** (the brief's
  preference). Small. The answer for `acc` is `Dynamic[top]`. A frame typed with `Dynamic[top]`
  parameters takes every branch of the body, so the summary gains members the outer call cannot
  return, and every caller reads them; it also inherits the scan's limits (a parameter rebound
  through another method, a call the scan cannot read).
- **Join what the re-entries pass into the frame's parameters and iterate.** Built first on this
  branch. It is the most precise (`acc` is `Integer`), but `tool/engine_alloc_ab.rb` measured
  +14.93% allocations over `lib`, and the widened frame produced four new
  `call.argument-type-mismatch` reports in `lib/rigor/type/combinator.rb` (`erase_facets`, whose
  summary gained `Interface` from a frame the reported call never reaches). Fixing that needs one
  more evaluation with the outer bindings on top of the cost.
- **Leave the frame as the outer call built it, and let a re-entry read the summary only when the
  frame's bindings cover its own; one that is not covered answers `Dynamic[top]`.** No parameter
  is widened, so the summary never gains a member the outer call cannot produce, and the only new
  thing in an answer is `Dynamic[top]`. The answer for `acc` is `1 | Dynamic[top]`. It costs one
  more body evaluation, only for a recursion that has such a re-entry.

## Decision

The third. ADR-5 and the false-positive rule in `AGENTS.md` weigh a wrong report above a lost
type, and this is the one option that cannot add a member to an answer. It is sound because the
summary is the return of the frame's body under the frame's bindings, which is the re-entry's
return exactly when those bindings include the re-entry's; it is bounded because the switch to
the floor happens once per fixpoint. It follows #3158 in what it gives up: that PR binds
`Dynamic[top]` where the recursion changes a slot, and this one answers `Dynamic[top]` where it
does.

Two smaller choices came with it. The cover test reads the bindings the re-entry was built with,
not the call's syntax, so an assigned parameter, a call inside a block and a mutual pair are
judged by what they pass; the scan is read only for a re-entry through a call-site `*splat`,
whose binder has no positional correspondence. And the first frame with an unpinned argument
under a constant-argument unroll owns its own summary, which keeps #3158's
`positional_before_rest(3, 1)` row at `:done`.

One existing example changed: `callee_next_sink_leak_spec`'s first type is
`[1 | [:sym | Dynamic[top]]]` (was `[1 | Dynamic[top]]`); the inner array is `f(:sym)`'s own
return. No row of `recursive_keyword_parity.rb` or of the ADR-55 fixtures moved.

## To undo

Remove the cover test in `consult_summary` and the floor switch in
`fixpoint_user_method_return` (`lib/rigor/inference/expression_typer.rb`), and take the second
option with a final evaluation under the outer bindings if the precision is wanted: #3162's rows
have to stay sound. The second option is recoverable from this PR's first description of it in
the entry above; nothing else reads the summary entry's new fields.
