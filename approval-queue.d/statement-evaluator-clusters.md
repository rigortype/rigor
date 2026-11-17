# A module extracted from StatementEvaluator takes the evaluator and the state it reads as parameters

- **PR:** [#3318](https://github.com/rigortype/rigor/pull/3318)
- **Issue:** [#3283](https://github.com/rigortype/rigor/issues/3283)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-18

## Background

ADR-116 lists StatementEvaluator's three self-contained clusters as pure moves and rejects, as end states, a mixin included back into the class and the class reopened in another file, because both shorten the file without shrinking its interface or its shared state. It does not say how a module taken out of a class that holds instance state (`@scope`, `@tracer`, `@class_context`, `@lexical_nesting`, `@opaque_class`) reaches that state and the evaluator methods the moved code called as `self`. Earlier moves (`Narrowing`, `ScopeIndexer`) came out of stateless modules, so none had to answer it.

## Options and trade-offs

- (a) A mixin included into `StatementEvaluator`. Rejected by the ADR: the moved methods keep reading the host's ivars, so the interface is unchanged.
- (b) A `module_function` module under `statement_evaluator/` whose entries take the evaluator and each ivar they read as positional parameters. A callback is made on the `evaluator` parameter, and only to a named set of methods, which become public with an `@api private` note. No allocation is added (positional arguments, no context object). The cost: the host keeps one-line call sites or delegators, and a method that calls back must thread `evaluator` through its recursive callees (15 of 40 methods in the pattern-matching cluster).
- (c) A collaborator object holding a reference to the evaluator. `sub_eval` and `evaluator_at` build a new evaluator for every sub-evaluation, so the collaborator would be one allocation per sub-evaluation unless it were built lazily, and a second object whose lifetime must match the evaluator's.
- (d) Leave the clusters until WD8 gives the evaluator a hook point.

## Decision

(b), with a cut-off that decides which clusters leave: a cluster moves only when it writes no evaluator ivar, reads only ivars that are fixed at construction (at most three), and calls back at most four distinct evaluator methods; a cluster over any limit stays and its numbers are reported. Passing an ivar as a parameter is equivalent to reading it only if the ivar is never written after `initialize`. That holds for `@scope` and `@tracer`, which are assigned only in `initialize` (`sub_eval` and `evaluator_at` always build a new evaluator); the reviewer verified it. It does not hold for every ivar of this class: `@value_position_block` is reassigned during evaluation, and `@owner_evaluators` and `@typing_state` are lazily memoised. A `scope` or `tracer` attribute-reader call counts as an ivar read. Per cluster, by the call graph over the whole class:

- Rescue reference binding and pattern matching (40 methods): writes 0 ivars, reads 2 (`@scope`, `@tracer`), calls back 3 methods (`sub_eval`, `widen_index_target`, `widen_attribute_write`). Moved to `StatementEvaluator::PatternBindings`.
- Def arguments and assertions (21 methods): writes 0, reads 1 (`@tracer`), calls back 1 (`eval_def`). Moved to `StatementEvaluator::DefArgumentsAndAssertions`.
- Class body and method entry scope (19 methods): writes 0, reads 4 (`@scope`, `@class_context`, `@lexical_nesting`, `@opaque_class`), calls back 1 (`sub_eval`). Not moved. The issue listed three reads; the cluster also reads `scope` sixteen times through the attribute reader. Raising the cut-off to four would not move it: those four ivars are the evaluator's frame identity, the arguments of `evaluator_at`, and threading them through 19 methods would rebuild the evaluator by hand. It waits for WD8.

Why (b) over the others. (a) is rejected by the ADR. (c) costs an allocation per sub-evaluation (or a lazily built second object) for no gain over parameters, on the hottest path in the engine. (d) leaves 61 methods, about 900 lines, in a file several pull requests a day touch, for a hook point that has no date; (b) moves them now at no measured allocation or wall cost (alloc -0.01%, wall ranges overlap).

Costs of (b) this PR measured:

- `evaluator` is threaded through 15 of the 40 methods of `PatternBindings`, because `sub_eval` is reached through the recursive `collect_*` walk, and into every call to them.
- Four evaluator methods became public (`sub_eval`, `widen_index_target`, `widen_attribute_write`, `eval_def`), marked `@api private`. `plugin_boundary_spec` would flag a plugin that called them.
- The self-check types the moved code only as far as `sig/` declares it. The entries `PatternBindings.eval_match_pattern` and `.eval_match_write` and the evaluator's `eval_def` are declared, so what `evaluator.sub_eval` returns reads as at base there. The other entries (`bind_rescue_reference`, `apply_in_pattern_bindings` and all of `DefArgumentsAndAssertions`, whose one renderable entry `apply_rspec_matcher_narrowing` trips a self-check error on `narrow.fetch(:local)` once `current_scope` is typed) and `widen_index_target` / `widen_attribute_write` are undeclared, because sig-gen renders no return for them and a hand-written row would raise `SIG_PROVENANCE_RESIDUE`. The 11 private helpers that receive `evaluator` as a threaded parameter are undeclared too, so their `evaluator` reads `Dynamic[top]` (probed on `collect_capture_pattern_bindings`). Both go to #3315.

## To undo

Inline each module's methods back into `StatementEvaluator` (the bodies are verbatim apart from the ivar-to-parameter and callback-to-`evaluator.` substitutions listed in the PR), make `sub_eval`, `widen_index_target`, `widen_attribute_write` and `eval_def` private again, and drop the two requires, the two `typing_state_closure_spec.rb` rows and the budget row's change.
