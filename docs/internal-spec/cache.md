# Cache Layer — `Rigor::Cache`

Status: **In progress (v0.0.8).** This document tracks the cache
layer's public read shape as it lands. Slices 1–2 are in place:
`Rigor::Cache::Descriptor` (the substrate every cached value
attaches to) and `Rigor::Cache::Store` (the filesystem-backed
storage that consumes a descriptor + producer + params and
returns a cached or freshly computed value). Subsequent slices
add the first cached producer (the RBS environment loader) and
the CLI observability flags (`--cache-stats`, `--clear-cache`).

The schema this module implements is fixed by:

- **[`docs/design/20260505-cache-slice-taxonomy.md`](../design/20260505-cache-slice-taxonomy.md)** — per-slot entry shapes, composition rules, cache-key derivation, granularity guidance.
- **[`docs/adr/6-cache-persistence-backend.md`](../adr/6-cache-persistence-backend.md)** — backend choice (sharded directory of binary entries), file format, atomicity, locking, eviction policy.

## `Rigor::Cache::Descriptor` (v0.0.8 slice 1)

The cache invalidation descriptor — a pure value object with four
slots, every slot an array of typed entries.

### Slot entries

```
FileEntry   :: { path: String, comparator: :digest|:mtime|:exists, value: String }
GemEntry    :: { name: String, requirement: String, locked: String? }
PluginEntry :: { id: String, version: String, config_hash: String? }
ConfigEntry :: { key: String, value_hash: String }
```

Each entry is constructed via keyword arguments and frozen
immediately. `FileEntry#new` validates the comparator enum and
raises `ArgumentError` on unknown values; the other entries
accept any string content (their values are already-canonical
hashes by convention).

### `Descriptor.new(files: [], gems: [], plugins: [], configs: [])`

Constructs a descriptor. Every slot defaults to an empty array;
slots are duped and frozen so callers cannot mutate after
construction. The descriptor itself is also frozen.

### `Descriptor.compose(*descriptors) -> Descriptor`

Composes any number of descriptors into a single descriptor. The
composition rule per slot is **union by key**:

- `files` group by `path`. Entries within a group prefer the
  **stricter** comparator (`:digest > :mtime > :exists`); among
  the strictest, all entries must agree on `value` or
  `Descriptor::Conflict` is raised.
- `gems` group by `name`. All entries within a group must be
  structurally equal under `(requirement, locked)`; otherwise
  `Conflict` is raised.
- `plugins` group by `id`. Same equality rule on
  `(version, config_hash)`.
- `configs` group by `key`. Same equality rule on `value_hash`.

A single contributor that adds duplicate equal entries to its
own descriptor is harmless — `compose` collapses them. Conflicts
are exceptional; callers (the cache layer) treat `Conflict` as
"this cache slice cannot be reused, drop it" rather than
choosing one contribution silently.

### `descriptor.cache_key_for(producer_id:, params: {}) -> String`

Returns the canonical hex SHA-256 cache key for a producer +
input + descriptor combination. The key incorporates:

1. `Descriptor::SCHEMA_VERSION` (currently `1`). Bumping this
   constant invalidates every cached value.
2. `producer_id` (a stable string that namespaces the cache
   slice).
