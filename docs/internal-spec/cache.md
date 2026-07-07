# Cache Layer — `Rigor::Cache`

Status: **Stable (introduced v0.0.8; current descriptor schema v4).**
This document tracks the cache layer's public read shape. The
slices below all landed and are stable across v0.1.x; the descriptor
`SCHEMA_VERSION` was bumped to `2` for the ADR-10 per-gem-version
`dependencies` slot, to `3` when `RbsLoader.build_env_for` began
synthesizing missing `signature_paths:` namespaces (so an RBS env
marshalled by an older Rigor — which would leave those signatures
inert — is rebuilt), and to `4` when [ADR-60](../adr/60-pre-freeze-plugin-contract-consolidation.md)
WD3 added the `globs` slot (`GlobEntry`) for the record-and-validate
plugin-producer cache. Slices 1–2 are in place:
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

The cache invalidation descriptor — a pure value object with six
slots, every slot an array of typed entries.

### Slot entries

```
FileEntry       :: { path: String, comparator: :digest|:mtime|:exists, value: String }
GemEntry        :: { name: String, requirement: String, locked: String? }
PluginEntry     :: { id: String, version: String, config_hash: String? }
ConfigEntry     :: { key: String, value_hash: String }
DependencyEntry :: { gem_name: String, gem_version: String, mode: :disabled|:when_missing|:full }
GlobEntry       :: { root: String, pattern: String, value: String }
```

Each entry is constructed via keyword arguments and frozen
immediately. `FileEntry#new` validates the comparator enum and
`DependencyEntry#new` validates the `mode` enum, each raising
`ArgumentError` on an unknown value; the other entries accept any
string content (their values are already-canonical hashes by
convention). `DependencyEntry` is the ADR-10 per-gem-version slot:
its `(gem_name, gem_version, mode)` triple keys the opt-in
dependency-source-inference cache slice so a `Gemfile.lock` bump or a
`source_inference:` mode change ([`dependency-source-inference.md`](dependency-source-inference.md)) invalidates exactly the affected gems.
`GlobEntry` is the ADR-60 WD3 record-and-validate slot: its `value`
is a digest of every file matching `root`/`pattern` (built via
`GlobEntry.compute`), re-validated by re-globbing so a plugin producer's
`watch:` glob coverage stays fresh across edits.

### `Descriptor.new(files: [], gems: [], plugins: [], configs: [], dependencies: [], globs: [])`

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
- `dependencies` group by `gem_name`. Same equality rule on
  `(gem_version, mode)`.
- `globs` group by `slot_key` (`root` + `pattern`). Same equality
  rule on `value`.

A single contributor that adds duplicate equal entries to its
own descriptor is harmless — `compose` collapses them. Conflicts
are exceptional; callers (the cache layer) treat `Conflict` as
"this cache slice cannot be reused, drop it" rather than
choosing one contribution silently.

### `descriptor.cache_key_for(producer_id:, params: {}) -> String`

Returns the canonical hex SHA-256 cache key for a producer +
input + descriptor combination. The key incorporates:

1. `Descriptor::SCHEMA_VERSION` (currently `4` — v2 added the
   `dependencies` slot for the ADR-10 per-gem-version cache slice;
   v3 invalidates RBS envs marshalled before `build_env_for` began
   synthesizing missing `signature_paths:` namespaces; v4 added the
   `globs` slot for the ADR-60 WD3 record-and-validate plugin-producer
   cache). Bumping this constant invalidates every cached value.
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
order (`configs`, `dependencies`, `files`, `gems`, `globs`,
`plugins`); entries within each slot are sorted by their key field
(`path` for files, `(root, pattern)` for globs, etc.) so two
equivalent descriptors produce identical bytes.

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

### `Store.new(root:, read_only: false, max_bytes: nil)`

