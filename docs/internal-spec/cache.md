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

## `Rigor::Cache::RbsClassAncestorTable` (v0.0.10 B)

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

## `Rigor::Cache::RbsClassTypeParamNames` (v0.0.10 A)

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
  schema_version: 1
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