3. `params` (the producer's input hash). Recursively
   canonicalised: hash keys stringify and sort, symbols
   stringify, arrays preserve order.
4. The descriptor's canonical hash form.

Two callers building structurally equivalent descriptors with
the same `producer_id` and `params` produce identical cache
keys, regardless of construction order.

### `descriptor.to_canonical_bytes -> String`

Returns the descriptor as a canonical-JSON byte string (UTF-8,
binary-encoded for transport). Slots appear in lexicographic
order (`configs`, `files`, `gems`, `plugins`); entries within
each slot are sorted by their key field (`path` for files, etc.)
so two equivalent descriptors produce identical bytes.

### Equality and hashing

`Descriptor#==` compares canonical-byte forms, so two descriptors
built in different orders compare equal. `#hash` is consistent
with `==` so descriptors are usable as Hash keys.

## Stability

The constructor signatures and composition semantics are stable
as a v0.0.x public read shape. Adding new slot kinds (e.g.
`env_vars`) is a schema-version bump per the taxonomy doc and
ADR-6. Adding new comparators to `FileEntry::VALID_COMPARATORS`
is additive and does not require a bump.

The persistence layer ([`Rigor::Cache::Store`](#cache-store-v008-slice-2),
v0.0.8 slice 2) and the cached-producer integrations follow.
This document is updated as each slice lands.

## `Rigor::Cache::Store` (v0.0.8 slice 2)

Filesystem-backed cache store. ADR-6 § "Decisions in detail" fixes
the contract; this section documents the public read shape that
producers and the CLI consume.

### `Store.new(root:)`

Constructs a store rooted at `root` (a directory path, typically
`.rigor/cache`). The directory is not created eagerly — the first
write materialises it along with the `schema_version.txt` marker.

### `store.fetch_or_compute(producer_id:, params:, descriptor:) { ... } -> Object`

The single producer-facing entry point.

- `producer_id` (String) — the cache namespace. Only
  `[a-z][a-z0-9._-]*` is accepted. The constraint guarantees
  filesystem-friendly directory names on case-insensitive
  filesystems.
- `params` (Hash) — the producer's input arguments. Mixed into
  the cache key via {Descriptor#cache_key_for}; producers do not
  derive cache keys themselves.
- `descriptor` ([`Rigor::Cache::Descriptor`](#rigorcachedescriptor-v008-slice-1))
  — the invalidation descriptor for the cached value.
- The block (`yield`) is invoked **only on cache miss**. Its
  return value is `Marshal.dump`-ed and stored.

Returns the cached value (loaded from disk on hit; produced by
the block on miss).

### Read fault tolerance

A read encountering any of the following silently returns a
cache miss; the producer block reruns and the next write
overwrites the bad entry:

- Missing entry file.
- Entry shorter than the minimum envelope (header + trailer).
- Mismatched magic + format-version header.
- Mismatched trailing SHA-256.
- Malformed varint length prefix.
- `Marshal.load` raises (e.g. unknown class on the receiving
  side, truncated payload, ABI skew).

The trailing SHA-256 catches accidental corruption (partial
writes from process kills, FS errors). It is **not** a security
boundary, per ADR-2's trusted-gem trust model.

### Schema-version marker

`<root>/schema_version.txt` carries a single integer — currently
`Rigor::Cache::Descriptor::SCHEMA_VERSION`. On every
`fetch_or_compute` call:

- Marker missing → write the current version, proceed.
- Marker matches → proceed.
- Marker disagrees → wipe every entry under `<root>` (`unlink`
  every child via `FileUtils.rm_rf`), rewrite the marker, and
  proceed as if the cache were empty.

A bump of `SCHEMA_VERSION` therefore drops every cache file on
the next run without any explicit migration step.

### On-disk layout

```
<root>/
  schema_version.txt
  <producer-id>/
    <ab>/
      <ab1234567890…>.entry
```

The cache key (a 64-character hex SHA-256 from
`descriptor.cache_key_for(...)`) splits into a 2-character
prefix and a 62-character suffix to keep per-directory fan-out
manageable on busy producers.

### Atomicity and locking

Writes follow the standard rename-into-place dance:

1. `mkdir -p` the destination directory.
2. Acquire `flock(LOCK_EX)` on the destination file (creating
   it with `O_CREAT|O_RDWR` if necessary).
3. Write the body to a sibling temp file
   (`<entry>.tmp.<pid>.<rand-hex>`).
4. `fsync` the temp file.
5. `rename` the temp file over the destination.
6. Release the lock by closing the destination file descriptor.

Readers do not lock; they tolerate seeing an old version (always
a fully committed entry, never a torn write — POSIX guarantees
`rename` atomicity on the same filesystem). A reader that catches
a brief window where the destination file exists but is empty
(between `O_CREAT` and the first successful `rename`) treats it
as a cache miss per the read fault-tolerance rules above.

### File format

A single entry file is laid out as:

```
"RIGOR\x00\x01"      6 bytes — 5-byte magic, 1-byte separator, 1-byte format version
varint               byte length of the descriptor payload
descriptor payload   canonical-JSON Descriptor (UTF-8, binary-encoded for transport)
varint               byte length of the value payload
value payload        Marshal.dump of the producer-returned object
sha256               32 bytes — integrity hash of every preceding byte
```

Descriptor and value are stored separately so a future cache-
inspection tool can read just the descriptor without paying the
`Marshal.load` cost. The format version (currently `1`) is
distinct from `Descriptor::SCHEMA_VERSION` — the former covers
the byte layout, the latter the descriptor schema. Bumping the
format version invalidates entries on the read path (header
mismatch → cache miss).

## RBS environment cache (v0.0.8 slice 3 — pending)

The first real cache producer. Caches the result of
`RbsLoader#build_env` keyed by signature-path file digests, the
`libraries:` list, and the `rbs` gem locked version.

## CLI observability (v0.0.8 slice 4–5 — pending)

`rigor check --cache-stats` reports per-producer hit/miss counts
at the end of the run. `rigor check --clear-cache` removes
`.rigor/cache` entirely.

## Diagnostic provenance (v0.0.8 slice 6 — pending)

Companion slice. `Rigor::Analysis::Diagnostic` gains a
`source_family` field defaulting to `:builtin`; the formatter
optionally prepends the source-family prefix (`plugin.<id>`,
`rbs_extended`, `generated.<provider>`) to the rule id. Prepares
ADR-2's plugin-observability story without committing to the
plugin API itself.