Constructs a store rooted at `root` (a directory path, typically
`.rigor/cache`). The directory is not created eagerly — the first
write materialises it along with the `schema_version.txt` marker.
`read_only:` suppresses every write (so a worker can share a parent's
cache without racing it); `max_bytes:` caps the on-disk size and
arms the LRU `#evict!` pass (the production default is 256 MB, set by
the CLI per [ADR-54](../adr/54-cache-slimming.md) WD3 — `nil` here
leaves the cache unbounded).

Every `fetch_or_compute` / `fetch_or_validate` call first resolves the disk
tier's availability for the Store's lifetime (memoized after the first
check — see "Schema-version marker" below): unavailable means the
producer block still runs and its result still lands in the
in-process memo, but no disk read or write is attempted. This covers
two situations — a read-only store facing a marker it must not trust,
and a writable store whose cache root cannot be read/repaired
(permission error, disk full, deleted root, read-only mount) — neither
of which may ever break an analysis run.

### `store.fetch_or_compute(producer_id:, params:, descriptor:, serialize: nil, deserialize: nil) { ... } -> Object`

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
- `serialize` (callable, optional) — turns the producer's return
  value into a binary `String`. Defaults to `Marshal.dump(value).b`.
  Producers whose return values are not `Marshal`-clean (RBS-
  native objects with `RBS::Location` members, raw `IO`, …) MUST
  provide a serialiser.
- `deserialize` (callable, optional) — turns bytes back into the
  producer's value. Defaults to `Marshal.load`. The pair
  `(serialize, deserialize)` MUST round-trip — a producer that
  reads with one strategy and writes with another corrupts its
  own cache slice. Any exception (`StandardError`) raised by
  the deserialiser is treated as a cache miss; the entry is
  considered corrupt, the producer block reruns, and the next
  write overwrites it. This matches the read fault-tolerance
  rules below.
- The block (`yield`) is invoked **only on cache miss**.

Returns the cached value (loaded from disk on hit; produced by
the block on miss).

### `store.fetch_or_validate(producer_id:, key_descriptor:, params: {}, serialize: nil, deserialize: nil) { ... } -> Object`

The record-and-validate variant ([ADR-45](../adr/45-unchanged-project-fast-path.md)).
Unlike `fetch_or_compute` — which keys the entry on the descriptor of
its inputs, so every input MUST be known before the producer runs —
this keys on `key_descriptor` (only the stable inputs known up front)
and stores, alongside the value, a `dependency_descriptor` of the
files the value actually read, **including inputs discovered DURING
the computation** (e.g. a plugin reading a project file mid-analysis).
The block MUST return `[value, dependency_descriptor]`. On the next
run the stored dependency descriptor is re-validated against the
filesystem via `Descriptor#fresh?` — every recorded `FileEntry` /
`GlobEntry` must still match — and a stale dependency forces a
recompute. A write that is not `Marshal`-clean (or any disk error)
is swallowed: the freshly-computed value is returned and the next run
recomputes. This is the sound successor to a pre-analysis fingerprint,
which would go stale when a plugin reads files Rigor cannot see up
front.

`Descriptor#fresh?` considers a descriptor fresh only when its
`gems` / `plugins` / `configs` / `dependencies` slots are all empty
(those non-file inputs belong in the cache *key*, not the validated
set); a descriptor carrying any of them is never fresh.

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

`<root>/schema_version.txt` carries
`Store.schema_marker_value` —
`"<PAYLOAD_ABI_VERSION>.<Descriptor::SCHEMA_VERSION>.<Store::FORMAT_VERSION>"`,
where `PAYLOAD_ABI_VERSION` is `Rigor::VERSION`. Three invalidation
axes fold into one marker: the installed Rigor release (an entry's
Marshal payload is a blob of Rigor/RBS objects, so a release upgrade
is an ABI boundary even when neither of the other two versions
changes — this is the same axis `IncrementalSnapshot`'s fingerprint
already covers), the descriptor schema, and the on-disk byte layout.

