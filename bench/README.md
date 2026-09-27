# Perf benchmark data

Files that drive the `make bench-perf` perf-regression gate
([ADR-50](../docs/adr/50-release-engineering-and-stability-strategy.md) WD4),
run as a job in the release gate (`.github/workflows/release-gate.yml`),
where it is a hard gate once the baseline is calibrated.

| File | Purpose |
|---|---|
| `baseline.json` | The corpus revision (`"corpus"`) and the committed per-target baseline metrics measured on it (wall / allocations / peak-RSS). While `"calibrated": false` the gate passes and only suggests; activate by committing a CI-measured baseline (see below). |
| `thresholds.yml` | The tunable tolerance band — the reviewed knob for how much each metric may regress before the gate fails. |
| `baseline.updated.json` | **Not committed** (gitignored). The suggested baseline `make bench-perf` writes on **every** run — this is the file a refresh commits from. |

The benchmark runs this checkout's `rigor check --no-cache` in-process over a
target (default `lib`) of a **frozen corpus**, and measures wall time,
`GC.stat(:total_allocated_objects)`, and peak RSS. Peak RSS is read from
`/proc/self/status` and is therefore measured on **Linux only** (the CI runner
is authoritative); on macOS / other hosts it is reported `nil` and the gate
skips it, so local `make bench-perf` still measures the portable wall +
allocations.

## The corpus

`baseline.json` names the corpus as `"corpus"`: the previous release's tag.
`tool/bench.rb` `git archive`s that tree into a scratch directory and runs the
engine there, as `tool/engine_alloc_ab.rb` does, so a clone without the tag
(a shallow checkout) stops with an error rather than measuring something else.
Rigor's own `lib` grows with every pull request, +26.5% over the v0.4.0 cycle,
so a band on the current `lib` could not tell corpus growth from engine cost
at any width. On a frozen tree allocations repeat to a few hundred objects, so
the band in `thresholds.yml` is a budget for the cycle's engine cost rather
than room for noise.

The corpus has no `vendor/bundle`, so gems' own `sig/` directories do not
load. The running bundle still supplies the core RBS, so a gem bump can move
the numbers without an engine change; refresh the baseline for it like any
accepted cost.

Over a release cycle:

- **At the cut**, the release gate measures the release candidate's engine
  over the previous release's tree. That is the cycle's engine cost, gated by
  `allocations_pct`.
- **After tagging**, the corpus advances to the new tag and the baseline is
  recalibrated on it (below). The `rigor-release-prep` skill carries both
  steps.

## Calibrating the baseline

`release-gate.yml` runs on every `release/**` push and on demand
(`workflow_dispatch`). Every run uploads a `bench-baseline-<run id>` artifact:
the suggested baseline, reduced by the sampling rule and naming the corpus it
measured. Recalibrating is committing that file as `baseline.json`, with a
`note` saying why and `calibrated_on` naming the run:

```sh
gh workflow run release-gate.yml --ref <branch>
gh run download <run id> --name bench-baseline-<run id>
```

To move to a new corpus, set `"corpus"` to the new tag and `"calibrated":
false` first, so the run measures the new tree without gating it against
numbers from the old one. A local `make bench-perf` writes the same file to
`bench/baseline.updated.json`; commit the Linux CI numbers, not a laptop's.

When a Rigor change legitimately shifts the numbers (a perf win, or an
accepted cost), refresh the baseline the same way, on the same corpus:
deliberately, as a reviewed commit, never silently.

Refreshing matters in **both** directions. The band is a percentage of the
baseline, not of the current cost, so an improvement left unrefreshed widens
the real ceiling instead of tightening it: after `lib` allocations fell 27%,
the then +5% band still permitted +44% over the true number. The gate only
fails on regressions — an improvement is not one — so `make bench-perf` prints
a `STALE` notice when allocations fall more than `stale_pct` below the
baseline. Treat it as a request for a reviewed refresh, not a failure. When an
engine improvement lands (its "Engine allocations" job reports the drop), run
the release gate on `master` and refresh, so the next regression is measured
against the improved number.

## The per-PR engine A/B

The release gate above runs only at a cut, so it charges a cycle's engine
cost to the cycle. The advisory "Engine allocations" CI job
(`tool/engine_alloc_ab.rb`, #1507) charges each step to its PR: the merge
base's engine and the PR's engine each run `rigor check --no-cache lib` over
the merge base's tree, in fresh processes, and the job summary reports the
delta. It warns past `pr_allocations_pct` in `thresholds.yml` and never fails
the PR.

It measures only what that run executes. Rigor's own configuration loads no
plugin, so of `plugins/` only the rbs-inline ingestion the engine runs by
default is measured; a PR that touches none of `lib/`, `data/` and
`plugins/rigor-rbs-inline/` is skipped rather than reported as a zero.

The same comparison runs locally, including against uncommitted work. Measure
from the merge base, not `origin/master`: a base the branch did not start from
charges the work with every engine change merged since.

```sh
nix develop --command bash -c 'bundle exec ruby tool/engine_alloc_ab.rb --base "$(git merge-base origin/master HEAD)" --head WORKTREE'
```
