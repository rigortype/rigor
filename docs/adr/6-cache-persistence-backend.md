# ADR-6: Cache Persistence Backend

## Status

Draft. Working decision recorded so the v0.0.8 cache persistence
slice has a fixed target. Will be ratified once the first
producer (the RBS environment cache) lands.

## Context

[ADR-2 § "Registration, Configuration, and Caching"](2-extension-api.md)
commits Rigor to a persistent cache between `rigor check` runs and
fixes the **schema** of the cache invalidation descriptor: a typed
four-slot `(files, gems, plugins, configs)` shape, expanded in
[`docs/design/20260505-cache-slice-taxonomy.md`](../design/20260505-cache-slice-taxonomy.md)
into per-slot entry definitions, composition rules, and a canonical
cache-key derivation.

The schema is storage-agnostic by design — the taxonomy doc closes
with:

> The on-disk format (sqlite, msgpack, single-file flat, sharded
> directory, …) is out of scope for this draft. The schema below is
> storage-agnostic.

This ADR resolves that open question for the v0.0.8 first
implementation. The choice constrains everything that follows: the
producer-facing API, the locking model, the eviction policy, and
the dependency footprint that the gemspec advertises.

## Working Decision

**The first cache backend is a sharded directory of msgpack files.**
One file per cache slice, paths derived from the canonical cache
key (`.rigor/cache/<producer-id>/<key-prefix>/<key-suffix>.msgpack`).
The cache layer ships with **zero new gem dependencies** for the
first implementation: msgpack serialisation is replaced by a
custom canonical-binary format the cache layer writes itself.

A pure-Ruby fallback path stays available for environments where
the binary format cannot be read (corrupt entry, schema-version
mismatch); reads that fail to deserialise are treated as cache
misses, the entry is dropped, and the producer reruns.

## Trade-off summary

The three candidate backends were:

| Backend | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **sqlite** | Atomic writes, query power, well-tested concurrent reads, easy size cap via `VACUUM`. | Adds the `sqlite3` gem (with C extension); locking semantics have surprising corners under multi-process. The query power exceeds what the cache schema needs (we look up by key, not by predicate). | **Rejected for v0.0.8.** Reconsidered if sharded directory hits scale issues. |
| **msgpack single-file** | Compact binary; one file is easy to lock. | Requires the `msgpack` gem (or a hand-rolled subset). Whole-cache rewrites on every change scale poorly past ~100 entries. | **Rejected for v0.0.8.** The whole-cache rewrite is the disqualifier. |
| **Sharded directory** | One file per slice → partial invalidation is a literal `unlink`; reads are independent and scale linearly with hit cardinality; no new gem dependency if the cache layer writes its own canonical format. | More inodes; concurrent writes need per-file locking, not a single global lock. | **Selected for v0.0.8.** |

## Decisions in detail

### 1. Layout

```
.rigor/cache/
  schema_version.txt
  <producer-id>/
    <ab>/
      <ab1234567890…>.entry
```

- `schema_version.txt` carries a single integer — the schema
  version from the cache slice taxonomy. Bumping it implicitly
  invalidates every cache file (the cache layer reads the version
  before reading any entry; a mismatch drops the directory).
- `<producer-id>` is the producer's identifier. Each producer
  owns its own subtree; there is no cross-producer file.
- The cache key (canonical-JSON-then-SHA-256 per the taxonomy doc)
  is split into a 2-character prefix and a 62-character suffix
  for filesystem-friendly fan-out.

### 2. File format

A cache entry is a single binary file with this layout:

```
"RIGOR\0\1"          - magic (5 bytes) + format version (1 byte)
length (varint)      - byte length of the descriptor payload
descriptor payload   - canonical-JSON-encoded Descriptor (UTF-8)
length (varint)      - byte length of the value payload
value payload        - producer-defined bytes (typically Marshal.dump)
sha256 (32 bytes)    - integrity check over the prior bytes
```

- The magic + version pair lets future format migrations detect
  old files cheaply and treat them as misses.
- Descriptor is stored separately from the value so cache
  validation can read just the descriptor (cheap) without
  deserialising the value.
- The trailing SHA-256 is a defence against partial-write
  corruption (truncated writes from process kills); it is **not**
  a security boundary, per ADR-2's trusted-gem model.
- Producer values use `Marshal.dump` by default because Rigor's
  type carriers are immutable value objects whose `Marshal` round-
  trip is well-defined; a producer that returns
  marshal-incompatible objects (e.g. raw `IO`) MUST register a
  custom serialiser.

