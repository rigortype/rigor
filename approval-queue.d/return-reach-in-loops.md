# Read a project method as running its block repeatedly from its body, erring toward "repeats", for the later-run return pass only

- **PR:** [#2250](https://github.com/rigortype/rigor/pull/2250)
- **Issue:** [#2127](https://github.com/rigortype/rigor/issues/2127)
- **Class:** open-choice
- **Precedent:** [#2126](https://github.com/rigortype/rigor/pull/2126)
- **Decided:** 2026-10-21

## Background

#2127 asks that a `return` inside a block passed to a project method that yields more than once reach the method's return type, as #2126 made it for core iterators. The issue warned that widening `BlockRepetition.may_repeat?` itself moves every block entry scope, and named the hard cases (a body that yields inside a loop, more than once, or an unknown body) without choosing a rule.

## Options and trade-offs

- **Widen `BlockRepetition.may_repeat?` to project yielders.** Covers diagnostics inside the block too, but moves every block entry scope and the write-back for such calls, a much wider change with its own false-positive risk.
- **Answer only the later-run return pass, from the callee's body (taken).** `ProjectYielder` reads the resolved project `def`: two or more `yield` / `blk.call` sites, one inside a loop, block or lambda, or a block handed on (`&blk`, `&`, `...`) or stored counts as repeating. A `yield` inside a block that runs once (`tap { yield }`) is read as repeating too. The pass only widens the method's return type, so erring toward "repeats" costs precision, never a diagnostic on correct code.
- **Also treat an unresolved callee as repeating.** Sound in the same direction, but every block passed to an unknown method would get the pass, and the issue did not ask for it.

## Decision

The return-pass-only rule, read from the body, with an unresolved callee left as before. It follows #2126, which added the later-run pass for core iterators without changing block entry scopes, and AGENTS.md's false-positive rule: a too-narrow return type is what drew `flow.always-truthy-condition` on correct code.

## To undo

Drop the `ProjectYielder.may_run_block_repeatedly?` branch from `StatementEvaluator#repeated_block_return_candidate?` (and `lib/rigor/inference/project_yielder.rb` with its spec), and the yielder cases in `spec/integration/fixtures/return_reach_in_loops.rb` and its snapshot.