Checked at most once per `Store` instance (the result is memoized as
the boolean "is the disk tier available" — see `Store.new` above),
with different semantics for a writable vs. a read-only store:

**Writable store:**

- Marker missing → write the current value, proceed. Disk available.
- Marker matches → proceed. Disk available.
- Marker disagrees → wipe every entry under `<root>` (`unlink` every
  child via `FileUtils.rm_rf`), rewrite the marker, and proceed as if
  the cache were empty. Disk available.
- Any filesystem failure while checking or repairing the marker
  (permission error, disk full, deleted root) → disk unavailable for
  this Store's lifetime; no partial repair is left in place beyond
  whatever the failing call itself did.

**Read-only store** (LSP / editor mode, see `docs/design/20260516-editor-mode.md`):
never touches the root — no `mkdir`, no marker write, no destructive
clear on mismatch. Disk is available ONLY when the on-disk marker is
present and matches current exactly; a missing or stale marker (e.g.
a Rigor upgrade with no writable run yet) reports unavailable rather
than risk unmarshalling a payload from a different ABI. The next
writable run repairs the cache as above.

A version bump therefore drops every cache file on the next writable
run without any explicit migration step — the Rigor-version axis
means this now happens on every release upgrade, at the cost of a
cold rebuild on the first writable run after upgrading. The
format-version axis matters for disk reclamation independently of
that: a format bump alone makes old entries unreadable (header
mismatch → miss) but would never delete them — they can sit below
the eviction cap indefinitely. The marker mismatch is what reclaims
their bytes (ADR-54).

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
6. Best-effort `fsync` of the destination directory (some
   platforms cannot fsync a directory; failure is ignored).
7. Release the lock by closing the destination file descriptor.

If the write or rename fails partway through, the temp file from
this attempt is removed on the way out (`ensure`) rather than left
for the sweep below to find later.

Readers do not lock; they tolerate seeing an old version (always
a fully committed entry, never a torn write — POSIX guarantees
`rename` atomicity on the same filesystem). A reader that catches
a brief window where the destination file exists but is empty
(between `O_CREAT` and the first successful `rename`) treats it
as a cache miss per the read fault-tolerance rules above.

### File format

A single entry file is laid out as:

```
"RIGOR\x00\x02"      7 bytes — 5-byte magic, 1-byte separator, 1-byte format version
varint               byte length of the descriptor payload
descriptor payload   canonical-JSON Descriptor (UTF-8, binary-encoded for transport)
varint               byte length of the value payload
value payload        zlib-deflated serialised bytes (Marshal.dump by default)
sha256               32 bytes — integrity hash of every preceding byte
```

Descriptor and value are stored separately so a future cache-
inspection tool can read just the descriptor without paying the
inflate + `Marshal.load` cost. The format version (currently `2`)
is distinct from `Descriptor::SCHEMA_VERSION` — the former covers
the byte layout, the latter the descriptor schema. Bumping the
format version invalidates entries on the read path (header
mismatch → cache miss).

Format v2 ([ADR-54](../adr/54-cache-slimming.md) WD2) deflates
the value payload on write and inflates on read; the descriptor
payload and the SHA-256 trailer (computed over the stored,
compressed bytes) are unchanged. Compression is invisible to
producers: a custom `serialize:` / `deserialize:` pair still
round-trips its exact bytes. v1 entries fail the header check
and read as silent misses — no migration.

### Compaction (`#evict!`)

`evict!` is a no-op on a read-only store. Otherwise it runs three
passes, in order:

1. **Stale temp-file cleanup.** Any `*.tmp.*` sibling older than
   one hour is unlinked. Under normal operation `atomically_replace`
   never leaves one behind (see "Atomicity and locking" above); this
   is a backstop for a process that died between the temp-file
   write and the rename.
