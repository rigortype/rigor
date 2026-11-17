# The #3318 rule, applied to a second class: ExpressionTyper's node typers and assemblers leave in five modules and one

- **PR:** [#3319](https://github.com/rigortype/rigor/pull/3319)
- **Issue:** [#3284](https://github.com/rigortype/rigor/issues/3284)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-18

## Background

ADR-116 lists ExpressionTyper's plain per-node typers and per-element assemblers as pure moves. Unlike the stateless modules `Narrowing` and `ScopeIndexer` were cut from, `ExpressionTyper` holds instance state (`@scope`, `@tracer`, `@operand_types`, `@typing_node`), and its dispatch table, `PRISM_DISPATCH`, names each typer by symbol and calls it with `send`. The same question [`statement-evaluator-clusters.md`](statement-evaluator-clusters.md) answered for `StatementEvaluator` (#3318) was open here: how a module taken out of such a class reaches the state and the methods the moved code called as `self`.

This entry applies that rule, unchanged, to a second class. The rule's first use, #3318, is still in the queue and an unratified entry is not a precedent, so this entry sets one too: the two are ratified or revised together.

## Options and trade-offs

The options and their costs are the ones in `statement-evaluator-clusters.md`: (a) a mixin included back, rejected by the ADR; (b) `module_function` modules whose entries take the typer and the state they read as positional parameters; (c) a collaborator object holding the typer; (d) leave the clusters until a hook point exists. Two points are particular to this class.

- The dispatch. `type_of` reaches a typer by `send(handler, node)` on the symbol `PRISM_DISPATCH` holds. Naming the module function there directly would change the table's shape (WD12's business) and, without a lambda or `define_method`, would not allocate less. Keeping each name as a one-line private delegator on the typer costs one extra method call per node and no allocation: 56 private delegators (`def local_read(node) = LeafNodes.local_read(node, scope, self)`) and one public one (`statements_or_nil`).
- `@typing_node` and `@operand_types` are written or read around `type_of` (`type_of` sets and restores `@typing_node`), so they are not fixed at construction. No moved method reads them; `typer_under`, which does, stays in the class and is called back.

## Decision

(b), under the #3318 cut-off: a method moves only when it writes no typer ivar, reads only ivars fixed at construction (at most three), and calls back at most four distinct typer methods, and the test is applied to each module's union. `@scope` and `@tracer` are assigned only in `initialize` (`git grep` finds no other assignment and no `instance_variable_set`); a `scope` or `tracer` attribute-reader call counts as an ivar read. Cluster 1 as a whole (about 100 methods) reads `@scope` and `@tracer` and calls back seven typer methods, so it is partitioned by node family:

| Module | Methods | Ivars read (fixed at construction) | Callbacks | Public typer methods it needs |
| --- | ---: | --- | --- | --- |
| `LeafNodes` (literals, variable reads, `self`, `defined?`, match globals, jumps, non-value positions) | 30 | 1 (`@scope`) | 1 (`dynamic_top`) | `dynamic_top` |
| `Composites` (hash, array, range, interpolation, pass-through nodes) | 29 | 0 | 1 (`type_of`) | none |
| `Constants` (constant reads) | 6 | 1 (`@scope`) | 3 (`dynamic_top`, `fallback_for`, `record_fallback`) | `fallback_for`, `record_fallback` |
| `Writes` (assignment and compound writes in value position) | 11 | 2 (`@scope`, `@tracer`) | 2 (`type_of`, `dynamic_top`) | none |
| `ControlFlow` (`if`, `and`/`or`, loops, `case`, `begin`/`rescue`) | 16 | 2 (`@scope`, `@tracer`) | 4 (`type_of`, `statements_or_nil`, `typer_under`, `block_level_jump?`) | `typer_under`, `statements_or_nil`, `block_level_jump?` |
| `PerElementAssemblers` (the assembler table and its 20 functions) | 21 | 0 | 0 | none |

Every module writes 0 ivars. Six typer methods became public and are marked `@api private` (`dynamic_top`, `fallback_for`, `record_fallback`, `typer_under`, `statements_or_nil`, `block_level_jump?`); `type_of` was public already. `Writes` calls `Constants.resolve_constant_name`, a second module's entry, instead of a typer callback. The cost: `ControlFlow` is at the four-callback cut-off, and `block_level_jump?`, a one-line helper four other methods share, is public for its two loop methods. The loop methods are the one place the rule's surface was weighed; they moved because the module stays within the cut-off.

What stayed, and why. `type_of_virtual` (fallback for synthetic nodes; reached from `untraced_type_of`), `typer_under`, `fallback_for`, `record_fallback` and `dynamic_top` (the callbacks; only their visibility changed and they moved above `private`), and `indexed_narrowing_for` / `method_chain_narrowing_for` (the call front, outside this slice). User-method return inference, block-return typing and the per-element Tuple folds that call the assemblers were not touched.

`NO_MATCH` stayed in `ExpressionTyper`, and `PerElementAssemblers` reads it lexically, because moving its initialiser would add a row to `admission_census.yml`, a gate-row decision this slice does not make. The only gate row that changed is `admission_census.yml`'s `in_source_constants` copy, re-keyed from `expression_typer.rb` to `expression_typer/writes.rb`.

`sig/`: the entries sig-gen renders a return for are declared, and so are the private helpers that receive `typer` and that sig-gen renders a return for (without a declaration `typer` reads `Dynamic[top]` inside them). Left undeclared, as in #3318, because a declaration would raise `SIG_PROVENANCE_RESIDUE`: `LeafNodes.type_of_yield`, `ControlFlow.type_of_conditional`, `ControlFlow.type_of_loop`, `PerElementAssemblers.assemble_per_element_result` and the helpers sig-gen renders nothing for (#3315).

## To undo

Inline each module's methods back into `ExpressionTyper` (bodies are verbatim apart from the parameter-for-reader and `typer.`-for-bare-callback substitutions listed in the PR), make the six callbacks private again, delete the 57 delegators and the six requires, and put back the six `typing_state_closure_spec.rb` paths, the budget row, the `admission_census.yml` row and `typing_state_spec.rb`'s one expectation. `PerElementAssemblers` could be undone alone: its one call site is `PerElementAssemblers.assemble_per_element_result` in the per-element fold.
