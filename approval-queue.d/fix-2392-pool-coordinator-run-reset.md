# Reset all six coordinator run tables per run, including dependencies and effects

- **PR:** [#2581](https://github.com/rigortype/rigor/pull/2581)
- **Issue:** [#2392](https://github.com/rigortype/rigor/issues/2392)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-01

## Background

`Runner::PoolCoordinator` holds six accumulators that only `#initialize` cleared: run disclosures, trust refusals, dependencies, analysis reads, analysis disclosures and effects. A long-lived pool-mode `Runner` (the LSP and MCP shape) re-emitted the previous run's disclosures and summed refusal counts. The issue asked for a per-run reset but left open which of the six belong to a run. The brief delegated that call to the lane.

## Options and trade-offs

- **Reset all six at the top of each `Runner#run_analysis` (taken).** A reused Runner reports what a fresh one would. The cost is that the dependency and effect graphs also restart each run, so a narrowed run sees only the files it analysed; no caller reads them across runs today.
- **Reset only the two disclosure and refusal tables the issue names.** The smallest change, but a dependency or effect row from a file the next run no longer analyses would survive and feed the runner's graph.
- **Clear the tables inside `analyze_files`.** Would also wipe the first pass's collections on a second pass within one run, which the reset must never do.

## Decision

Reset all six, once per run, at the top of `run_analysis`. Each is per-run state: a file the run did not analyse should not contribute to its graph. Configuration-derived state (`@record_dependencies`, `@record_effects`, the readers and reporters) stays per coordinator. The unit example in `spec/rigor/analysis/runner/pool_coordinator_spec.rb` pins each table.

## To undo

Remove `PoolCoordinator#reset_for_run` and its call in `Runner#run_analysis`, which restores the cross-run accumulation the issue reports. To keep only the two named tables, drop the other four lines from `reset_for_run`. No shipped caller reuses a pool-mode Runner, so nothing user-visible depends on either choice yet.