2. **Whole-project generation cap.** Some producers are
   content-keyed (the cache key is a function of the value's
   dependencies, not a stable per-project key), so re-running with
   different inputs writes a new entry and leaves the old one
   unreachable — but still on disk. A small hardcoded allow-list of
   whole-project producer ids
   (`rbs.environment`, `rbs.class_ancestor_table`,
   `rbs.class_type_param_names`, `rbs.constant_type_table`,
   `rbs.known_class_names`, `analysis.run-diagnostics`) caps how many
   generations of each survive a compaction pass; beyond the cap the
   oldest-by-mtime generations are unlinked first. Per-file and
   per-plugin producers are deliberately absent from this table —
   many current entries under one such producer id can be live at
   once, so a generation count is not a meaningful proxy for
   staleness there. The cap is presently a maintained constant, not
   producer-declared metadata; a new whole-project producer must be
   added to the list by hand to benefit.
3. **Size-based LRU pass.** Unchanged from prior releases: walks
   every remaining `.entry` file, sorts by mtime ascending, and
   unlinks from the oldest until the total is at or below
   `max_bytes:`.

Passes 1 and 2 run **regardless of whether `max_bytes:` is
configured** — they reclaim bytes that are provably dead (a leaked
temp file, an unreachable content-keyed generation) rather than
enforcing a size budget, so an explicitly unbounded store
(`max_bytes: nil`) still benefits from them. Only pass 3 is gated on
`max_bytes:` being set. Any filesystem error during any pass is
swallowed — `evict!` must never break a run.

## Bundled RBS producer contract

Every bundled RBS-derived producer documented below (`RbsConstantTable`, `RbsKnownClassNames`, `RbsClassAncestorTable`, `RbsClassTypeParamNames`, `RbsEnvironment`) satisfies one shape — a class object responding to `fetch(loader:, store:)` and returning the cached or freshly computed value. This is codified as the structural interface `_CacheProducer` in [`sig/rigor/cache.rbs`](../../sig/rigor/cache.rbs): a structural interface (the RBS/Go sense), not an ADR-28 protocol contract, and distinct from the plugin-side producer surface in [`plugin-cache-producers.md`](plugin-cache-producers.md).

The `fetch` body is identical across producers: build the RBS descriptor (`RbsDescriptor.build(loader)`), then call `store.fetch_or_compute(producer_id:, params: {}, descriptor:)` yielding to the producer's `compute(loader)`. Only the `PRODUCER_ID` constant and the `compute` body differ. That shared wiring lives on the `Rigor::Cache::RbsCacheProducer` base; a producer MUST subclass it and declare its own `PRODUCER_ID` and a (private) `self.compute(loader)`. The base reads `self::PRODUCER_ID` so the constant resolves on the concrete subclass. The per-producer sections below specify each producer's `PRODUCER_ID`, `compute` output type, and the `cache_store` consumer that reads it.

## `Rigor::Cache::RbsConstantTable` (v0.0.8 slice 3)

The first cached producer wired through {`Rigor::Cache::Store#fetch_or_compute`}.
Producer id: `"rbs.constant_type_table"`.

### Why the constant table and not `RbsLoader#build_env`

`RBS::Environment` and its transitive AST nodes carry
`RBS::Location` instances. `RBS::Location` is a C-extension class
without `_dump_data`, so a naive `Marshal.dump(env)` raises
`TypeError`. Caching `RBS::Environment` itself therefore requires
either a custom-serialiser surface on the `Store` or a
schema-stable intermediate that walks every relevant node into a
Marshal-safe shape. Both options are out of scope for the v0.0.8
slice budget — see [ADR-6 § 8 "RBS::Environment serialisation"](../adr/6-cache-persistence-backend.md).

The v0.0.8 slice instead caches a **post-translation** artefact:
the result of translating every RBS-declared constant to its
`Rigor::Type` form. `Rigor::Type` values are plain frozen value
objects with well-defined `Marshal` round-trips, so the cache
machinery exercises the full read/write cycle on real data
without blocking on the serialiser question.

