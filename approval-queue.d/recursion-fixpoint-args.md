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
  is widened, so the frame is not typed for arguments the outer call never passed. The answer for
  `acc` is `1 | Dynamic[top]`. It costs one
  more body evaluation, only for a recursion that has such a re-entry.

## Decision

The third. ADR-5 and the false-positive rule in `AGENTS.md` weigh a wrong report above a lost
type, and this is the one option that does not type the frame for arguments the outer call never
passed. An answer can still gain a member beside its `Dynamic[top]`: a floored call's value flows
on through the body (`def ksp(k:) = k > 1 ? k : ksp(k: k + 1)` called with `k: 1` can list a `2`
Ruby never returns from that call). It is sound because the
summary is the return of the frame's body under the frame's bindings, which is the re-entry's
return exactly when those bindings include the re-entry's; it is bounded because the switch to
the floor happens once per fixpoint. A value-keyed re-entry and the re-entry's block are held
against the frame like any argument (review round 1); `&b` is the frame's block only while the
body neither assigns `b` nor declares it in a block of its own (round 2). It follows #3158 in what it gives up: that PR binds
`Dynamic[top]` where the recursion changes a slot, and this one answers `Dynamic[top]` where it
does.

Two smaller choices came with it. The cover test reads the bindings the re-entry was built with,
not the call's syntax, so an assigned parameter, a call inside a block and a mutual pair are
judged by what they pass; the scan is read only for a re-entry through a call-site `*splat`,
whose binder has no positional correspondence. And the first frame with an unpinned argument
under a constant-argument unroll owns its own summary, which keeps #3158's
`positional_before_rest(3, 1)` row at `:done`.

No row of `recursive_keyword_parity.rb` or of the ADR-55 fixtures moved, and no existing spec
was edited.

### Cost, accepted by the maintainer on 2026-11-13

`tool/engine_alloc_ab.rb` over `lib` against the merge base `a1bb73d1c`, on the final head:
84,831,276 to 85,858,726 allocations, +1.21%, above the 1.0% per-PR band (`pr_allocations_pct`).
The maintainer accepted the rise at +1.16%, measured before review round 2's block-parameter scan. The diagnostics over
`lib` are identical. The rise is the discarded evaluations: a recursion with an uncovered re-entry
types its body once reading the summary, throws that evaluation away and types it again on the
floor, and a first unpinned frame under an unroll runs a fixpoint where it ran one evaluation.

One cut was considered and rejected: answering `Dynamic[top]` at the first uncovered re-entry,
with no discarded evaluation. A body whose only exits are through such a re-entry would then
never compute `bot`, so `spin` (no base case) would answer `Dynamic[top]` instead of `bot`, and
the bodies #3158's widened retry recovers (`keyword(1, n: some_int)`) would bypass the retry and
answer `Dynamic[top]` instead of `Integer`.

The maintainer accepted the rise above the band on 2026-11-13.

The floor also gives up true positives the wrong answer happened to report:

- `acc(rand(10), 1).upcase` reported `undefined method 'upcase' for 1`; the receiver is now
  `1 | Dynamic[top]` and nothing is reported.
- `count(some_int).no_such` for `def count(n) = n <= 0 ? 0 : 1 + count(n - 1)` reported
  `undefined method 'no_such' for Integer`; the receiver is now a `Dynamic` over the numeric
  classes and nothing is reported.

## To undo

Remove `uncovered_reentry_floor` at the recursion guard and the floor switch in
`fixpoint_user_method_return` (`lib/rigor/inference/expression_typer.rb`), and take the second
option with a final evaluation under the outer bindings if the precision is wanted: #3162's rows
have to stay sound. Nothing else reads the summary entry's new fields.
