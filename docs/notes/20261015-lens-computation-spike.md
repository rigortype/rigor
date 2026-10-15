# `rigor lens` computation spike: forced targets and an in-run index callback

Date: 2026-10-15.

Status: **research note, no design commitments.** It measures the computation path proposed for
[ADR-113](../adr/113-rigor-lens.md) WD2 after the adversarial review of the #1907 reply. The engine is
the branch `lens-computation-spike` at base `dd0201566`. The host is an Apple M4 Pro with 12 cores.
redmine is the survey checkout at `078e57f6b`.

## Question

ADR-113 WD2 says a lens "runs the incremental check path for its target file(s)" and that "the next lens
or `check` is warm". The review found two premises that do not hold on current code:

- The snapshot fingerprint hashes the run's roots, so a lens rooted at its target and `check --incremental`
  would overwrite each other's `snapshot.bin`.
- A warm null recheck analyses nothing, so no index exists for the target. The per-file index is built
  inside `Runner#analyze_file_body` and dropped there, or built in a forked worker.

The spike asks three things:

1. Can a lens read the seeded index that `check` builds, with diagnostics identical to `check`?
2. Does a lens share the snapshot with `check --incremental`?
3. What do cold and warm runs cost?

## Instrument

The changes are opt-in and default to off, so `check` is unchanged.

- `Runner.new(on_file_indexed:)` is called with `(path, parse_result, scope, index)` right after a file's
  rules run, inside the run window. A pooled file never reaches it.
- `IncrementalSession.new(force_targets:, on_file_indexed:)` adds the forced files to `recheck`'s analyse
  set. A recheck that forces targets runs with `workers: 0`, so the targets are indexed in process.
- `tool/lens_spike.rb` drives `run_incremental` with the roots `configuration.paths` (the fingerprint
  `check --incremental` writes). A cold run is a baseline at the configured worker count; when that left a
  target uncaptured (pool mode), the spike runs one more forced recheck. With `--rows`, it emits one row per
  class, module, `def` and direct-body `attr_*`, with the declared method types and their buffer-derived
  provenance and `DefReturnTyper`'s inferred return over the seeded index.
- `--skip-templates` is a sizing probe only. It drops #392's always-re-analysed template units, so it must
  run against a throwaway copy of the cache.

Every probe config set `cache.path` to a scratch directory and lived next to the project's own config,
so relative `paths:` resolved as in production.

## Results

### Parity with `check`

On redmine, the diagnostics the lens run produced for `app/models/issue.rb` (13) and
`app/controllers/boards_controller.rb` (5) equal `rigor check --no-cache --no-baseline --workers 4` for
the same files, row for row on line, column and message. Rigor's own targets have no diagnostics, so
they are no evidence either way.

### Shared snapshot

After a lens run, `rigor check --incremental` with the same config answered warm in 0.39 s on Rigor's
tree ("re-analysed 0 of 573 files") and in 0.45 s on redmine. Rooting the session at
`configuration.paths` is enough.

### Wall time

These are in-process seconds from the spike's phases. The end-to-end figure adds the process boot.

| Project | Run | Workers | Lens | `check --incremental`, same state |
| --- | --- | --- | --- | --- |
| Rigor (573 files) | cold | 0 | 62.4 | — |
| Rigor | cold | 4 | 26.8 baseline + 1.0 forced recheck = 27.9 | 31.9 (end to end) |
| Rigor | warm, nothing changed | 4 | 1.1–1.7, 1.66 end to end | 0.39 (run-result slot) |
| redmine (352 files, 508 view templates) | cold | 0 | 38.9 | — |
| redmine | cold | 4 | 20.2 baseline + 10.3 forced recheck = 30.6 | 19.3 (end to end) |
| redmine | warm, nothing changed | 0 or 4 | 10.8–11.0 | 0.45 (run-result slot) |
| redmine | warm, `issue.rb` touched | 0 | — | 9.5 |
| redmine | warm, templates skipped (probe) | 0 | 2.1, 3.2 end to end | — |

Building rows is negligible: 0.08 s for the 160 rows of `issue.rb`.

### Findings

1. **The computation works.** The forced target is indexed with the project seed, its diagnostics match
   `check`, and the snapshot is shared with `check --incremental`.
2. **A lens can never use the run-result slot.** `check` answers an unchanged project without running the
   engine. A lens needs an index, so it pays the engine's warm floor every time.
3. **On a Rails app that floor is the view templates.** #392 re-analyses every template unit on every
   recheck, and they cost about 80% of a warm lens on redmine (11.0 s against 2.1 s without them). The
   target's diagnostics were the same 13 either way. A lens whose targets are not templates has no
   use for the template units. Dropping them is sound only in a run that persists nothing about them,
   and only after checking that no run-level row depends on them.
4. **In pool mode the forced recheck is a second sequential run.** On redmine it re-analysed the 508
   templates sequentially (10.3 s) after a 20.2 s pooled baseline. Finding 3's lever also fixes this.
   Otherwise, analyse the forced targets in process during the pooled baseline.
5. **Rigor's own tree is always cold after an edit to `lib/`, for `check --incremental` too.** The fingerprint
   carries `EngineSource.process_identity`, and the analysed `lib` is the engine. Rigor's API site, built
   from a checkout, will therefore pay a cold run (about 28 s at 4 workers) on every commit that touches
   `lib/`. That is a build cost, not a lens defect, but #1907's transport answer must assume it.
6. **Provenance from buffer names survives a warm environment cache.** On a scratch fixture, a `#:` method
   read `inline`, an unannotated method in an `rbs_inline: enabled` file read `inline` with the
   `inferred-return` annotation (its inferred return came out `Integer` through a `sig/` type of another
   class), and `attr_reader :name, :code #: String` gave two rows with ordinals 0 and 1. Rigor's own
   `sig/rigor/trinary.rbs` read `sig` once the spike resolved sig roots with
   `Environment.project_signature_roots`. The configured `signature_paths` is nil under auto-discovery,
   which first made them read `library`.
7. **The raw rows need sig-gen's spelling layer.** The spike printed `Issue#initialize -> [] | nil`,
   `Issue#reload -> bot` and `"1=0" | String`. sig-gen's classification (`initialize` → `void`, bot
   handling) and `TypeElaborator` must sit between `DefReturnTyper` and the row. On redmine, 134 of 157
   inferred returns in `issue.rb` erase to `untyped`. Those slots need the `Dynamic` cause from ADR-75, or
   they say nothing.

## What this changes in the proposal

- Keep the forced-target recheck and the in-run callback. A lens's roots are `configuration.paths`, always.
- Do not promise an interactive warm lens on Rails apps until the template lever (finding 3) exists. For
  ZARD's sequential per-file queries this makes a multi-file invocation more important, not less: one
  process pays the warm floor once for every target.
- A cold lens costs a full `check`. On Rigor's own tree that is about 28 s at 4 workers.

## Limitations

- Wall times are single runs on one host, except where a range is shown (two or three runs). They size
  the levers; they are not a regression baseline.
- Diagnostic parity was checked on two redmine files, not on a corpus. The acceptance check in #1083 still
  needs redmine and mastodon in full.
- The template-skip probe was not checked for run-level rows or for snapshot effects beyond the
  throwaway cache.
- The instrument is the branch `lens-computation-spike` (`tool/lens_spike.rb` and the two opt-in hooks).
