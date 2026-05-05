# Cache Layer — `Rigor::Cache`

Status: **In progress (v0.0.8).** This document tracks the cache
layer's public read shape as it lands. The first slice — the
`Rigor::Cache::Descriptor` value object — is the substrate every
cached value attaches to. Subsequent slices add the storage backend
(`Rigor::Cache::Store`), the first cached producer (the RBS
environment loader), and the CLI observability flags
(`--cache-stats`, `--clear-cache`).

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

## `Rigor::Cache::Store` (v0.0.8 slice 2 — pending)

To be documented when the slice lands. ADR-6 § "Decisions in
detail" already fixes the contract:

- `.rigor/cache/<producer-id>/<key-prefix>/<key-suffix>.entry`
  layout.
- `"RIGOR\0\1"` magic + format version + descriptor + value +
  trailing SHA-256 file format.
- Rename-into-place atomicity; per-file `flock` for writes.
- Schema-version directory marker.

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
