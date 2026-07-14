# Incremental plugin-fact soundness — audit + implementation findings (2026-07-14)

Grounding note for [ADR-88](../adr/88-incremental-plugin-fact-soundness.md). Maps
the choke points the fix touches and records the investigation findings — including
two that diverged from the initial hypothesis.

## The gap

A `--incremental` recheck is gated by two mechanisms, neither of which sees a
plugin's cross-file contribution derived from files they do not track:

1. The **global snapshot fingerprint** — `Cache::IncrementalSnapshot.fingerprint`
   (`lib/rigor/cache/incremental_snapshot.rb`) digests the resolved configuration,
   the analysis roots, `Gemfile.lock` / `rbs_collection.lock.yaml`, and the
   project's own `signature_paths:` `.rbs` contents. It does NOT digest a plugin's
   `paths:` / `rbi_paths:` sig trees, a `db/schema.rb`, etc.
2. The **per-file dependency graph** — recorded through the `Scope` accessor choke
   points (`lib/rigor/scope.rb`: `user_def_for` at :372 records via
   `record_cross_file_method`; `superclass_of` / `includes_of` /
   `data_member_layout` record class-ancestry edges). A plugin reads its catalog
   INTERNALLY (`sorbet.rb`'s `io_boundary.read_file`), not through a choke point, so
   no edge is recorded.

Concretely: `rigor-sorbet` builds a catalog from `.rb`/`.rbi` sigs (default
`rbi_paths: sorbet/rbi`) and contributes `dynamic_return` types cross-file. Editing
an `.rbi` (not analyzed, not a signature path) changes the catalog — and every
consumer's inferred types — while the global fingerprint stays fresh and `ΔF` is
empty. The recheck serves the stale cached diagnostics. Same shape for the AR
`model_index` / `schema_table` producers and the rails-routes `helper_table`.

The ADR-45 whole-run cache is inert on these runs
(`Runner#run_result_cacheable?` excludes `record_dependencies` / `analyze_only`), so
it offers no accidental protection.

## The fix surface

- **WD1 fingerprint** — `lib/rigor/analysis/plugin_fact_fingerprint.rb` digests
  (a) `Plugin::FactStore#each_fact` publications, (b) each plugin's declared
  producer VALUES (`Plugin::Base#producer_value`), (c) an optional
  `Plugin::Base#incremental_state_fingerprint` hook. Rides the snapshot as
  `plugin_fact_digest` (`Payload` + `SCHEMA` 8→9). Compared in
  `IncrementalSession#run_incremental`.
- **WD2 sorbet producer** — `plugins/rigor-sorbet/lib/rigor/plugin/sorbet.rb`:
  `producer :catalog, watch: -> { catalog_watch_globs }`; `ensure_catalog` unpacks
  the cached bundle; `harvest_path` sorts its `Dir.glob`.
- **WD3 edge** — `lib/rigor/scope.rb#user_def_site_for` records
  `record_cross_file_method`.
- **WD4b loader fix** — `lib/rigor/plugin.rb` (`@gem_registrations`,
  `record_gem_registration` / `ids_for_gem`) + `lib/rigor/plugin/loader.rb`
  (`resolve_and_instantiate`).

## Finding 1 — the gitlab verify-red is a plugin-loader bug, not a producer

The initial hypothesis (producer cached-state ≠ fresh, or `Dir.glob`-order
nondeterminism) was **wrong**. `rigor check --verify-incremental app/models
app/controllers` on gitlab failed 1,161 incremental-only / 19 full-only, all `:info`
Action Pack recognition trace, and reproduced with a CLEARED cache (so not stale
disk state).

Root cause: the verify harness runs baseline → subset → full **in one process**, and
`verify_full_diagnostics` is a SECOND in-process `Plugin::Loader.load` of the same
bare-string plugin set. In `loader.rb#resolve_and_instantiate`, `require_gem!`
returns after the gem's body already ran on the first load, so `newly_registered =
(after - before)` is EMPTY; for a bare-string (`id:`-less) entry
`lookup_plugin_class!` then hits `when 0` → `"did not register any plugin"`
LoadError. The oracle silently loaded ZERO plugins → 101 diagnostics vs the correct
2,494. Isolation test (`baseline` then a fresh `Runner.new(cache_store: nil).run` in
one process) reproduced it directly (10 `load-error` diagnostics on the second run).

Fix: memoise `gem → registered ids` on the first load; recover it when a re-load's
`require` no-ops and the delta is empty (only for `id:`-less entries). After the fix
the second in-process run loads the same 10 plugins; gitlab verify is byte-identical
(887/1,774, 2,494, zero mismatch). This also fixes the incremental session's own
subset re-analysis (a second in-process load).

The WD2 glob sort still lands — it is real robustness against cross-environment
nondeterminism — but it was not the verify-red cause.

## Finding 2 — fingerprint the producer VALUE, not the cache blob

A first cut digested the producer's cache-entry BLOB (cheap: read the file, no
re-Marshal). It over-invalidates: the blob carries the dependency descriptor (the
input files' digests), so it moves on ANY input edit. Measured: a value-preserving
gitlab controller edit (adding a top-level constant) → `controller_index` blob
rewritten → snapshot invalidated → **23s full re-analysis vs ~9.5s incremental**.
Every Rails model/controller edit would defeat incremental.

Digesting the producer VALUE instead moves the fingerprint only when the contributed
value moves. Verified: with `--no-cache` (deterministic recompute) a value-preserving
controller edit leaves the fact-surface digest identical. This makes WD2's glob-sort
determinism load-bearing (a non-deterministic value would false-invalidate every
recompute) — all bundled producers were checked deterministic on recompute.

The apparent "producer nondeterminism" seen while diagnosing this was an ADR-87
racy-window artifact of rapid test edits (edit + immediately re-run within the mtime
racy guard); a settle delay makes warm rechecks deterministic.

## Finding 3 — compute the fingerprint post-hoc, not via a probe

A dedicated sequential `#prepare` probe (for pool-mode parity) measured ~1.0s on
gitlab (a second `#prepare` at 0.45s + a second producer validation/Marshal at
0.6s) — ~10% of a warm recheck. Reading the fingerprint POST-HOC from the analysis
runner's already-prepared registry (`PluginFactFingerprint.from_registry`) reuses the
recheck's prepare + its memoised producer values, dropping the overhead to ~0.24s
(≈2.5%). The probe survives only as the pooled-mode fallback (the pooled main
process skips `#prepare`); both paths compute the identical digest, so the decision
is pool-independent.

## Perf summary (gitlab app/models app/controllers, host)

| measurement | value |
|---|---|
| gitlab `--verify-incremental` before | FAILED (1,161 / 19) |
| gitlab `--verify-incremental` after | OK (887/1,774, 2,494 diagnostics, 0 mismatch) |
| warm-recheck fingerprint overhead (post-hoc) | ~0.24s (≈2.5% of ~9.5s) |
| value-preserving controller-edit recheck | stays warm (no over-invalidation) |
| Sorbet `.rbi` sig edit | snapshot invalidated → full re-analysis (WD4a) |

## Bundled-plugin opacity audit

Contributing plugins (register `dynamic_return` / `narrowing_facts`) and their WD1
surface: actionpack / activerecord / activestorage — producers (non-opaque);
sorbet — WD2 producer; minitest / rspec / mangrove + examples units / pattern /
lisp-eval — `incremental_state_fingerprint` sentinel (per-file / static
contributions, backstopped by `--verify-incremental`). activesupport-core-ext /
devise register no contributions (a grep matched a comment). No bundled plugin is
opaque; the opacity path is the forcing function for a third-party plugin that
contributes types without declaring a surface.
