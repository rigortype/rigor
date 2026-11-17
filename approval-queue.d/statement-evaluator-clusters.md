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
- (c) A collaborator object built once per evaluator and holding a reference to it. One allocation per evaluator and a second object whose lifetime must match the first.
- (d) Leave the clusters until WD8 gives the evaluator a hook point.

## Decision

(b), with a cut-off that decides which clusters leave: a cluster moves only when it writes no evaluator ivar, reads at most three, and calls back at most four distinct evaluator methods; a cluster over any limit stays and its numbers are reported. Per cluster, by the call graph over the whole class (a `scope` or `tracer` call is an ivar read):

- Rescue reference binding and pattern matching (40 methods): writes 0 ivars, reads 2 (`@scope`, `@tracer`), calls back 3 methods (`sub_eval`, `widen_index_target`, `widen_attribute_write`). Moved to `StatementEvaluator::PatternBindings`.
- Def arguments and assertions (21 methods): writes 0, reads 1 (`@tracer`), calls back 1 (`eval_def`). Moved to `StatementEvaluator::DefArgumentsAndAssertions`.
- Class body and method entry scope (19 methods): writes 0, reads 4 (`@scope`, `@class_context`, `@lexical_nesting`, `@opaque_class`), calls back 1 (`sub_eval`). Over the read limit by one, so it stays. The issue listed three reads; the cluster also reads `scope` sixteen times through the attribute reader.

## To undo

Inline each module's methods back into `StatementEvaluator` (the bodies are verbatim apart from the ivar-to-parameter and callback-to-`evaluator.` substitutions listed in the PR), make `sub_eval`, `widen_index_target`, `widen_attribute_write` and `eval_def` private again, and drop the two requires, the two `typing_state_closure_spec.rb` rows and the budget row's change.
