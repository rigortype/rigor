# CLI editor mode — disk-backed `ProjectScan` snapshot cache

**Status:** Design note. Authored 2026-05-18. Implementation
**deferred** until concrete editor-extension demand surfaces. The
LSP path (in-memory `ProjectContext` + `Analysis::ProjectScan`,
landed v0.1.6) already addresses the typical editor case; this
note captures the implementation pathway for the CLI shell-out
niche so the next implementer can pick it up cold.

## Motivation

`rigor check --tmp-file=X --instead-of=Y lib` is the CLI surface
PHPStan-style editor extensions shell out to per buffer save (see
[`docs/design/20260516-editor-mode.md`](20260516-editor-mode.md)
§ "CLI surface"). Each invocation is a fresh process, so there is
no in-memory `ProjectContext` to share across calls. Measured
breakdown on a warm-cache call against rigor's own `lib/`
(2026-05-17 benchmark):

| Phase | Cost |
|---|---|
| Ruby + bundler boot + rigor library load | ~200 ms |
| `Environment.for_project` (disk cache hit) | ~300 ms |
| Pre-passes (`Plugin::Loader.load`, plugin `#prepare`, `DependencySourceInference::Builder.build`, `SyntheticMethodScanner.scan`, `ProjectPatchedScanner.scan`) | ~500 ms (project-size-dependent) |
| Buffer parse + `analyze_file` | ~50-100 ms |

**Total: ~1050 ms.** The boot floor (~500 ms cumulative) is
fundamental; the ~500 ms pre-pass cost is the addressable headroom.

A disk-backed snapshot would shave the pre-pass cost on warm hits,
bringing CLI editor mode to ~500 ms wall — competitive with
PHPStan's per-buffer feedback. The LSP path already achieves
≤ 5 ms per publish via the in-memory `ProjectScan` cache, so this
optimisation is **for the CLI shell-out niche only** (editors
without LSP support, or batch tooling).

## Implementation pathway

### Phase A — Marshal-friendly snapshot

The existing `Rigor::Analysis::ProjectScan` (v0.1.6) value object
bundles six slots; five are Marshal-friendly, one is not:

| Slot | Marshal-friendly? | Notes |
|---|---|---|
| `dependency_source_index` | ✅ | Plain Hash-of-CatalogEntry data. |
| `synthetic_method_index` | ✅ | Frozen Hash of frozen `SyntheticMethod` Data values. |
| `project_patched_methods` | ✅ | Frozen Hash. |
| `plugin_prepare_diagnostics` | ✅ | Array of `Diagnostic` Data values. |
| `pre_eval_diagnostics` | ✅ | Array of plain Hashes. |
| `plugin_registry` | ❌ | Plugin instances hold `Plugin::Services` with `Cache::Store` (Mutex), `IoBoundary` (Mutex), `Plugin::FactStore` (also mutable). |

**Solution.** Introduce
`Rigor::Analysis::MarshalableProjectScan` — the five Marshal-friendly
slots PLUS the per-plugin **published facts snapshot** the
`plugin_registry` carried indirectly (the `Plugin::FactStore`'s
state after `#prepare` ran). This drops the live plugin instances
and keeps only the data downstream dispatch tiers actually consult.

```ruby
MarshalableProjectScan = Data.define(
  :dependency_source_index,
  :synthetic_method_index,
  :project_patched_methods,
  :plugin_prepare_diagnostics,
  :pre_eval_diagnostics,
  :fact_store_snapshot  # Hash[plugin_id => Hash[fact_name => marshalable_value]]
)
```

On warm load:

1. Marshal-load the snapshot.
2. Call `Plugin::Loader.load(configuration:, services:)` to
   reconstruct `plugin_registry` (gems already required from
   prior runs — `Kernel.require` returns false; the cost is
   dominated by `Plugin.register` / `Blueprint` work, ~5-20 ms).
3. **Re-attach the snapshotted facts** to each plugin's
   `services.fact_store` so dispatch consumers see the published
   facts without re-running `#prepare`.
4. Build a runtime `ProjectScan` from the rehydrated
   `plugin_registry` + the unchanged snapshot slots.
