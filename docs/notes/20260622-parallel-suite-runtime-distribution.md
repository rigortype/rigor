# Parallel spec suite: runtime-based distribution (2026-06-22)

## Context

PR#24 (`spec-suite-performance` branch) sped up three slow spec groups by
sharing an immutable `Environment` across examples:

- `reflection_spec.rb` — `before(:all)` once per file vs. per example: ~22s → ~2s
- `rails_routes_plugin_spec.rb` — shared plugin cache (`default_run_plugin_cache_store: :shared`): ~25s → ~4s
- `incremental_session_spec.rb` — optional `IncrementalSession.new(environment:)`: ~16s → ~6s

Sequential `make test` savings: **~50 seconds**.

## CI regression found

Comparing GitHub Actions "Tests (Ruby 4.0)" wall-clock between PR#22 and PR#24:

| PR  | Run 1 | Run 2 |
|-----|-------|-------|
| #22 | 473s  | 458s  |
| #24 | 493s  | 476s  |

PR#24 is consistently **~20s slower** on the parallel suite despite being ~50s
faster on the sequential suite.

## Root cause: `--group-by filesize` became a bad proxy

`parallel_rspec --group-by filesize` distributes spec files into worker groups
by total byte count. This works as a runtime proxy when large files are also
slow — but PR#24 created a "large but fast" file: `rails_routes_plugin_spec.rb`
is 1499 lines (5th largest in the suite) but now runs in ~4s instead of ~25s.

The per-group breakdown tells the story:

| Group | PR#22 time | PR#22 examples | PR#24 time | PR#24 examples |
|-------|-----------|----------------|-----------|----------------|
| 1     | 6:02      | 1839           | **3:55**  | 1724           |
| 2     | 6:27      | 1744           | **4:50**  | 1759           |
| 3     | 6:45      | 1747           | **5:24**  | 1620           |
| 4     | 7:16      | 1689           | **7:38**  | **1916**       |

Groups 1–3 are dramatically faster (the shared-setup wins are real). But the
parallel wall-clock is determined by the **slowest group**, and group 4 went
from 7:16 → 7:38 (+22s) because the filesize balancer pushed 227 extra
examples into it once the "heavy" files were no longer the bottleneck.

Total examples stayed at 7019 — same tests, different distribution.

## Fix: switch to `--group-by default` with a cached runtime log

`parallel_tests 5.7.0` documents three modes:

- `filesize` — by file byte count (old behavior)
- `runtime` — by measured per-file timing from a previous run
- `default` — runtime when a log exists, filesize otherwise

Switching to `--group-by default --runtime-log tmp/parallel_runtime.log`
and recording timings via `ParallelTests::RSpec::RuntimeLogger`:

1. **First CI run (cold log)**: falls back to filesize — same as before, slightly
   unbalanced.
2. **Every subsequent run**: uses measured timing → correctly re-weights
   `rails_routes_plugin_spec.rb` as ~4s, not ~25s.
3. **Self-correcting**: any future spec speed-up/slow-down is automatically
   re-balanced on the following run without any manual intervention.

CI caches `tmp/parallel_runtime.log` between runs (unique key per `run_id`,
prefix-match restore-key to always find the most recent entry).

### Files changed

- `Rakefile` — `--group-by filesize` → `--group-by default` + `--runtime-log`
  + `-o` formatter flag so workers write timing data
- `.github/workflows/ci.yml` — restore/save cache step before `make test-parallel`

### Commits

- PR#24: `9c743701` — spec-suite setup sharing (the speedup)
- this follow-up: runtime distribution fix