### `RbsConstantTable.fetch(loader:, store:) -> Hash{String => Rigor::Type}`

Returns a hash mapping every canonical constant name (top-level-
prefixed, e.g. `"::Math::PI"`) to its translated `Rigor::Type`.
The producer block iterates `loader.each_constant_decl` (which
yields `(name, entry)` pairs from `env.constant_decls`) and
translates each entry directly; entries whose translation
returns `Rigor::Type::Bot` or raises are dropped from the table.

Going through `each_constant_decl` instead of
`loader.constant_type` keeps the producer free of the recursion
risk: `RbsLoader#constant_type` itself consults the cache when
`cache_store` is set.

## `Rigor::Cache::RbsKnownClassNames` (v0.0.9 group C)

Second cached producer. Materialises the set of every RBS-declared
class / module / alias name (top-level prefixed) currently loaded
into the environment, as a Marshal-clean `Set<String>`. Producer
id `"rbs.known_class_names"`.

### `RbsKnownClassNames.fetch(loader:, store:) -> Set<String>`

Returns the set. The producer block iterates
`loader.each_known_class_name` (which walks both
`env.class_decls` and `env.class_alias_decls`); a fail-soft
`rescue StandardError` inside the iterator means a broken
environment yields no names rather than aborting the whole run.

### Class-known path under `cache_store`

`RbsLoader#class_known?(name)` consults the cached set when the
loader was constructed with `cache_store:` set. Cold runs build
the set once and persist it; warm runs (and a separate loader
sharing the same Store) skip the env walk entirely. The in-
process per-name cache (`@class_known_cache`) still memoizes
positive and negative answers across calls within a single
loader instance — the disk cache only changes the cold-start
behaviour, not the warm hot path.

## `Rigor::Cache::RbsClassAncestorTable` (v0.0.9 B)

Third cached producer. Materialises every loaded class /
module's RBS-declared ancestor chain as a Marshal-clean
`Hash<String, Array<String>>` keyed by top-level-stripped class
name (e.g. `"Integer"` → `["Integer", "Numeric", "Comparable",
"Object", "BasicObject"]`). Producer id `"rbs.class_ancestor_table"`.

Building one ancestor chain requires a full
`RBS::DefinitionBuilder#build_instance` over that class — the
single most expensive RBS operation per class. Caching the table
lets a warm process pay only a `Marshal.load` of the resulting
hash; subsequent `class_ordering` queries are O(table-lookup +
ancestor-list-membership-check), with no env walk.

`RbsHierarchy#ancestor_names` consults the cached table when
`loader.cache_store` is set. The in-process per-name cache
(`@ancestor_names_cache`) still memoises results across calls
within a single hierarchy instance, so the disk cache only
changes the cold-start behaviour.

## `Rigor::Cache::RbsClassTypeParamNames` (v0.0.9 A)

Fourth cached producer. Materialises every loaded class's
RBS-declared type-parameter names as a Marshal-clean
`Hash<String, Array<Symbol>>` keyed by top-level-stripped class
name (e.g. `"Array"` → `[:Elem]`, `"Hash"` → `[:K, :V]`,
`"Integer"` → `[]`). Producer id `"rbs.class_type_param_names"`.

The dispatcher reads type-parameter names every time it builds
a substitution map from a receiver's `type_args` into a method's
return type. Each entry shares the underlying
`RBS::DefinitionBuilder#build_instance` cost with
{RbsClassAncestorTable}; populating both producers warms the
same set of definitions.

`RbsLoader#class_type_param_names(class_name)` consults the
cached table when `cache_store` is set. The accessor returns a
fresh `Array.dup` so callers cannot mutate the cached payload.

## `Rigor::Cache::RbsEnvironment` (v0.0.9 C2)