5. Hand to `Runner.new(prebuilt: ...)`.

### Phase B — cache key derivation

A snapshot must invalidate when ANY project input that affects the
pre-pass outputs changes. The cache key candidates are:

```
SHA256(
  configuration_digest    # .rigor.yml + bundler / collection axes
  + plugin_manifest_digest # plugin gem version + per-plugin config
  + project_paths_digest   # `paths:`-expanded .rb files, mtime + size
  + pre_eval_paths_digest  # pre_eval: files, mtime + size
  + dependencies_digest    # dependencies.source_inference: config
)
```

`project_paths_digest` is the dominant cost: walking `paths:` for
mtime+size on every CLI invocation. For 5000 files, ~250 ms of
`File.stat` calls. **This nearly cancels the pre-pass savings on
large projects.** Two mitigations:

- **(α) Cheap pre-check via directory mtime.** Most filesystems
  update a directory's mtime when entries are added or removed
  (NOT when contents change). Walk only the `paths:` directories
  for their mtime → ~ms. If unchanged since the cached snapshot's
  build time, assume the file list is unchanged and skip the
  per-file mtime walk. Per-file mtime+size only kicks in when a
  directory's mtime changes. This is a fast-path optimisation
  the implementer should benchmark before adopting.
- **(β) Skip key derivation for buffer-only paths argument.**
  When `rigor check --tmp-file=X --instead-of=Y` is called with
  `paths:` defaulting to the configuration's project root, the
  derivation is unavoidable. When the caller passes ONLY a single
  file path (`rigor check --tmp-file=X --instead-of=Y lib/foo.rb`),
  the key only needs to cover what the pre-passes consume — still
  the whole project under `paths:`, because scanners walk the
  project. So (β) does NOT help; (α) is the right lever.

### Phase C — storage

Reuse `Rigor::Cache::Store` with a new producer:

```ruby
module Rigor
  module Cache
    class ProjectScanSnapshot
      PRODUCER_ID = "analysis.project_scan_snapshot"

      def self.fetch(loader:, store:, configuration:)
        descriptor = build_descriptor(configuration)
        store.fetch_or_compute(
          producer_id: PRODUCER_ID,
          params: {},
          descriptor: descriptor
        ) { build_fresh(configuration) }
      end

      def self.build_descriptor(configuration)
        Descriptor.new(
          configs: [config_entry(configuration)],
          files: project_path_file_entries(configuration) +
                 pre_eval_file_entries(configuration),
          plugins: plugin_entries(configuration)
        )
      end

      def self.build_fresh(configuration)
        # Spin up a project-only Runner (no buffer), call
        # prepare_project_scan, snapshot the fact_store, return
        # MarshalableProjectScan.
      end
    end
  end
end
```

The `Cache::Store` already handles Marshal round-trip, sharded
storage, per-file `flock`, and descriptor-based invalidation. The
new producer just needs to provide the descriptor + the fresh
build.

### Phase D — Runner integration

`Runner` already accepts `prebuilt:`. The CLI command path
threads through:

```ruby
def cli_run_check(configuration:, buffer_binding:)
  snapshot = Cache::ProjectScanSnapshot.fetch(
    loader: nil, store: cache_store, configuration: configuration
  )
  prebuilt = rehydrate(snapshot, configuration: configuration,
                       cache_store: cache_store)
  Runner.new(
    configuration: configuration,
    cache_store: cache_store,
    buffer: buffer_binding,
    prebuilt: prebuilt
  ).run([buffer_binding.logical_path])
end
```

`rehydrate` does the Plugin::Loader.load + fact_store reattach
described in Phase A.

### Phase E — Snapshot freshness on write

When the cache key indicates a miss, the fresh build runs
`Runner#prepare_project_scan` against a project-only runner, then
serialises:

- Snapshot the five Marshal-friendly slots verbatim.
- Snapshot the per-plugin fact_store: iterate
  `plugin_registry.plugins`, capture `plugin.services.fact_store.facts`
  (or whatever the FactStore's accessor exposes — may need a
  `#snapshot_for_cache` method on `Plugin::FactStore`).
