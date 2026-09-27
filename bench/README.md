# Perf benchmark data

Files that drive the `make bench-perf` perf-regression gate
([ADR-50](../docs/adr/50-release-engineering-and-stability-strategy.md) WD4),
run as a job in the release gate (`.github/workflows/release-gate.yml`),
where it is a hard gate once the baseline is calibrated.

| File | Purpose |
|---|---|
| `baseline.json` | The committed per-target baseline metrics (wall / allocations / peak-RSS). Ships **uncalibrated**; activate by committing a CI-measured baseline (see below). |
| `thresholds.yml` | The tunable tolerance band — the reviewed knob for how much each metric may regress before the gate fails. |
| `baseline.updated.json` | **Not committed** (gitignored). The suggested baseline `make bench-perf` writes on **every** run — this is the file a refresh commits from. |

The benchmark runs `rigor check --no-cache` in-process over a target (default
`lib`) and measures wall time, `GC.stat(:total_allocated_objects)`, and peak
RSS. Peak RSS is read from `/proc/self/status` and is therefore measured on
**Linux only** (the CI runner is authoritative); on macOS / other hosts it is
reported `nil` and the gate skips it, so local `make bench-perf` still measures the
portable wall + allocations.

## Calibrating the baseline

The committed `baseline.json` is uncalibrated, so the gate passes and emits a
suggestion. To activate it against the authoritative Linux numbers:

```sh
# Locally (writes bench/baseline.updated.json, never the committed file):
make bench-perf

# Or take the perf artifact from a release-gate run on CI (Linux), then:
#   commit its per-target metrics as bench/baseline.json with
#   { "calibrated": true, "targets": { ... } }.
```

When a Rigor change legitimately shifts the numbers (a perf win, or an
accepted cost), refresh the baseline the same way — deliberately, as a
reviewed commit, never silently.

Refreshing matters in **both** directions. The band is a percentage of the
baseline, not of the current cost, so an improvement left unrefreshed widens
the real ceiling instead of tightening it: after `lib` allocations fell 27%,
the +5% band still permitted +44% over the true number. The gate only fails
on regressions — an improvement is not one — so `make bench-perf` prints a
`STALE` notice when allocations fall more than `stale_pct` below the
baseline. Treat it as a request for a reviewed refresh, not a failure.

## The per-PR engine A/B

The release gate above runs only at a cut, over a `lib` that grows with every
pull request, so its band cannot tell corpus growth from engine cost. The
advisory "Engine allocations" CI job (`tool/engine_alloc_ab.rb`, #1507) answers
the engine half on each PR: the merge base's engine and the PR's engine each
run `rigor check --no-cache lib` over the merge base's tree, in fresh
processes, and the job summary reports the delta. It warns past
`pr_allocations_pct` in `thresholds.yml` and never fails the PR.

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