### 3. Atomicity

Writes follow the standard rename-into-place dance:

1. `mkdir -p` the destination directory.
2. Write to a sibling temp file (`<key>.entry.tmp.<pid>.<rand>`).
3. `fsync` the temp file.
4. `rename` over the destination.

POSIX guarantees that `rename` is atomic on the same filesystem.
A reader that sees a partial entry has either an old (committed)
file or no file (no entry yet) — never a torn write.

### 4. Locking

Per-file: a producer about to write acquires `flock(LOCK_EX)` on
the destination file (creating it if necessary). Readers do not
lock; they tolerate seeing an old version, since the cache layer
is best-effort and a stale entry simply triggers a reread on next
cache check.

### 5. Eviction

The first implementation does **not** evict. The cache grows
unbounded; `rigor check --clear-cache` removes the whole
`.rigor/cache` directory. A future ADR-amendment introduces an
LRU policy with a configurable byte cap when project size makes
unbounded growth a problem. Defer the policy to keep the v0.0.8
slice tractable.

### 6. Concurrency model

v0.0.8 shipped with a single-writer model: one `rigor check`
run at a time per project. Concurrent runs MAY use the same
cache directory, but per-file locks serialise writes and the
result is correct (every reader gets either a committed entry
or a miss). No coordinator process; no shared in-memory state.

**v0.1.4 in-process layer.** `Cache::Store` now keeps a
process-local in-memory memo (commit `5c30b37`) so repeated
`fetch_or_compute` calls in the same process skip the disk
read AND the `Marshal.load` deserialise step on the warm
path. A re-entrant `Monitor` (commit `31e95c8`) guards the
memo + the hit / miss / write counters so the Store is safe
under concurrent access from worker threads or Ractors.

**ADR-15 boundary — cross-Ractor sharing.**
[ADR-15](15-ractor-concurrency.md) designates `Cache::Store`
as **the** cross-Ractor sharing point for cached values: each
Ractor in the worker pool holds its own per-process inference
cache (Environment cache layer), but reads through a shared
`Cache::Store`. The current implementation isn't yet
`Ractor.shareable?` (Monitor + Hash + counter ivars block it);
Phase 4 of the migration will decide whether to:

(a) make `Cache::Store` directly `Ractor.shareable?` by
    replacing the Monitor with a Ractor-friendly primitive,
(b) wrap it in a thin `Ractor.shareable?` proxy that forwards
    calls into the underlying Store via `Ractor.send`, or
(c) shard the Store into one per-Ractor mutable instance
    sharing a frozen on-disk root (the simplest path; see
    ADR-15 § OQ1).

The decision will land in Phase 4 of the Ractor migration;
this entry records the constraint so future Cache::Store work
does not accidentally move the design AWAY from
shareability.

Long-running daemons / LSP-mode is a separate v0.1.0+ surface
that benefits from both the in-process memo (already in
place) and the Phase 4 cross-Ractor shareability work.

### 7. Producer API surface

```ruby
Rigor::Cache::Store.new(root: ".rigor/cache").fetch_or_compute(
  producer_id: "reflection.instance_method_definition",
  params: { class_name: "Hash", method_name: :fetch },
  descriptor: descriptor_value,
) do
  # build the cached value
end
```

- `producer_id` is a stable string. Never write a value under a
  producer id you do not own.
- `params` are the inputs the producer was called with. Mixing
  them into the cache key is the cache layer's responsibility,
  not the producer's.
- `descriptor` is the `Rigor::Cache::Descriptor` value object.
- The block runs only on cache miss.

The first producer wired through this API in v0.0.8 is the RBS
**translated-constant table** — a `Hash<String, Rigor::Type>`
keyed by every constant name declared in the loaded RBS
environment, materialised once and reused. It is not the single
largest cold-start cost (that is `RBS::EnvironmentLoader#build_env`
itself), but it is the largest cost the cache machinery can
consume **without a custom serialiser**: see § "RBS::Environment
serialisation" below. Other producers (reflection, scope index,
catalog loaders) follow in subsequent v0.0.8 slices or v0.0.9.

### 8. RBS::Environment serialisation

`RBS::Environment` and its transitive AST nodes carry
`RBS::Location` instances. `RBS::Location` is a C-extension
class without `_dump_data`/`_load_data`, so naive `Marshal.dump`
fails with `TypeError`. Caching `RBS::Environment` itself
therefore requires either:

- A custom-serialiser surface on the cache `Store` (a producer
  registers `dump`/`load` callables alongside `fetch_or_compute`),
  plus a serialiser that strips and reconstructs `RBS::Location`
  / `RBS::Buffer`; or
- A schema-stable intermediate representation (every relevant RBS
  node walked into a Marshal-safe shape).

Both are substantial work and out of scope for the v0.0.8 slice
budget. The v0.0.8 first producer therefore caches a
**post-translation** artefact (`Rigor::Type` values, which are
plain frozen value objects with well-defined `Marshal` round-
trips). Subsequent slices reconsider the custom-serialiser route
once a real cold-start regression motivates the work.

## Rejected and Deferred Candidate Decisions

| Candidate | Status | Reason |
| --- | --- | --- |
| sqlite as v0.0.8 backend | Rejected | Adds the `sqlite3` gem dependency (C extension) for query power the schema does not need. Reconsider if sharded-directory I/O cost dominates. |
| Single msgpack file | Rejected | Whole-cache rewrites on every change scale poorly past ~100 entries. |
| Cross-machine cache sharing | Deferred | Out of scope for v0.0.8. The schema is path-relative so a cache built on one machine can be moved to another with the same project / gem state, but Rigor does not coordinate that. |
| LRU eviction policy | Deferred | First implementation is unbounded; users run `--clear-cache` if needed. |
| Long-running-daemon / LSP cache mode | Deferred | Separate v0.1.0+ surface. |
| `msgpack` gem dependency | Rejected | The cache layer writes its own canonical binary format to keep the zero-runtime-dependency property. |
| `marshal` for descriptor payload | Rejected | Descriptor is canonical JSON so two equivalent descriptors built by different code paths produce identical bytes; `Marshal` does not guarantee that across Ruby versions. |
| Cache integrity as a security boundary | Rejected | Per ADR-2's trusted-gem model, plugins are trusted Ruby code. The trailing SHA-256 catches accidental corruption (partial writes, FS errors), not malicious tampering. |

## Open Questions

- **`Cache::Store` `Ractor.shareable?` compliance.** Phase 4 of
  the [ADR-15](15-ractor-concurrency.md) Ractor migration
  needs the Store to be Ractor-shareable so multiple worker
  Ractors can read through it. The current implementation is
  Monitor-safe but not Ractor-shareable. Decision deferred to
  Phase 4 (see ADR-15 § OQ1 for the three candidate
  approaches). The constraint is recorded so future Cache::Store
  work does not silently move the design AWAY from
  shareability.
- **Filesystem case sensitivity.** Producer ids and cache keys
  use only `[a-z0-9._-]` so case-insensitive filesystems (macOS
  HFS+, NTFS) do not cause collisions. The cache layer
  enforces this character set at write time.
- **Symlinks / network filesystems.** v0.0.8 assumes the cache
  root is a real local directory. NFS / network FS works but
  the `flock` semantics are FS-specific; we do not test NFS in
  v0.0.8.
- **Schema-version migration UX.** A bump invalidates the whole
  cache. Should the cache layer emit a one-line `:info`
  diagnostic on first detection? Working answer: yes, but the
  diagnostic is gated behind `--cache-stats` until v0.1.0.

## Consequences

Positive:

- Zero new gem dependencies; the `rigortype` gem stays at the
  current `(prism, rbs)` runtime surface.
- Cache reads and writes are O(per-slice), not O(whole-cache);
  partial invalidation is `unlink` of one file.
- The on-disk layout is human-inspectable through `ls
  .rigor/cache` and `xxd <entry>`.

Negative:

- More inodes than a single-file backend.
- Per-file locking semantics are FS-dependent; macOS / Linux are
  the supported targets, Windows requires a follow-up
  evaluation.
- No size cap in v0.0.8. Users on tiny disks need to clear the
  cache manually.

## Reading order for a returning implementer

1. [ADR-2 § "Registration, Configuration, and Caching"](2-extension-api.md) — the schema-level decisions this ADR builds on.
2. [`docs/design/20260505-cache-slice-taxonomy.md`](../design/20260505-cache-slice-taxonomy.md) — per-slot detail, composition, cache-key derivation.
3. This ADR — backend choice, file format, atomicity, locking, eviction.
4. [`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md) — where the cache slice fits in the v0.1.0 sequencing.
