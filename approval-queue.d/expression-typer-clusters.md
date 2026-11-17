# The #3318 rule, applied to a second class: ExpressionTyper's composites, writes and assemblers leave; three families stay

- **PR:** [#3319](https://github.com/rigortype/rigor/pull/3319)
- **Issue:** [#3284](https://github.com/rigortype/rigor/issues/3284)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-18

## Background

ADR-116 lists ExpressionTyper's plain per-node typers and per-element assemblers as pure moves. Unlike the stateless modules `Narrowing` and `ScopeIndexer` were cut from, `ExpressionTyper` holds instance state, and its dispatch table, `PRISM_DISPATCH`, names each typer by symbol and calls it with `send`. The question [`statement-evaluator-clusters.md`](statement-evaluator-clusters.md) answered for `StatementEvaluator` (#3318) was open here too: how a module taken out of such a class reaches the state and the methods the moved code called as `self`.

This entry applies that rule, unchanged, to a second class. The rule's first use, #3318, is still in the queue and an unratified entry is not a precedent, so this entry sets one too: the two are ratified or revised together. Applying the rule to this class also showed where it stops, below.

## Options and trade-offs

The options and their costs are the ones in `statement-evaluator-clusters.md`: (a) a mixin included back, rejected by the ADR; (b) `module_function` modules whose entries take the typer and the state they read as positional parameters; (c) a collaborator object holding the typer; (d) leave the clusters until a hook point exists. Two points are particular to this class.

- The dispatch. `type_of` reaches a typer by `send(handler, node)` on the symbol `PRISM_DISPATCH` holds. Naming the module function there directly would change the table's shape (WD12's business). Keeping each name as a one-line private delegator on the typer costs one extra method call per node and no allocation.
- `@scope` and `@tracer` are assigned only in `initialize` in this class (`git grep` finds no other assignment and no `instance_variable_set`), so passing them is equivalent to reading them. `@typing_node` is rewritten by `type_of` and `@operand_types` is read with it, so they are not fixed at construction. No moved method reads them; `typer_under`, which does, stays in the class.

## Decision

(b), under the #3318 cut-off: a method moves only when it writes no typer ivar, reads only ivars fixed at construction (at most three), and calls back at most four distinct typer methods, applied to each module's union. Cluster 1 as a whole reads `@scope` and `@tracer` and calls back seven typer methods, so it was partitioned by node family. A module that meets the cut-off must also pass ADR-116's deletion test: its interface is smaller than what it hides. Three of the six first-cut modules did not, and were moved back verbatim.

Moved, and kept:

| Module | Methods | Entries | Ivars read (fixed at construction) | Callbacks | Typer methods made public |
| --- | ---: | ---: | --- | --- | --- |
| `Composites` (hash, array, range, interpolation, pass-through nodes) | 29 | 15 | 0 | 1 (`type_of`) | none |
| `Writes` (assignment and compound writes in value position) | 11 | 4 | 2 (`@scope`, `@tracer`) | 3 (`type_of`, `dynamic_top`, `resolve_constant_name`) | `dynamic_top`, `resolve_constant_name` |
| `PerElementAssemblers` (the assembler table and its functions) | 21 | 1 | 0 | 0 | none |

Each writes 0 ivars. `Composites` hides 14 helpers behind 15 entries, `Writes` 7 behind 4, `PerElementAssemblers` 20 behind 1, so each is a smaller interface than its body. `ExpressionTyper.public_instance_methods(false)` differs from base by exactly `dynamic_top` and `resolve_constant_name`.

Moved back into the class (cut-off met, deletion test failed):

- `LeafNodes` (30 methods): 29 of them are entries behind 29 same-name delegators, the same class with an indirection layer.
- `Constants` (6 methods): three entries and three callbacks, and it made `fallback_for` and `record_fallback` public, to hide 20 lines.
- `ControlFlow` (16 methods): seven entries, four callbacks of which three were newly public (`typer_under`, `statements_or_nil`, `block_level_jump?`), three threaded values, to hide 52 lines.

They wait for a different seam (WD8 / WD12). `LeafNodes` is the ADR's "plain per-node typers, which call only `type_of` and `dynamic_top`"; `Constants` and `ControlFlow` go beyond it. After the move back, their methods in `expression_typer.rb` are textually equal to `origin/master`'s (checked by Prism, comments included). `statements_or_nil` stays private: its delegator is called by the rescue typers still in the class, which reach `Composites` through it.

Other decisions. `NO_MATCH` and `NO_STATIC_HASH_KEY` stay in the class and the modules read them lexically, because moving an initialiser would add a row to `admission_census.yml`, a gate-row decision this slice does not make. The one gate row that changed is `admission_census.yml`'s `in_source_constants` copy, re-keyed from `expression_typer.rb` to `expression_typer/writes.rb`. `Writes` does not require `scope_indexer`: it requires this class, and the require makes a cycle under `ruby -w`.

Measured costs (review of the first cut, six modules): allocations +179 objects (+0.00%); `tool/engine_wall_ab.rb --target lib/rigor/inference --reps 6`: 42.14 s (39.96–48.52) to 41.515 s (39.79–44.19), CPU -0.39%, GC +0.29%, ranges not separating, on a loaded host. That wall figure is from before the three modules moved back, which removes delegators. At this head, allocations are measured again (see the PR).

## To undo

Inline each module's methods back into `ExpressionTyper` (the bodies are verbatim apart from the parameter-for-reader and `typer.`-for-bare-callback substitutions listed in the PR), make `dynamic_top` and `resolve_constant_name` private again, delete the 19 delegators and the three requires, and put back the three `typing_state_closure_spec.rb` paths, the budget row and the `admission_census.yml` row. `PerElementAssemblers` could be undone alone: its one call site is `PerElementAssemblers.assemble_per_element_result` in the per-element fold.