Fifth cached producer — and the first to use the
{`Store#fetch_or_compute`} default-`Marshal` path against a
non-Marshal-clean RBS-native value. The producer caches the
loader's full `build_env` result (`RBS::Environment` after
`from_loader` + `resolve_type_names`); cold runs pay the parse +
resolve cost once and persist the result, while warm runs (and
a separate loader sharing the same Store) load the marshalled
blob and skip the parse / resolve stages entirely.

Producer id `"rbs.environment"`. Cache descriptor reuses
{`RbsDescriptor.build`} so a single signature change or rbs gem
bump invalidates this producer alongside the four
post-translation caches.

### `RbsEnvironment.fetch(loader:, store:) -> ::RBS::Environment`

Returns the env. The producer block calls
`Rigor::Environment::RbsLoader.build_env_for(libraries:, signature_paths:)`
— a stateless class-method counterpart to
`RbsLoader#build_env` so the producer does not need to hold a
loader instance.

### `RBS::Location` Marshal patch

`RBS::Environment` and its transitive AST nodes carry
`RBS::Location` instances. The rbs gem's C-extension
`RBS::Location` does not ship `_dump` / `_load`, so a naive
`Marshal.dump(env)` raises `TypeError`. v0.0.9 patches
`RBS::Location` with the minimal Marshal hooks the cache
machinery requires:

```ruby
class RBS::Location
  def _dump(_) = ""
  def self._load(_) = new(buffer: ..., start_pos: 0, end_pos: 0)
end
```

