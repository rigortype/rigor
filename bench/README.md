# Perf benchmark data

Files that drive the `make bench-perf` perf-regression gate
([ADR-50](../docs/adr/50-release-engineering-and-stability-strategy.md) WD4),
run as an advisory job in the release gate
(`.github/workflows/release-gate.yml`).

| File | Purpose |
|---|---|
| `baseline.json` | The committed per-target baseline metrics (wall / allocations / peak-RSS). Ships **uncalibrated**; activate by committing a CI-measured baseline (see below). |
| `thresholds.yml` | The tunable tolerance band — the reviewed knob for how much each metric may regress before the gate fails. |
| `baseline.updated.json` | **Not committed** (gitignored). The suggested baseline `make bench-perf` writes when the committed baseline is uncalibrated, or for inspection. |

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
