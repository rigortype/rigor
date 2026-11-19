# `explicit_non_self_receiver?` stays in `ProjectPatched`, and the user-class fallback asks it there

- **PR:** [#3365](https://github.com/rigortype/rigor/pull/3365)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

`explicit_non_self_receiver?(call_node)` answers whether a call is written on a receiver other than `self`. Ruby does not let such a call reach a private method, and two dispatcher tiers ask it for that reason: the project-patched tier, to refuse a private `pre_eval:` patch, and the user-class fallback, to keep the private methods of `Object`, `Kernel` and `Class` off an explicit receiver. It was written for the fallback (`fb807fb02`), and its comment still explains it by the fallback alone.

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" moves the dispatcher's tiers into modules in batches. #3364 moved the project-patched tier while the fallback was still a function of `method_dispatcher.rb`, so the predicate went with the tier that moved, as `ProjectPatched`'s second entry. #3365 moves the fallback into `UserClassFallback`. Both callers are now modules, neither owns the predicate more than the other, and the lane's brief asked for its home to be decided.

## Options and trade-offs

- **Stay in `ProjectPatched`.** Nothing moves: the function, its examples in `project_patched_spec.rb` and their four mutation rows stay where #3364 put them. `user_class_fallback.rb` requires `project_patched.rb` for a predicate that has nothing to do with patches, and the function's comment describes a caller in another file.
- **Move to `UserClassFallback`.** The comment and the history fit. `project_patched.rb` would then require `user_class_fallback.rb`, the one tier file that declares `Rigor::TypingState` slots, so two requires would decide where its two memo slots land instead of one. Measured on this branch: with that require added, `Rigor::TypingState.slots` is the same 92 names in the same order through all three load paths, because nothing that loads between the two requires declares one. So the slot order does not rule this option out today; it would start to depend on that staying true. The function would also move for the second time in two pull requests.
- **A home neither tier owns.** `ArgumentNodes` holds the other reading of a call node that two tiers share, and is named for arguments; a receiver predicate there is a misnomer. A module of its own would be one six-line function behind one name, which hides nothing. A reader on `CallContext` (`context.explicit_non_self_receiver?`) removes the dependency between the two tiers, but it changes the function's body and both call sites inside a pull request whose claim is that bodies do not change, and it puts a Prism read on the value object.

Every option is temporary. [ADR-132](../docs/adr/132-reflective-call-view.md) WD3, accepted with no slice landed, has the tiers read a call's visibility from the context and names this function among the readers it replaces: its reading of the outer node is what makes `o.send(:priv)` public-only today. After WD3 no tier decides a call's visibility from its call node, and the predicate has no caller.

## Decision

It stays in `ProjectPatched`, and `UserClassFallback.try_dispatch` calls `ProjectPatched.explicit_non_self_receiver?`. No other home is better by enough to pay for a second move of a function that ADR-132 WD3 deletes: moving it to the fallback trades one cross-tier call for the opposite one and adds a second require of the slot-declaring file, and the neutral homes each cost a wrong name, an empty module or a body change.

The precedent is the amendment's rule for a second entry ("A rung module may expose a second named entry when a caller outside the rung asks part of it"), applied to a tier as #3363 and #3364 applied it (`MetaIntrospection.array_new_element`, `SyntheticMethodDispatch.synthetic_method_class_name`, `DependencySource.dep_source_class_name`): the helper lives in one module and its other callers name that module. It fits loosely, as it did there: the amendment states the rule for rungs, and it does not say which of two tier modules holds a helper both call.

## To undo

Move the function and its comment into the chosen module, and its `.explicit_non_self_receiver?` examples with it (`spec/rigor/inference/method_dispatcher/project_patched_spec.rb`). Two calls name it: `ProjectPatched.try_dispatch` and `UserClassFallback.try_dispatch`. `ProjectPatched`'s header comment calls it the module's second entry, and `user_class_fallback.rb` requires `project_patched.rb` only for it. If the new home is `UserClassFallback`, check `Rigor::TypingState.slots` under `require "rigor"`, a `rigor check` run and `require "rigor/inference/method_dispatcher"` alone, since `project_patched.rb` then loads the file that declares the two memos.

ADR-132 WD3 removes the question: once the context carries the call's visibility, the function and both calls go.
