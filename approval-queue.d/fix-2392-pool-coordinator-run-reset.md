# Reset the coordinator's and the sequential run tables at the start of each run

- **PR:** [#2581](https://github.com/rigortype/rigor/pull/2581)
- **Issue:** [#2392](https://github.com/rigortype/rigor/issues/2392)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-01

## Background

`Runner::PoolCoordinator` holds six accumulators that only `#initialize` cleared: run disclosures, trust refusals, dependencies, analysis reads, analysis disclosures and effects. `Runner` holds the sequential counterparts, its per-file dependency and effect tables and the effect-slot state a served run leaves behind. A reused Runner carried the previous run's rows into the next run: disclosures were re-emitted and refusal counts summed in pool mode, and files a later run no longer analysed stayed in the dependency and effect graphs in both modes. No shipped caller reuses a Runner, since each one builds a fresh Runner per run. The issue asked for a per-run reset but left open which tables belong to a run. The brief delegated that call to the lane.

## Options and trade-offs

- **Reset every per-run table in both modes, at the top of each `Runner#run_analysis` (taken).** A reused Runner, pooled or sequential, reports what a fresh one would. The cost is that the dependency and effect graphs restart each run, so a narrowed run sees only the files it analysed. No caller reads them across runs today.
- **Reset only the two disclosure and refusal tables the issue names.** The smallest change, but in both modes a dependency or effect row from a file the next run no longer analyses would survive and feed the runner's graph.
- **Clear the tables inside `analyze_files`.** Would also wipe the first pass's collections on a second pass within one run, which the reset must never do.

## Decision

Reset every per-run table once per run, at the top of `run_analysis`, in both modes: the six coordinator tables through `PoolCoordinator#reset_for_run`, and the sequential dependency and effect tables plus the served-run loader, sources, ancestry and flag through `Runner#reset_sequential_run_tables`. Each is per-run state: a file the run did not analyse should not contribute to its graph. The reset runs before any `adopt_*` call, and the served lanes call those later in the same run. Configuration-derived state (`@record_dependencies`, `@record_effects`, the readers and reporters) stays per coordinator and per Runner. The specs in `spec/rigor/analysis/pool_run_reset_spec.rb` and `spec/rigor/analysis/runner/pool_coordinator_spec.rb` pin each table.

## To undo

Remove `PoolCoordinator#reset_for_run` and `Runner#reset_sequential_run_tables` with their calls in `Runner#run_analysis`, which restores the cross-run accumulation the issue reports. To keep only the two named tables, drop the other lines from both reset methods. Nothing user-visible depends on either choice yet, since no shipped caller reuses a Runner.
