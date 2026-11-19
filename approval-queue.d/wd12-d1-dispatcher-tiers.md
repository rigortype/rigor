# The first batch of dispatcher tier moves is the four tiers that share no helper with a tier that stays

- **PR:** [#3363](https://github.com/rigortype/rigor/pull/3363)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** scope
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-19

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" turns `MethodDispatcher`'s twelve private tiers into eleven `try_dispatch(context)` modules "in two or three pure-move pull requests" (slice 2, D1–Dn). It names the eleven modules and the rule for where `resolve` asks each, and does not say which tiers go in which pull request. The first one had to pick its batch, and the lane's brief left the pick to the lane.

## Options and trade-offs

- **By what `resolve` does after the answer.** First the five tiers nothing follows (meta introspection, HKT builtin return, static refinement, synthetic method, synthesized stub), then the six `resolve` follows with a record. It frees the most lines in one step, about 700 of 1,880. Synthetic method shares `synthetic_method_class_name` with project-patched and is half of `plugin_member_answers?` beside plugin contribution, so moving it ahead of those two means either a function that stays calling into the new module for a helper, or a copy of the helper.
- **By shared helpers.** The four tiers that call no function a remaining tier calls: meta introspection, HKT builtin return, static refinement, synthesized stub. 603 lines leave the file, and no function left in it changes except `resolve` and `dispatch_precise_tiers`. Synthetic method waits for the batch that moves the tiers it shares code with.
- **One tier per pull request.** The smallest diffs, at eleven review rounds and eleven edits of the same gate rows.

## Decision

By shared helpers: #3363 moves `MetaIntrospection`, `HktBuiltinReturn`, `StaticRefinement` and `SynthesizedStub`. A pure move is easiest to check when every body outside the moved set is untouched, and the first option gave that up for about 100 more lines. `method_dispatcher.rb` goes from 1,880 lines to 1,287 against a budget that was 20 lines away.

The precedent is the amendment itself, which sets the number of pull requests and leaves their content open. It fits loosely: the amendment decides that the moves are batched, not how.

Seven functions remain, eight tiers: plugin contribution, synthetic method, project-patched (asked twice), dependency source, discovered method, user-class fallback and composite receiver. The pull request's body lists what each shares with code that stays (`synthetic_method_class_name`, `explicit_non_self_receiver?`, `dep_source_class_name`, `discovered_method_lookup`, the two `TypingState` memos), which is what the next batch has to settle. This entry does not decide that split.

## To undo

Nothing depends on the batch boundary. To regroup, move a tier's functions back into `method_dispatcher.rb` verbatim (the pull request's body lists the substitutions: the entry's parameter preamble, one recursion in `StaticRefinement`, the three callers of `array_new_element`), put its call back in `resolve` or `dispatch_precise_tiers` at the position its array holds, and restore its rows: the `sig/` declaration, the `parameter_only` pin and the compared floor in `provenance_spec.rb`, the path in `typing_state_closure_spec.rb`, the budget row, and the two code-map rows.
