# #775 measurement harness (unmerged branch `perfbench-harness-775`)

The instruments behind `docs/notes/20260908-v037-allocation-regression-attribution.md`. Kept on a branch, never merged: every script is driver-side (`Module#prepend` / `TracePoint` from outside `lib/`), and the paths inside them are the 2026-09-08 session's scratch directory and worktrees — edit the constants at the top before reuse.

| file | what it measures |
| --- | --- |
| `sweep.sh` | `tool/bench.rb` allocations at every code-touching first-parent commit of a range, in an isolated worktree (`sweep-v0.3.6-to-v0.3.7.csv` is its output). |
| `prof_phases.rb` | exclusive allocations per pipeline region (`ENGINE_ROOT TARGET_ROOT target`) — the engine A/B on one target. |
| `prof_sites.rb` | allocation-site census over every Nth analysed file (`trace_object_allocations` with GC disabled), by file, class#method, line, engine file. |
| `prof_calls.rb` | per-method call counts (`TracePoint :call`, engine `lib/` only). |
| `prof_unions.rb` | arity histogram of `Combinator.union` and the call stacks that build unions of ≥ 10 members. |
| `prof_callers.rb` | rigor-side callers of `RBS::Substitution.build` (and a `Symbol#to_s` c_call probe that no longer fires — `Symbol#to_s` is Ruby-defined in 4.0). |
| `measure.rb` / `measure.sh` | one in-process `rigor check --no-cache --no-stats --format json lib` of the current tree: allocations plus byte-identity against a reference JSON. |
| `run_check.rb` | run one engine tree's CLI against another target tree (cwd = target, `$LOAD_PATH` = engine). |

Gotchas met while building it, recorded so the next sweep does not repeat them: under zsh `pipefail`, `git diff --name-only | grep -q PATTERN` fails whenever grep exits before git finishes writing (SIGPIPE), so the "touches non-Markdown" filter silently dropped every large merge — count with `grep -c` instead; and the `RIGOR_BUDGET_TRACE` counters drift by ~1% across hours on one host even though each run is deterministic and the diagnostics are byte-identical, so compare counters only back-to-back.