The patch is purely additive (only adds methods that previously
raised `TypeError` on dispatch) and idempotent (gated behind
`method_defined?(:_dump)`). Cached `RBS::Location` instances
lose their per-node source-position info — but Rigor never
consults `RBS::Location` from any analysis code path (every
diagnostic flows through Prism's own location), so the loss is
inert in practice. Code paths that DO read Location after a
cache hit (e.g. third-party tools) see a benign zero-range
sentinel rather than crashing.

The patch lives in
`lib/rigor/cache/rbs_environment_marshal_patch.rb` and is
required by the producer; it is loaded once per process when
the producer is first referenced.

### Composition with the post-translation caches

`RbsEnvironment` lives alongside `RbsConstantTable`,
`RbsKnownClassNames`, `RbsClassAncestorTable`, and
`RbsClassTypeParamNames`. The post-translation caches answer
the lookups they cover from disk without ever materialising an
env; `RbsEnvironment` answers everything else (e.g.
`RbsLoader#instance_method` and `singleton_method`) by handing
the cached env to RBS's `DefinitionBuilder`. The two layers
compose: a warm process pays no env build, no constant
translation, no ancestors walk, and no type-parameter walk for
already-cached lookups, and only an env load + per-class
DefinitionBuilder cost for the few that aren't.

## `Rigor::Cache::RbsDescriptor` (shared)

Both `RbsConstantTable` and `RbsKnownClassNames` depend on the
same RBS environment state, so they share a descriptor builder:

```ruby
Rigor::Cache::RbsDescriptor.build(loader)
# => Descriptor with:
#    gems    = [{ name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION }]
#    files   = [...]   # :digest entries for every .rbs under signature_paths
#    configs = [{ key: "rbs.libraries", value_hash: SHA256(sorted-libraries) }]
```

Sharing the builder means a single signature change or rbs gem
bump invalidates every RBS-derived cached producer in lockstep.

## Constant-lookup path under `cache_store`

Once an `Environment` is built with `Environment.for_project(..., cache_store:)`,
every constant lookup path threads through the cache:

- `Rigor::Reflection.constant_type_for(name, scope:)` — public
  read API; in-source constants win on collision, otherwise
  falls through to:
- `Environment#constant_for_name(name)` →
- `Environment::RbsLoader#constant_type(name)` — checks
  `constant_type_table[rbs_name.to_s]` (memoized per loader,
  populated through `RbsConstantTable.fetch`).

The first lookup on a cold cache pays the full table-build cost
once and persists the result; warm runs (and a separate loader
that shares the same Store) skip the env walk entirely and pay
only a `Marshal.load` of the stored hash. The `params` argument
to `Store#fetch_or_compute` is empty — every input the producer
consumes is already encoded in the descriptor (see
{Cache::RbsDescriptor.build}).

## CLI observability (v0.0.8 slice 4)

The cache layer ships two CLI flags on `rigor check`:

### `--clear-cache`

Removes the `.rigor/cache` directory (resolved relative to the
current working directory) before the analysis run. Prints
`Cleared cache: .rigor/cache` when the directory existed and was
removed, or `Cache already empty: .rigor/cache` when nothing was
present. The check itself runs to completion regardless.

### `--cache-stats`

Prints both an on-disk inventory and the runtime hit/miss/write
counters from the runner's `Cache::Store`. Output sample:

```
Cache (root: .rigor/cache)
  schema_version: 0.2.8.4.2
  3 entries, 12.4 KiB
    rbs.constant_type_table: 1 entries, 11.0 KiB
    reflection.instance_method_definition: 2 entries, 1.4 KiB
  this run: 5 hits, 1 miss, 1 write
    rbs.constant_type_table: 5 hits, 1 miss, 1 write
```

When the cache directory does not exist, `schema_version` reads
`absent` and the body shows `(empty)`. When the runner has no
Store (e.g. under `--no-cache`), the `this run:` section is
omitted — there is no in-memory state to report.

### `Store#stats`

Returns a frozen snapshot of the Store's per-run counters:

```ruby
{
  hits: Integer,
  misses: Integer,
  writes: Integer,
  by_producer: { producer_id => { hits:, misses:, writes: } }
}
```

The counters are in-memory only — every new `Store.new` starts
at zero. Bumped inside `#fetch_or_compute`: a successful read
increments `:hits`; a miss increments `:misses` immediately and
then `:writes` after the producer block returns and the entry
is persisted. Per-producer counts mirror the totals so callers
can report the breakdown shown above.

### `Store.disk_inventory(root:)`

Class method backing `--cache-stats`. Returns:

```ruby
{
  root: String,                  # the cache root path
  schema_version: String | nil,  # nil when the marker is absent
  total_entries: Integer,
  total_bytes: Integer,
  producers: [
    { id: String, entries: Integer, bytes: Integer },
    ...
  ]
}
```

Producers are sorted by id. Empty producer subdirectories are
omitted from the listing.

## Diagnostic provenance (v0.0.8 slice 5)

Companion slice on `Rigor::Analysis::Diagnostic`. The class gains
a `source_family:` keyword (default `Diagnostic::DEFAULT_SOURCE_FAMILY`,
which is `:builtin`) and a `qualified_rule` accessor:

```ruby
diagnostic = Rigor::Analysis::Diagnostic.new(
  path: "lib/foo.rb", line: 12, column: 3,
  message: "...", rule: "no-mutation",
  source_family: "plugin.rigor-immutable"
)

diagnostic.source_family   # => "plugin.rigor-immutable"
diagnostic.rule            # => "no-mutation"  (bare kebab-case identifier)
diagnostic.qualified_rule  # => "plugin.rigor-immutable.no-mutation"
diagnostic.to_h            # includes both "source_family" and "rule"
```

The bare `rule` accessor stays as the kebab-case identifier so
existing config / `# rigor:disable` plumbing keeps working.
`qualified_rule` is the namespaced identifier consumers should
display when they want unambiguous attribution. JSON output
(`to_h`) carries both fields side-by-side so downstream consumers
can choose which one they care about.

This prepares ADR-2's plugin-observability story (`plugin.<id>`,
`rbs_extended`, `generated.<provider>`) without committing to the
plugin API itself. No production caller in v0.0.8 sets a non-
default source_family — the surface is reserved for plugin
authors and future RBS-extended / generated rules.