- Marshal-friendly values only. A plugin publishing a non-
  Marshal-friendly fact (Mutex, Proc, etc.) breaks the snapshot —
  the producer should rescue and degrade to "no cache for this
  configuration", or the FactStore's snapshot method should
  raise a clear error pointing at the offending plugin.

## Open questions for the implementer

1. **FactStore snapshot API.** `Plugin::FactStore` currently
   doesn't expose a "serialise all published facts" surface. The
   right shape depends on whether the store keys facts per-plugin
   (it does, per ADR-9) and whether the values are constrained
   to Marshal-friendly types (no explicit constraint today). A
   small `Plugin::FactStore#to_snapshot` / `.from_snapshot`
   pair scopes the integration.
2. **Marshal-version stability.** `Cache::Store` already keys on
   `SCHEMA_VERSION` so a Ruby-version bump invalidates entries.
   The `MarshalableProjectScan` snapshot inherits this invariant.
3. **Plugin gem version pinning.** A plugin upgrade should
   invalidate the snapshot. Today's `Cache::Descriptor::PluginEntry`
   includes `version:` + `config_hash:` — the producer's
   descriptor must include one of these per plugin.
4. **Pre-pass diagnostic re-emission ordering.** The
   `plugin_prepare_diagnostics` snapshot must preserve the order
   the source plugins emitted them in so the CLI diagnostic
   stream stays stable across cold / warm runs. The Marshal
   round-trip preserves Array order — verify in the spec.
5. **Cache write contention.** Two `rigor check` invocations
   racing to write the snapshot would conflict on the
   producer's cache file. `Cache::Store` already handles this
   via per-file flock; the first writer wins, the second
   discards its computed value.

## Expected wins

| Project size | CLI editor-mode warm wall (today) | After snapshot cache | Δ |
|---|---|---|---|
| Trivial (no plugins) | ~500 ms | ~500 ms | 0 (pre-passes already cheap) |
| Small Rails (5 plugins) | ~700-900 ms | ~500-550 ms | -200 to -350 ms |
| Mid Rails (10 plugins + substrate) | ~1000-1500 ms | ~550-650 ms | -450 to -850 ms |
| Large monorepo (5000+ files, substrate-using plugins) | 2+ s | ~700 ms | > -1.3 s |

The win scales with plugin / substrate / file count.

## Why this is deferred

- **LSP covers 90%+ of editor cases.** `rigor lsp` (v0.1.6) is
  the recommended editor integration. Per-publish work is ≤ 5 ms
  warm. Editor extensions that can speak LSP should use that
  path.
- **Implementation surface area is significant.** Marshal
  friendliness of plugin facts is a NEW invariant the plugin
  contract would expose (or break opaquely). The decision
  about whether the FactStore enforces Marshal-friendliness
  or simply gracefully degrades is a substantive ADR-level
  question.
- **No concrete editor extension consumer exists today.** The
  CLI editor mode CLI shape shipped in v0.1.6 (`--tmp-file` /
  `--instead-of`), but no editor extension we know of is
  shelling out to it on save. When one surfaces and reports
  > 500 ms wall as a UX problem, this slice unblocks the
  improvement.

## Adjacent levers (lower priority)

- **In-memory `Environment.for_project` cache across LSP /
  CLI**. v0.1.6 already caches Environment in the LSP
  `ProjectContext`. The CLI cannot share that cache, but the
  Environment build itself is dominated by `Marshal.load` from
  the existing on-disk `Cache::RbsEnvironment` — already
  warm-cache optimised.
- **Reduce CLI boot cost.** ~200 ms boot is the Ruby +
  bundler + rigor library load. Eliminating it requires a
  persistent daemon (= LSP). Out of scope.

## Tracking

When this slice picks up:

- Update `docs/CURRENT_WORK.md` § "Open Engineering Items".
- Add a `CHANGELOG.md` entry under `[Unreleased]` § Performance.
- Reference this design note in the commit.
- Add `Plugin::FactStore#to_snapshot` / `.from_snapshot` to the
  `spec/rigor/public_api_drift_spec.rb` snapshot.
