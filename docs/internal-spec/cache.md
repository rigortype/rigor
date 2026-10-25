# Cache Layer — `Rigor::Cache`

Status: **Stable (introduced v0.0.8; current descriptor schema v6).**
This document tracks the cache layer's public read shape. The
slices below all landed and are stable across v0.1.x; the descriptor
`SCHEMA_VERSION` was bumped to `2` for the ADR-10 per-gem-version
`dependencies` slot, to `3` when `RbsLoader.build_env_for` began
synthesizing missing `signature_paths:` namespaces (so an RBS env
marshalled by an older Rigor — which would leave those signatures
inert — is rebuilt), to `4` when [ADR-60](../adr/60-pre-freeze-plugin-contract-consolidation.md)
WD3 added the `globs` slot (`GlobEntry`) for the record-and-validate
plugin-producer cache, to `5` when [ADR-87](../adr/87-null-build-floor.md)
WD1 added the `:stat` `FileEntry` comparator (stat-then-digest
validation), and to `6` when `append_stub_declarations` began emitting
the declaration kind each referenced-type stub needs and validating each
declaration on its own (so an env cached by an older Rigor — which
discarded the whole stub batch on a dangling `interface` or type-alias
reference — is rebuilt). All five v0.0.8 slices landed:
`Rigor::Cache::Descriptor` (slice 1 — the substrate every cached
value attaches to), `Rigor::Cache::Store` (slice 2 — the
filesystem-backed storage that consumes a descriptor + producer +
params and returns a cached or freshly computed value), the first
cached producer — the RBS constant table (slice 3) — the CLI
observability flags `--cache-stats` / `--clear-cache` (slice 4),
and diagnostic provenance (slice 5). Four further RBS-derived
producers landed in v0.0.9.

The schema this module implements is fixed by:

- **[`docs/design/20260505-cache-slice-taxonomy.md`](../design/20260505-cache-slice-taxonomy.md)** — per-slot entry shapes, composition rules, cache-key derivation, granularity guidance.
- **[`docs/adr/6-cache-persistence-backend.md`](../adr/6-cache-persistence-backend.md)** — backend choice (sharded directory of binary entries), file format, atomicity, locking, eviction policy.

## `Rigor::Cache::Descriptor` (v0.0.8 slice 1)

The cache invalidation descriptor — a pure value object with six
slots, every slot an array of typed entries.

### Slot entries

```
FileEntry       :: { path: String, comparator: :digest|:stat|:mtime|:exists, value: String }
GemEntry        :: { name: String, requirement: String, locked: String? }
PluginEntry     :: { id: String, version: String, config_hash: String? }
ConfigEntry     :: { key: String, value_hash: String }
DependencyEntry :: { gem_name: String, gem_version: String, mode: :disabled|:when_missing|:full }
GlobEntry       :: { root: String, pattern: String, value: String, mode: :stat|:names|:kinds }
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
`watch:` glob coverage stays fresh across edits. Post-[ADR-87](../adr/87-null-build-floor.md)
WD2 that per-glob digest is a SHA-256 over sorted **stat tuples**
(`"<path>\0<size>\0<mtime_ns>\0<ctime_ns>\0<inode>\n"` rows), not file
content — re-validation re-globs and re-stats, reading zero content bytes
on an unchanged tree while any edit (which moves mtime + ctime) still moves
the signature. `GlobEntry#new` validates the `mode` enum, raising
`ArgumentError` on an unknown value.

`mode` ([#979](https://github.com/rigortype/rigor/issues/979)) selects
which question the signature answers. `:stat` is the default just
described — appearance, disappearance and edit alike. `:names` hashes the
sorted matching **paths alone**, reading no stat and no content, so only a
change to the SET of matching files moves it. A `:names` row is for a
dependency whose members are already covered individually: the run
descriptor's per-signature-root rows are `:names` because every `.rbs`
they list also carries its own `:stat` `FileEntry` row, and an edit must
invalidate through that row's ADR-87 WD1 digest fallback rather than
through the glob — a stat-mode glob over a signature tree would read every
`git checkout`, `bundle install`, and CI cache restored over a fresh
checkout as a full re-analysis, none of which changes a byte of RBS. The
mode is part of the composition `slot_key`, and is omitted from `to_h`
(and so from the canonical bytes) when it is `:stat`, leaving pre-#979
descriptors byte-identical — the field itself moves no producer's key.
Every key did move once with `SCHEMA_VERSION` 9, which the storage layer
mixes into each key; that one-time miss is the #979 migration, the same
shape as v8's for #577.

`:kinds` ([#1959](https://github.com/rigortype/rigor/issues/1959)) hashes
each matching path with its `File.lstat` kind (`GlobEntry.lstat_kind`:
`:file`, `:directory`, `:symlink`, `:other`, or `:absent` for a path that
vanished between the glob and the `lstat`), reading no content, so it
moves when the set changes or when a path keeps its name and changes
kind, and not on a `touch` or an edit. `IoBoundary#list_directory_kinds`
records it over `path/*` for a walk that decides per top-level entry
whether to descend: a file `gen` replaced by a directory `gen/`, or a
symlinked directory replaced by a real one, changes what such a walk
reads while every name stays put, and a `:names` row would stay fresh.

The `:stat` comparator is the ADR-87 WD1 stat-then-digest tier for
individual `FileEntry` slots. Its `value` packs `"<digest> <size>
<mtime_ns> <ctime_ns> <inode> <recording_instant_ns>"`: validation
(`FileDigest.stat_fresh?`) stats the file first and only falls back to a
full content hash (`FileDigest.hexdigest`) when the tuple moved, or when a
racy-window guard fires (the file's mtime is not strictly older than the
entry's recording instant). The SHA-256 digest packed in the value remains
the sole change **authority** — an unmoved stat only lets validation skip
recomputing it; a `:stat` entry whose stat moved but whose content is
identical (a bare `touch`) is re-hashed and correctly found fresh. The
`:stat` tier rides validation-only descriptors (the ADR-45 dependency
descriptor, plugin `watch:` globs); cache-KEY descriptors keep the
deterministic `:digest` comparator. `cache.validation: digest` (or the
`RIGOR_STRICT_VALIDATION=1` env, which wins) forces every entry back to
`:digest` for a filesystem whose stat cannot be trusted. The key's
default is `auto` (#190): it resolves to `digest` when `CiDetector`
recognises a CI provider — a fresh checkout regenerates every stat tuple,
so the stat tier can never short-circuit and the stat-signature glob
slots would read stale on every run — and to `stat` everywhere else.
Resolution happens per run (`Configuration#cache_validation_strict?`),
honours the `RIGOR_CI_DETECT=0` kill switch, and an explicit `stat` /
`digest` always wins (a persistent-workspace CI runner opts back into the
stat floor with `stat`).

The `:exists` comparator carries `File.exist?`'s answer rendered as
`"true"` / `"false"` (`FileEntry::PRESENT` / `FileEntry::ABSENT`).
`FileEntry.absent(path:)` builds the `"false"` row — the
[ADR-45](../adr/45-unchanged-project-fast-path.md) WD1 (#577) **absence
dependency** that `Plugin::IoBoundary#read_file` records when a read
fails because the path is missing, so an entry computed on the file's
absence reads stale once anything appears there. `#absent?` identifies
the row. `FileEntry.present(path:)` builds the `"true"` row — WD1b
(#613), the same dependency in the other direction, recorded by
`Plugin::IoBoundary#file?` / `#directory?` when an existence probe found
what it asked for and the plugin read no bytes (a discovery root it
globbed, a config file whose presence alone switched a mode). Validation
either way is a single `File.exist?`: there is no stat tuple or digest to
drift on an unchanged tree, so an existence row never thrashes a warm
hit. It is also the weakest file row — a rewrite in place leaves a
presence row fresh — so it is only ever the row for a dependency that
really is on existence alone; a read records the `:stat` row over it.

The `:kind` comparator (#1962) carries what `FileEntry.kind_of` answers for the path, in
the order `Runner#expand_paths` asks, each predicate following symlinks: `"directory"`,
`"file"`, `"other"` (a FIFO, a socket), or `"absent"` (a missing path, a dangling symlink).
`FileEntry.kind(path:)` builds it, and the run descriptor and the `--incremental` slot (#1977)
record one per analysis root, `pre_eval:` entry and project signature root, whose answers turn on exactly that: unlike an
existence row it reads stale when a directory is replaced by a file of the same name. What
a directory holds is not its concern; the analysed files are in the key and have rows of
their own, and a signature root's files have #979's, so a non-`.rb` file added under an
analysis root leaves it fresh. Validation is at most three stat calls with no digest,
so it never thrashes a warm hit either. It ranks between `:mtime` and `:exists` in `compose`.

### `Descriptor.new(files: [], gems: [], plugins: [], configs: [], dependencies: [], globs: [])`

Constructs a descriptor. Every slot defaults to an empty array;
slots are duped and frozen so callers cannot mutate after
construction. The descriptor itself is also frozen.

### `Descriptor.compose(*descriptors) -> Descriptor`

Composes any number of descriptors into a single descriptor. The
composition rule per slot is **union by key**:

- `files` group by `path`. Entries within a group prefer the
  **stricter** comparator (`:stat > :digest > :mtime > :exists`;
  ranking `:stat` and `:digest` apart is what guarantees a path
  contributed under both never raises a value `Conflict`, since
  their `value` strings differ by construction); among the
  strictest, all entries must agree on `value` or
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

1. `Descriptor::SCHEMA_VERSION` (currently `20` — v2 added the
   `dependencies` slot for the ADR-10 per-gem-version cache slice;
   v3 invalidates RBS envs marshalled before `build_env_for` began
   synthesizing missing `signature_paths:` namespaces; v4 added the
   `globs` slot for the ADR-60 WD3 record-and-validate plugin-producer
   cache; v5 added the `:stat` `FileEntry` comparator for ADR-87 WD1
   stat-then-digest validation; v6 invalidates RBS envs marshalled
   before `append_stub_declarations` emitted the declaration kind each
   referenced-type stub needs and validated each declaration on its own,
   so a dangling `interface` or type-alias reference no longer discards
   the whole stub batch (#237); v7 invalidates def-index seed bundles
   written before they carried the `:extends` table (#526); v8
   invalidates run-result and plugin-producer entries written before
   `IoBoundary#read_file` recorded absence rows for probed-but-missing
   paths (ADR-45 WD1, #577) — a pre-8 entry would validate fresh across
   exactly the file-appearance edit those rows exist to catch; v9 adds the
   run descriptor's per-signature-root names-mode `GlobEntry` listing rows
   (#979), for
   the same migration reason one slot over — a pre-9 entry carries none and
   validates fresh across a `.rbs` appearing under `sig/`; v10 invalidates
   def-index seed bundles written before they carried the `:prepends`
   table (#1123); v11 invalidates run-result and plugin-producer entries
   written before a producer served from its own cache replayed its
   dependency rows into its plugin's `IoBoundary` (#1558) — the same
   migration reason as v8; v12 to v18 are recorded on the constant; v19
   invalidates run-result entries written before the run descriptor
   carried a `:kind` row per analysis root, `pre_eval:` entry and
   signature root (#1962, #1555), the v8 migration reason again; v20
   invalidates `--incremental` slot entries written while those rows
   were existence rows, which read a directory replaced by a file of the
   same name as fresh (#1977)). Bumping this constant invalidates every cached value.
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
ADR-6. Adding a comparator to `FileEntry::VALID_COMPARATORS`
(currently `%i[digest stat mtime exists]`) is behaviourally additive,
but because the comparator is folded into the cache key via
`cache_key_for`, the ADR-87 `:stat` addition took a
`SCHEMA_VERSION` bump (4 → 5) so pre-`:stat` entries read as clean
misses rather than being trusted under a comparator the old writer
never used.

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
producer block still runs — and, for `fetch_or_compute`, its result still
lands in the in-process memo — but no disk read or write is attempted.
`fetch_or_validate` / `peek_validated` are deliberately **not** memoised
in-process: validation always re-checks the filesystem. This covers
two situations — a read-only store facing a marker it must not trust,
and a writable store whose cache root cannot be read/repaired
(permission error, disk full, deleted root, read-only mount) — neither
of which may ever break an analysis run.

### `store.fetch_or_compute(producer_id:, params:, descriptor:, generation_cap:, serialize: nil, deserialize: nil) { ... } -> Object`

The compute-keyed producer entry point; `fetch_or_validate` below is
the record-and-validate variant, and `peek_validated` its read-only
probe half.

- `producer_id` (String) — the cache namespace. Only
  `[a-z][a-z0-9._-]*` is accepted. The constraint guarantees
  filesystem-friendly directory names on case-insensitive
  filesystems.
- `params` (Hash) — the producer's input arguments. Mixed into
  the cache key via {Descriptor#cache_key_for}; producers do not
  derive cache keys themselves.
- `descriptor` ([`Rigor::Cache::Descriptor`](#rigorcachedescriptor-v008-slice-1))
  — the invalidation descriptor for the cached value.
- `generation_cap` (Integer or `:unbounded`, **required**) — the
  producer's own compaction budget, per § "Compaction (`#evict!`)"
  below. Not optional: a producer that reaches disk has stated how
  many of its generations may accumulate.
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

### `store.fetch_or_validate(producer_id:, key_descriptor:, generation_cap:, params: {}, serialize: nil, deserialize: nil, on_hit: nil) { ... } -> Object`

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
`GlobEntry` must still match, an absence row (`FileEntry.absent`, the
ADR-45 WD1 negative half) matching only while its path is still
missing — and a stale dependency forces a recompute. A **disk-side** write failure (permission, disk full, deleted
root, read-only mount) is swallowed: the freshly-computed value is
returned and the next run recomputes. A **producer contract violation is
not** — a value `Marshal.dump` cannot serialise, or a custom `serialize:`
returning a non-`String`, raises out of `fetch_or_validate` and **aborts
the run**. It does not degrade to a cold run: the write path rescues only
`SystemCallError` / `IOError`, deliberately, so the bug is visible rather
than silently costing every run a recompute. A producer whose value is
not `Marshal`-clean MUST supply a `serialize:` / `deserialize:` pair.
This is the sound successor to a pre-analysis fingerprint, which would go
stale when a plugin reads files Rigor cannot see up front.

`Descriptor#fresh?` considers a descriptor fresh only when its
`gems` / `plugins` / `configs` / `dependencies` slots are all empty
(those non-file inputs belong in the cache *key*, not the validated
set); a descriptor carrying any of them is never fresh.

`on_hit:`, when given, is called with the entry's stored dependency
descriptor on a fresh hit, before the value is returned, and never on
a miss. A hit runs no block, so this is the only way a caller learns
what a served value was computed from.
`Plugin::Base#cache_for` passes a callable that replays the rows into
the plugin's `IoBoundary`
([#1558](https://github.com/rigortype/rigor/issues/1558), see
[`plugin-cache-producers.md`](plugin-cache-producers.md) §
`cache_for`), so a served producer's inputs reach the run-result
descriptor below and the entry of any producer computed around it.
The run-result slot itself passes nothing: nothing encloses a run.

### `store.peek_validated(producer_id:, key_descriptor:, params: {}, deserialize: nil) -> Object?`

The read half of `fetch_or_validate` ([ADR-87](../adr/87-null-build-floor.md)
WD4), with no compute and no write: it returns the cached value on a
fresh hit and `nil` on a miss, a stale dependency descriptor, or an
unavailable disk tier. It takes no block and never runs a producer, so
there is nothing to persist. The boot-slimming probe calls it to serve a
run's diagnostics without loading the inference engine at all. It records
a hit (so `--cache-stats` still balances) but never a miss — a probe miss
hands off to the full path, which records its own.

A served hit skips everything `Runner#run_analysis` appends after
`#compute_run_diagnostics`. A diagnostic kept out of the cache identity
there therefore needs an answer in `Analysis::RunCacheProbe`: reproduce
it engine-free, or decline the probe for any project that could earn it,
judged from its declarations alone. Without one the diagnostic fires
cold and never warm (#428; [`effect-summaries.md`](effect-summaries.md)
§ "The boot-slim probe and the two out-of-band passes"). Runs that look
fine while diagnosing this are not probe runs: `--cache-stats` and
`--no-cache` are ineligible, and `rigor effects` has its own probe. A
cache spec proves its warm arm was served by asserting the run-stats
block is absent warm, since `Runner#stats_for_run` returns nil for a
cache-served run (`spec/rigor/effects/envelope_cache_spec.rb`).

### `store.store_validated`, `store.peek_unvalidated` and `store.discard`

The pieces the `--incremental` run-result slot
([ADR-45](../adr/45-unchanged-project-fast-path.md) WD2, below) is written
and carried with. `store_validated(producer_id:, key_descriptor:,
generation_cap:, value:, dependencies:)` is `fetch_or_validate`'s write
half on its own, and unconditional: a writer that has just computed an
answer stores that answer even when the entry on disk still validates,
because it is the one the run printed. Same entry format, same failure
contract. `peek_unvalidated(producer_id:, key_descriptor:)` returns an
entry's value WITHOUT validating its dependency descriptor, for a writer
that takes rows from a slot it knows to be stale; it records neither a
hit nor a miss, and its answer is never served. `discard(producer_id:,
key_descriptor:)` removes one entry, a no-op on a read-only store.

### Engine identity in a computed-value key

A cache whose value is a function of what the analyzer *computes* —
`analysis.run-diagnostics`, `analysis.incremental-run-diagnostics`, `analysis.run-effects`,
`protection.mutation-file-result`, the per-file
`plugin.source_rbs_synthesizer` slot, every plugin producer
(`plugin.<id>.<producer>`), the five `rbs.*` producers
(`rbs.environment`, `rbs.constant_type_table`,
`rbs.class_ancestor_table`, `rbs.known_class_names`,
`rbs.class_type_param_names`), and the
`IncrementalSnapshot` — MUST key on the engine's source, not only on
`Rigor::VERSION`. The version pins the bytes for a gem installed from
RubyGems and for nothing else, so on an edited working tree a warm run
replays pre-edit diagnostics and a before/after measurement of an engine
change reports a zero it did not
earn ([#285](https://github.com/rigortype/rigor/issues/285)).

Every `Descriptor`-keyed slot among these (all but the
`IncrementalSnapshot`, whose fingerprint appends the identity as a
string part) takes the row from
`EngineSource.key_config_entries` — an `engine-source` `ConfigEntry`
whose `value_hash` is the SHA-256 of the identity, or no row at all for a
version-pinned tree — so the slots cannot drift apart in how they carry
it.

**Why a slot fed to another computation needs it too
([#1009](https://github.com/rigortype/rigor/issues/1009)).** Moving the
run-result key alone is not enough when the re-analysis it forces reads
*other* cached values the engine computed. Before #1009 the
`plugin.source_rbs_synthesizer` slot was keyed on the source file's
digest and the plugin's `PluginEntry` (id, manifest version, config
hash), and a plugin producer's key on the `PluginEntry` alone. A
checkout that edits a bundled plugin's synthesizer keeps its manifest
version, so after such an edit the run-result key moved and the run
re-analysed — but the synthesizer slot served the previous build's RBS
string. The `rbs.virtual_rbs` row of the environment key (see
`RbsDescriptor` below) hashes the string it is handed, so the stale
string kept `rbs.environment` warm as well, and the new build's rules
read the old build's signatures: a warm result that neither build
reports cold. A `lib/`-only edit that changes no synthesizer output did
not show it, which is why the run-result key's own coverage looked
sufficient. With the row in the synthesizer key, an engine edit
re-synthesizes every annotated file; when the output is unchanged the
`rbs.virtual_rbs` row is too, so `rbs.environment` still hits.

**The same shape in the `rbs.*` producers
([#1014](https://github.com/rigortype/rigor/issues/1014)).** All five
`rbs.*` producers key through `RbsCacheProducer#fetch` on the one
descriptor `RbsDescriptor.build` composes, which carried the RBS inputs
(the `rbs` gem version, every signature file's digest, the library list,
the synthesized virtual RBS, the deferred-path partition) and nothing
about the engine. What they hold is not those inputs but what Rigor's own
code made of them, so an engine edit moved the value while the key stood
still. Two were reproduced serving a stale value across a build boundary
on a fixture project, on runs whose `analysis.run-diagnostics` key had
correctly *missed*: an edit to `Inference::RbsTypeTranslator.translate`
left `rbs.constant_type_table: 1 hit` and dropped a true positive the
same tree reports cold, and an edit to the ancestor walk left
`rbs.class_ancestor_table: 1 hit` and served a `flow.unreachable-clause`
false positive the same tree does not report cold. The row now rides in
`RbsDescriptor.build` — once, for all five — and deliberately **not** in
`RbsDescriptor.config_entries`: that half is what the run cache key reads
through `.build_run`, and `RunCacheKey` contributes the identical row
itself, so putting it there would duplicate it in the run key and would
have to be reconstructible by the boot-slimming probe, which builds
`config_entries` with no loader.

The cost is the intended one and is paid once per engine build: an engine
edit in a checkout invalidates the whole `rbs.*` family, including the
~1.9 MB `rbs.environment` blob, on the first warm run after it — a run
that is already a full re-analysis, because the run-result key moved for
the same reason. An unchanged engine is unaffected, and a released gem
adds no row at all.

A caller that cannot identify the engine (`EngineSource::Unavailable`)
runs the synthesizer, the plugin producer, or the `rbs.*` producer
uncached for the run rather than keying it without the row. For the
`rbs.*` family that is `RbsLoader#rbs_cache_descriptor` answering `nil`,
which `RbsCacheProducer.fetch` reads as "compute, do not store".

No `Descriptor`-keyed cache slot deliberately omits the identity. The
slots that carry no row of their own are the ones whose value the engine
did not compute: the `Descriptor` file, gem, glob and config rows are
statements about the project's inputs, and `RbsDescriptor.config_entries`
is the shared half described above, whose one consumer supplies the row
on its own behalf.

`Cache::EngineSource.identity` supplies the slot, in two regimes:

- **Version-pinned** — the tree sits at `<gem_home>/gems/rigortype-<VERSION>`
  and holds no `.git`. Answers `nil`; the caller adds **no** config entry,
  so a released gem's key is byte-identical to the pre-#285 one and costs
  nothing to compute. The predicate is positive about being pinned, so
  every unrecognised layout falls to the mutable side.
- **Mutable** — anything else (a checkout, a `bundle add rigor, github:`
  clone, a `path:` gem). The caller adds an `engine-source` config entry
  holding a SHA-256 over every `.rb` under the gem root's `lib/` and
  `plugins/`, every `.yml` under `data/builtins/` and `data/effects/`,
  every `.rbs` under `data/`, and every `.rbs` under `plugins/*/sig/`,
  each contributing its **root-relative path** and its **content**.
  The `.rbs` files are digested by `RbsDescriptor` too, but only the
  run-result and env caches read that; the `--incremental` snapshot
  fingerprint and `Protection::MutationCache` key on `signature_paths`
  plus this slot alone. Tooling-only trees such as `data/oss-sweep/` are
  not engine input. Content, not a stat tuple: a stat tuple is barred
  from a cache KEY (see `FileEntry`), and a path-relative content digest
  is what makes the key survive a re-clone or a fresh CI checkout of the
  same commit.

A mutable tree whose source cannot be read raises
`EngineSource::Unavailable`, which every caller turns into "no cache for
this run". Falling back to the version-only key is forbidden: it restores
exactly the blind spot the slot exists to close. For
`IncrementalSnapshot.fingerprint` that means answering `nil`, which
disables the snapshot on both sides — `IncrementalSession` guards the
load *and* the save on it, so no `nil`-keyed blob is written for the next
equally-unidentifiable run to match against.

Production callers read the digest through
`EngineSource.process_identity`, which computes it once per process. The
memo is a correctness statement before it is an optimisation: the engine
that computed a cached value is fixed once requiring finishes, so
re-reading `lib/` mid-run would key values against source that never ran
them. A fork-pool worker inheriting the parent's memo is right for the
same reason — it is running the parent's image. `identity` itself stays
uncached, as the computation and the seam a spec relocates.

An engine change drops the **whole** `IncrementalSnapshot`, not part of
it. Every section except `digests` is a value the analyzer computed, so a
changed engine can move any of it — including the dependency edges, where
a new engine recording an edge the old one missed would let a recheck
skip the very file that needed re-analysing. Retaining the one
engine-independent section would not pay either: `digests` is 2.5% of a
2.5 MB snapshot of this repo, and re-deriving it is a file-digest walk
costing ~0.2% of the full run it would be saving. So an engine edit
behaves exactly as a config or `sig/` edit already does.

`Protection::MutationCache` probes `EngineSource` before it loads a
snapshot. It is sound either way — an unidentifiable engine yields a
`nil` fingerprint, which fails the snapshot load and disables the cache —
but the reason the user sees would otherwise be `NO_SNAPSHOT`, which
tells them to run `rigor check --incremental`, a fix for a different
problem.

### Project dependency identity in a computed-value key

A cache whose value is a function of what the analyzer computes MUST also
key on the project's **dependency lockfiles**, for the same reason it keys
on the engine's source. The locked gem set decides which bundle-shipped
`sig/` directories load, which `rbs_collection` directories load, which
[ADR-72](../adr/72-gemfile-lock-gated-rbs-overlays.md) gem overlays apply,
what the ADR-82 WD9 missing-gem constant index owns, and whether
`rbs.coverage.missing-gem` fires — yet a lockfile edit touches no analyzed
source and no `.rbs` file, so nothing else in a run's identity moves with
it. Keyed without it, a warm run replays the pre-`bundle add` diagnostics:
a `call.undefined-method` survives the edit that licenses the overlay
retracting it, and — primed the other way — stays silent after the edit
that revokes it ([#564](https://github.com/rigortype/rigor/issues/564)).

`Analysis::RunCacheKey.descriptor` carries two config slots for it,
`bundler.lockfile` and `rbs_collection.lockfile`, each holding a SHA-256
of the file the corresponding resolver
(`Environment::LockfileResolver.resolve_lockfile_path` /
`Environment::RbsCollectionDiscovery.resolve_lockfile_path`) resolves
under the run's configuration:

- **Content, never the path.** A cache KEY may not carry machine-local
  data (see `FileEntry`), and a content-only slot is what lets a moved
  checkout — a CI workspace, a rename — still hit on an identical
  lockfile.
- **Absent is a value.** No lockfile resolving carries its own sentinel
  rather than dropping the slot: "absent" and "present but empty" must not
  key the same.
- **A key slot, not a dependency entry.** A recorded dependency descriptor
  can only say "a file I recorded changed"; it cannot express a lockfile
  that did not exist when the entry was written and does now, which is the
  first-`bundle install` case.

Both slots are built inside `descriptor`, from the configuration alone, so
the miss path (`Analysis::Runner`) and the ADR-87 WD4 boot-slim hit path
(`Analysis::RunCacheProbe`) obtain them by construction and cannot drift
out of key agreement — the invariant that module exists to hold. Both
resolvers are leaf files, so the probe reaches them without loading
`rigor/environment` or the RBS machinery.

`IncrementalSnapshot.fingerprint` has always hashed the same two
lockfiles (§ Two-level gating above); this states the rule the other
computed-value caches are held to as well.

A cache keyed on the analyzer's output also keys on the **opted-in gems'
versions** ([#1814](https://github.com/rigortype/rigor/issues/1814),
`dependencies.source_inference`, ADR-10 slice 3). The walked gem sources
(their method catalogue, their refinement table, the constants they bind)
reach every file's checks and no analysed file records them, and a
lockfile digest covers a `bundle update` but not a project without a
lockfile. `Analysis::RunCacheKey.descriptor` carries one `DependencyEntry`
`(name, version, mode)` per non-disabled entry that resolves, in its
`dependencies:` slot, built by
`DependencySourceInference::GemResolver.dependency_entries` (a leaf file,
no walk, so the boot-slim probe reaches it); a project that lists no gem
adds no row. `IncrementalSnapshot.fingerprint` hashes the same rows as a
`dependency-source` part under the same rule. A gem edited in place with no
version change is not seen.

One residual is deliberate rather than closed: a gem installed or removed
**under the bundle root without a lockfile change** is half-covered. The
discovered `sig/*.rbs` files are recorded dependencies, so a removal
invalidates, while an appearance does not.

### Read fault tolerance

A read encountering any of the following silently returns a
cache miss; the producer block reruns and the next write
overwrites the bad entry:

- Missing entry file — including one that disappears between
  the existence check and the open (`Errno::ENOENT`), which is
  what a concurrent process clearing or compacting the root
  looks like. Every other `SystemCallError` (permission, I/O)
  still raises: a broken filesystem must stay visible rather
  than degrade into an endless recompute.
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
- Marker present but EMPTY → treated exactly as missing: write the
  current value, proceed, keep the entries. Disk available.
  Emptiness carries no information — it is what a torn in-place
  write looks like, what a crash between the create and the write
  leaves behind, and what the clear-then-rewrite below itself passes
  through — and destroying a cache root is the wrong answer to an
  ambiguous signal. Declining grants the entries no trust they did
  not already have, since a missing marker over existing entries is
  kept and served by the rule above.
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

`schema_version.txt` is published by steps 3–5 alone — the same
temp-file-then-rename, without the destination lock. It needs the
atomicity: its reader is another process's `Store` constructor,
which takes no lock, and a reader that saw a truncated marker
would conclude the marker disagreed and clear the root under a
sibling mid-read. It does not need the lock: every writer of the
marker writes the same value, so there is no last-writer-wins
question to settle.

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
inflate + `Marshal.load` cost. The format version (currently `4`)
is distinct from `Descriptor::SCHEMA_VERSION` — the former covers
the byte layout, the latter the descriptor schema. Bumping the
format version invalidates entries on the read path (header
mismatch → cache miss).

Format v2 ([ADR-54](../adr/54-cache-slimming.md) WD2) deflates
the value payload on write (at `Zlib::BEST_SPEED`; the level is not
part of the format) and inflates on read; the descriptor
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
2. **Producer-declared generation cap.** Some producers are
   content-keyed (the cache key is a function of the value's
   dependencies, not a stable per-project key), so re-running with
   different inputs writes a new entry and leaves the old one
   unreachable — but still on disk. Every fetch call
   (`#fetch_or_compute`, `#fetch_or_validate`) MUST carry a
   `generation_cap:`, which is either a positive `Integer` (how many
   generations of that producer survive a compaction pass) or
   `Cache::Store::UNBOUNDED_GENERATIONS` (`:unbounded` — the producer
   keeps many entries live at once, so a generation count is not a
   staleness proxy and only pass 3 bounds it). Beyond the cap the
   oldest-by-mtime generations are unlinked first. The keyword is
   REQUIRED: omitting it is an `ArgumentError`, so a whole-project
   producer added later cannot be silently uncapped — the failure the
   pre-#151 hardcoded allow-list of producer ids invited.

   The value is the producer's own declaration, not a call-site
   judgement: `RbsCacheProducer.generation_cap` (2, inherited by every
   `rbs.*` subclass), `Analysis::RunCacheKey::GENERATION_CAP` (16 for
   `analysis.run-diagnostics`, one live generation per analyzed-path
   SET × root list as written (#1559), so `rigor check` and `rigor check lib`
   are separate generations, and for its `--incremental` twin `analysis.incremental-run-diagnostics`,
   whose writer also discards the generation it supersedes when the path set
   moves, since the incremental path runs no compaction pass) and its
   `EFFECTS_GENERATION_CAP` twin (`analysis.run-effects`,
   the ADR-103 effects sidecar — one generation per analyzed-path SET ×
   effects identity), and `Plugin::Base.producer generation_cap:`
   (defaulting to `:unbounded`) for plugin-side producers. The per-file
   `plugin.source_rbs_synthesizer` producer declares `:unbounded`.

   The Store records each declaration against the producer id as the
   fetch calls arrive, and the compaction pass reads that record. A
   producer id this Store instance never saw declared is therefore left
   alone rather than compacted on a guess. That is the safe direction:
   a producer not consulted during the run also wrote no new
   generation, so the pass can only skip entries that were already
   there, never evict a live one.
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

Every unlink in all three passes is followed by a best-effort
`Dir.rmdir` on the shard directory (`entry_path`'s `key[0, 2]`
component) that held the file, removing it when the unlink just
emptied it. A shard is created on write (`FileUtils.mkdir_p`) and
nothing else ever deletes it, so without this an evicted generation
or a swept temp file left an empty shard directory behind
permanently. This is cosmetic only — inode reclaim, not part of the
eviction policy — and races (a concurrent writer's `mkdir_p`
recreating the shard, or another pass already having removed it) are
swallowed the same way any other filesystem error in these passes
is.

## `Rigor::Cache::IncrementalSnapshot` (ADR-46)

The persistent artefact behind `rigor check --incremental`. Distinct from
the entry store above: a single per-project blob (`Marshal`, zlib-deflated
at `Store::DEFLATE_LEVEL`, under the cache root) that records enough of the
previous run to re-derive only the affected files' diagnostics on the next
run. Every operation is
fault-tolerant — a missing, unreadable, schema-mismatched,
fingerprint-mismatched, or corrupt snapshot loads as `nil` and forces a
full run, so the snapshot can never wedge or stale an analysis.

### Two-level gating

1. **Global fingerprint (gates the load).** `IncrementalSnapshot.fingerprint(configuration:, roots:, explain:)`
   is a SHA-256 over the engine version + `SCHEMA`, the configuration hash
   (`configuration.to_h`, which omits the keys that change no diagnostic —
   `effects:`, below, and `test_paths:`, which only `sig-gen` reads), the
   analysis **roots** (not the expanded file list — so adding/removing a
   file under a root does not drop the snapshot), the **resolved** dependency
   lockfiles (`bundler.lockfile:` / `rbs_collection.lockfile:`, else
   auto-detected `./Gemfile.lock` / `./rbs_collection.lock.yaml`), the `(name, version, mode)` of each opted-in
   `dependencies.source_inference` gem that resolves (no part for a project that lists none; #1814), the project's RBS
   (the `signature_paths` roots,
   or the auto-detected `<root>/sig` when `signature_paths` is nil — the
   contents of its `.rbs` files), and the **contents** of every `pre_eval:`
   file (its path is in the configuration; a file outside the analysed paths
   would otherwise leave the snapshot stale) — but **not** the analyzed source
   contents. A missing `pre_eval:` file digests as absent, so creating one also
   drops the snapshot. A run under `--explain` adds an `explain:true` part (none
   otherwise, so a plain run's fingerprint is unchanged): the per-file cache
   holds the `:info` fallback rows, so a snapshot primed without the flag must
   not serve a run with it, nor the reverse ([#1533](https://github.com/rigortype/rigor/issues/1533)).
   The modes also persist to separate files under `<cache>/incremental/`: a plain run
   to `snapshot.bin` (unchanged), a run with run-mode parts (`--explain`, the ADR-116
   shadow harness) to `snapshot-<mode digest>.bin` (`IncrementalSnapshot.file_name`), so
   an occasional `--explain` run neither reads nor evicts the warm plain snapshot, and the
   reverse ([#1867](https://github.com/rigortype/rigor/issues/1867)). The language server
   and `Protection::MutationCache#load_snapshot` have no run mode and stay on the plain
   file. `rigor type-of` is a third reader ([#512](https://github.com/rigortype/rigor/issues/512)): it
   loads the plain snapshot under the fingerprint of a bare `check --incremental`
   (roots = the configured paths) and folds its `seed_bundles` into the probe's discovery
   tables through the same digest check as an incremental recheck, so a file whose bytes
   moved (or the editor buffer's) is re-walked. Under `parameter_inference: true` it also seeds
   `param_inferred_types` from the snapshot's `param_table` ([#2282](https://github.com/rigortype/rigor/issues/2282)),
   but only while every configured file still matches its bundle digest and no buffer is bound: the table is
   whole-project, so a single moved file drops it rather than serving a stale type. It is read-only, never writes the snapshot, and
   on any miss (no snapshot, fingerprint mismatch, no bundles) keeps the single-file scope without a
   message. Snapshot files are not budgeted or pruned by `Cache::Store`; they stay until
   `--clear-cache`.
   A mismatch drops the snapshot.

   The language server's in-process session is gated the same way
   ([#1613](https://github.com/rigortype/rigor/issues/1613)).
   `LanguageServer::ProjectContext#project_diagnostics` re-reads the
   configuration and recomputes this fingerprint on every save round, and
   compares it with the one the session was primed with. A mismatch, or a
   fingerprint that cannot be computed (`nil`), discards the session and the
   Environment / project scan built from the old inputs and re-baselines, so
   the round equals a cold run; an unchanged fingerprint takes the plain
   `IncrementalSession#recheck` path. The re-baseline does not bump
   `ProjectContext#generation`: the round that noticed the change is already
   computed from the new inputs. The `effects:` identity
   (`Effects::Identity.digest`, which `Configuration#to_h` omits) is compared
   alongside it, and a fingerprint that was already `nil` at priming is not a
   change. The fingerprint cost is proportional to project size: about 18 ms
   on a 573-file project and 65-95 ms on a 1,300-file app (roughly 4% of a
   no-op save round).

   The lockfile paths are resolved by `Analysis::RunCacheKey.resolved_lockfile_paths`
   — the same call that builds the ADR-45 run-result key's `bundler.lockfile` /
   `rbs_collection.lockfile` slots — so the two caches identify the gem set by the
   same files ([#1532](https://github.com/rigortype/rigor/issues/1532)). A project
   using `./Gemfile.lock` digests that file exactly as before, so `SCHEMA` did not
   move. A project whose resolved lockfile differs from `./Gemfile.lock` sees a
   different fingerprint once (a safe cold run): one whose `bundler.lockfile:`
   names another file, one with `auto_detect: false` and an existing
   `./Gemfile.lock` (now unread, so the part is `absent`), and one whose
   `bundler.lockfile:` names a missing file (no fallback to auto-detection) —
   the last only when a `./Gemfile.lock` also exists. With neither file, master
   and now both digest the part as `absent`, so the fingerprint does not move.
   A plugin that reads a dependency file on its own, such as `rigor-ffi` reading
   `./Gemfile.lock` for its `:ffx` / `:ffi` target, covers it through the
   `incremental_state_fingerprint` hook instead. That covers the snapshot gate
   only. The run-result slot answers an unchanged run without loading the
   plugin, so it sees such an input only through the plugin's `IoBoundary`
   rows, and the plugin MUST read it through the boundary: `rigor-ffi` does
   ([#1652](https://github.com/rigortype/rigor/issues/1652)). `IoBoundary#glob`
   records a `:names` row, which sees a match appear or disappear but not an
   edit or a `touch`, so a plugin that depends on a match's content reads it
   with `#read_file`, whose row carries the edit.
2. **Per-file digests (drive the decision).** When the fingerprint matches,
   the `Payload` is loaded unconditionally and its per-file content digests
   determine the changed set `ΔF`; the affected closure `ΔF ∪ dependents[ΔF]`,
   joined by every file a plugin read of which went stale (`plugin_reads`,
   below), is re-analysed and the rest served from `Payload#cache`.

### Output order

A run that serves files from the per-file cache MUST list its diagnostics
in the order a full run of the same tree, with the same options, lists them,
so warm output is byte-identical to cold
([#1524](https://github.com/rigortype/rigor/issues/1524)). The options
matter: a pool backend lists its `.rigor.yml` prepare rows at the head of the
per-file stream, while a sequential run lists them among the pre-file rows.
A pooled run whose closure is empty dispatches no worker, so `#prepare` runs once on a throwaway registry
(its trust refusals never reach the run) and the same rows are listed there ([#1541](https://github.com/rigortype/rigor/issues/1541)).
A full run lists its pre-file run-level rows, then the per-file stream —
each analysed file's rows, one file after another in analysis order (the
expanded project files, then the template units) — then the post-analysis
run-level streams. So a narrowed run (a recheck's closure, an empty closure,
a `--verify-incremental` partition) does not append the served rows to its
result: `IncrementalSession` hands them to the narrowed run's `Runner`
(`served_per_file_diagnostics:`), which splices each served file's rows into
its per-file stream at that file's place in the analysis order, before the
post-analysis streams are appended. The rows the narrowed run produced keep
their relative order. A misplaced row never aborts the run
([ADR-5](../adr/5-robustness-principle.md)).

The cache is keyed by the path a row names, which is where the order can
still depart from a full run's, in two known cases:

- **A row positioned at another file.** A plugin may report, while analysing
  one file, a row positioned at a different project file. The cache holds
  that row under the path it names and lists it at that file's place, where
  a full run lists it after the rows of the file whose analysis produced it.
  The cache cannot tell which file produced it either, so a recheck that
  re-analyses only one of the two files can list the row twice or drop it.
  This departs whenever such a row exists, not only when it is served: the
  interleave uses the row as a place marker at the target file's rank, so
  served rows from files in between are spliced before it.
- **A served path the run no longer lists.** A file deleted between the
  session's listing and the narrowed run's own expansion has no place in the
  analysis order; its rows are kept and listed after every other file's.

`--verify-incremental` compares the rows as multisets, then the order
(#1542). A recheck whose rows differ in multiplicity fails with the set
report. One whose rows agree as a multiset but list in another order fails
with a "same set, different order" report that names the first index where
the two lists diverge. Rows are compared in full (every field the row
carries), so a tie on path, line, column, rule and message is not mistaken
for a match.

The partition re-analyses an unchanged tree, so every served row is still
right and a missing invalidation edge cannot show
([#1967](https://github.com/rigortype/rigor/issues/1967)).
`--verify-incremental-edits=N` adds an edit replay after a passing
partition: for each of `N` files spread over the analysed list,
`IncrementalSession#replay_edit` rechecks the baseline, handed over as a
Marshal copy of the snapshot a `--incremental` run would save, with the
file replaced through an editor buffer (editor mode option B, never on
disk), and the rows must equal, as a multiset and in order, a full run of
the same buffered tree (`analyze_only:` every analysed file). Each file
is replayed under the two edits `Analysis::EditReplay.edits` builds: the
file emptied, and the file reduced to its `class` / `module` declarations
with every body statement dropped (skipped when identical to the file or
empty). Emptying removes every declaration, so the class-level keys a
removed declaration fires re-check most readers and mask a finer missing
edge. The skeleton keeps the declarations, so a finer edge can be what
puts a reader into the closure: #2163's dropped `refinement:` edge
passes the emptying replay and fails the skeleton one. Not every finer
edge is reached, because dropping a body still moves a broader key for
some of them. A dropped `visibility:` read is one: #2161's
`module_function :two` to `private :two` swap (and the reverse) serves a
stale answer, yet passes both edits, since only an edit that keeps a body
while changing it exposes it
([#2277](https://github.com/rigortype/rigor/issues/2277)). No addition and
no body-changing edit is replayed. A replay the recheck declines as option
B does is counted, not compared, and a run in which every replay declined
fails.

Case 1 therefore fails the gate as an order mismatch or a set mismatch,
depending on the partition: a recheck that reproduces the duplicate or the
drop fails on order only, and one that does not fails on the set. Case 2
always fails as a set mismatch, before and after the order check. Both are
pinned by `spec/rigor/analysis/incremental_session_spec.rb`, which also
checks the order row for row against a full run.

### Editor mode (`--tmp-file` / `--instead-of`)

An incremental run may carry an `Analysis::BufferBinding`: one project
path whose bytes are read from the editor's temp file instead of from
disk. Two rules bind that run, and neither follows from the tier above.

- **The binding is resolved against the analysed set, not by string
  equality.** `--instead-of` carries whatever spelling the editor hands
  the CLI (absolute, `./`-prefixed, relative); the analysed set carries
  the spelling the run's path arguments produce. A binding whose logical
  path is not a member of that set MUST be re-spelled onto the member
  with the same real path. Without it the substitution silently applies
  nowhere: the run reads the file on disk, reports an empty closure, and
  serves the pre-buffer answers
  ([#960](https://github.com/rigortype/rigor/issues/960)).
- **The buffer's own content digest decides change, not the recorded
  stat tuple.** The substituted path is changed exactly when the
  editor's bytes hash to something other than the digest the snapshot
  recorded for it — an edit in the editor never moves the on-disk stat
  tuple, so the stat tier reads the file as fresh no matter what the
  user typed. The closure is then `{path} ∪ dependents[path]`; a buffer
  whose bytes equal the recorded digest leaves the closure empty,
  because every cached answer was computed under exactly those bytes.

A buffer-bearing session MUST NOT write its snapshot back. Its per-file
digests and diagnostics describe bytes that exist only in the editor,
and persisting them would make the next `rigor check --incremental`
believe the file on disk had already been analysed in a state it was
never in. A session that cannot reuse an existing snapshot therefore
declines rather than running a baseline — nothing it computed could warm
the next keystroke anyway.

### `Payload` (current `SCHEMA = 45`)

```
Payload :: Data[
  cache, sources, digests, analyzed,          # per-file diagnostics, read-sets, content digests, analyzed set
  symbol_sources, ancestry_sources,           # the ADR-46 dependency edges (method-symbol and class-ancestry)
  symbol_fingerprints,                        # path -> { "Class#method" => sha256 } — per-method source fingerprints
  missing, class_decls, constant_decls,        # name-keyed edges + per-file declared-class sets / constant publication census
  seed_bundles,                               # ADR-85 per-file pre-pass contribution (plain data + def-node handles)
  plugin_fact_digest,                         # ADR-88 plugin-fact surface fingerprint (see below)
  return_summaries,                           # ADR-89 observed-key return summaries (see below)
  param_table,                                # ADR-67 WD6c the inferred-param seed table the run analysed under
  effect_collections, effects_identity,       # ADR-103 the effects sidecar and its own identity (see below)
  run_level_rows,                             # the two run-level rows a narrowed run replays (see below)
  effect_plugin_digest,                       # #1898 the plugin effect-fact digest the collections were stamped under
  plugin_reads,                               # #1553 path -> the plugin reads its last analysis made (see below)
  discovery_digests,                          # #1583 discovered-not-analysed path -> packed stat digest (see below)
  plugin_disclosures,                         # #2020 path -> the run-scoped plugin rows its last analysis registered (see below)
  synthetic_surface_digest                    # PR #2286 the ADR-16 synthetic-method index the cache was built under (see below)
]
```

The `class:<last segment>` key in `missing` is recorded on the HIT as well
as on the miss ([#639](https://github.com/rigortype/rigor/issues/639)): a
consumer that merely REFERENCES a project class — `Post` with no call on it
— depends on that class existing, and deleting the declaring file otherwise
leaves it serving the pre-deletion type on a warm `--incremental` run while
a full run answers the honest unresolved one. Its producer MUST therefore be
symmetric and MUST diff REMOVED files as well as changed ones: a
declaration that VANISHED satisfies the key exactly as one that appeared,
and a removed file's whole before-set vanished. The edge is deliberately
name-keyed rather than a positive edge to the declaring file, so a body edit
inside the declaration does not re-check the referent. `class_decls` already
carries the per-file declared sets, so no row moves and `SCHEMA` is
unchanged.

The `defines:<method name>` key in `missing` is recorded by
`Inference::BlockCallTiming.project_defines_anywhere?` whichever way it
answers ([#1459](https://github.com/rigortype/rigor/issues/1459)): the
answer reads every file's method tables whole, so it is a function of
whether ANY file defines the name, on any class or module and either side,
by a `def`, an `attr_*`, an `alias` / `alias_method` or a `define_method`.
`LastLine.reads_line?` declines a `gets` / `readline` on it, so a `$_`
narrowing a reader earned while no file defined the name must go when one
starts to, and come back when the last one stops. Its producer diffs each
changed, added or removed file's defined names
(`ScopeIndexer.defined_method_names` over the `methods`, `def_nodes` and
`singleton_def_nodes` tables, plus the named `deferred_ranges` rows with no
side: a `def` inside a block and a literal-named `define_method` /
`define_singleton_method` call, [#2184](https://github.com/rigortype/rigor/issues/2184))
between the file's seed bundle and the
recheck scan (`Incremental.changed_defined_names`), and fires the key for
every name that appeared in or vanished from a file. The appeared-symbol
diff the `method:` and `toplevel:` keys use cannot stand in for it: it
sees only a `def`, and only one that appears. The seed bundles already
carry the three tables, so no row moves and `SCHEMA` is unchanged. The
check's other readers record the key too. `ErrorInfo.rescue_entry` asks it
for `backtrace` at a rescue entry whose clause reads `$@`, so a `backtrace`
definition appearing or vanishing re-checks every file with such a clause.
Before [#1967](https://github.com/rigortype/rigor/issues/1967) it asked at
every rescue entry and re-checked every file with a `rescue`.

`CheckRules::RubyDeprecations#project_defines?` records the key the same
way, whichever way it answers
([#2133](https://github.com/rigortype/rigor/issues/2133)): a
`call.deprecated-ruby2-keywords` report is silenced while any file
defines a method of the called name anywhere (on any class, on either
side, or at the top level), so a file that starts
or stops defining it must re-check the call. Before this the rule read
the tables without recording the key, and the edit re-analysed only the
defining file.

`Scope#discovered_method?` records the key too, on a HIT only, together
with the class edge to every file that declares the class
([#2121](https://github.com/rigortype/rigor/issues/2121)). Its table
holds the members no `def` symbol edge covers — an `attr_*`, an `alias` /
`alias_method`, a `define_method` (a cross-file `def` is withheld from
it) — so before this a caller that the table answered, such as a
`call.undefined-method` silenced by an `attr_accessor` on a core class,
recorded no read of it, and deleting the member re-analysed only the
edited file. The class edge re-checks the caller when a declaring file's
declaration signature moves (the member moved to another class of the
same file, which leaves the file's defined names unchanged); the name
key re-checks it when the member was declared from a file that does not
declare the class (`Mutex.class_eval { attr_accessor :a }`). A miss
records nothing there: the readers that act on one record their own
negative edges.

The `visibility:<class>#<method name>` key in `missing` is recorded by
`Scope#discovered_method_visibility` whichever way it answers
([#2134](https://github.com/rigortype/rigor/issues/2134)), for the class
and method it reads, on either side, and by `DefinerResolution`'s
contested-slot check for a question that reads the visibility (an
answer block may answer from RBS without reading the slot). The
singleton rule's other reads of the table record it too: its wildcard-slot contest check records
`visibility:<entry>#*` for each project entry of the chain, and its
project-wide "is the name private anywhere" gate
(`CheckRules#private_singleton_candidate?`) records `visibility:*#<method
name>`. A `private :foo` can be written from a reopening or from a
`Parent.class_eval` block in a file the reader has no other edge to, so
before this a verdict that read it was not re-checked when that file
added or dropped the modifier: `def.override-visibility-reduced` and
`def.override-return-widened` reading a parent's visibility, and a
singleton `def.method-visibility-mismatch` whose gate found no private
entry of the name and so read no chain. Its producer diffs each changed, added or removed file's
visibility entries — every `[class, slot, visibility]` of its
`method_visibilities` table and every `[class, slot]` of its
`contested_discovered_method_visibilities` sibling
(`ScopeIndexer.visibility_entries`) — between the file's seed bundle and
the recheck scan (`Incremental.changed_visibility_slots`). It fires
`visibility:<class>#<name>` for every entry that moved, with a singleton
slot `[:singleton, name]` read as `name`, and `visibility:*#<name>` for
every moved entry: the table merges last-writer-wins, so dropping a
`public :foo` can uncover another file's `private :foo`. Keying on the class keeps an
edit to one class's visibility from re-checking every reader of the
method name. The seed bundles already carry both tables, so no row moves
and `SCHEMA` is unchanged.

`DefinerResolution.module_function_row?` records the key too
([#2161](https://github.com/rigortype/rigor/issues/2161)): a self-extended
module's singleton copy of a private method is public when any file holds a
`module_function` row for the name on the module, and the answer reads
every file's deferred-range rows. So `visibility_entries` also carries a
`[:module_function, owner, name]` entry for each of the file's def rows of
a kind other than `:instance`, and the diff fires `visibility:<owner>#<name>`
and `visibility:*#<name>` for one that moved: a swap from `private :x` to
`module_function :x` in a reopening leaves the file's visibility table and
declared classes unchanged. The seed bundles already carry the
`deferred_ranges` table, so no row moves and `SCHEMA` is unchanged.

The `global_census:<entry>` keys in `missing` are recorded by the
`global.*` write rules (`CheckRules#global_aliased?`,
`#program_may_answer?` and `#refined_writer_in_effect?`) for each
`Inference::GlobalWriteCensus` entry they ask about
([#2158](https://github.com/rigortype/rigor/issues/2158)):
`global_census:alias:<global>`, `global_census:defines:<method>` for the
setter's method and each hatch, `global_census:defines_any`,
`global_census:refines:write`, `global_census:refines_any`, and one
`global_census:main_mixin` for every top-level mixin
(`GlobalWriteCensus.dependency_key`). A question over several entries
(`CheckRules#census_holds_any?`) records only the entries present when
one is, since the answer stays until every one of them vanishes, and
every entry when none is. That rests on an invariant: every census entry
can only move a write toward being silenced, and a reported write always
re-checks through `IncrementalSession#global_write_reporters`. A future
census entry that makes a write reported would break it, and its reader
would have to record every entry; recording every entry on a no is
defence in depth. The shared `main_mixin` key is a deliberate
precision trade-off: the reader asks about every top-level mixin, so a
mixin appearing or vanishing anywhere re-checks every write that reached
that step. The census is a
fact of the whole program: a `write` or hatch defined in any spelling on
any receiver silences a write, and so does an alias of the variable or a
top-level mixin of a module RBS does not rule out. Before this a file
that stopped writing such an entry re-analysed only itself, and the
silenced write kept its answer; the run already re-checks every file
whose last result holds a `global.*` diagnostic, which covers the other
direction. Its producer (`IncrementalSession#global_census_affected`)
diffs each changed, added or removed file's census between its seed
bundle and the recheck scan (`Incremental.changed_global_census_keys`)
and fires the key of every entry that appeared or vanished, so an edit
that leaves a file's census as it was re-checks nothing. The `defines:`
key cannot stand in for it: its producer reads the method tables, which
hold no delegation macro, string `eval`, computed name, global alias or
mixin. The seed bundles already carry each file's census, so no row moves
and `SCHEMA` is unchanged.

The `mark:<last segment>` key in `missing` is recorded by
`Scope#parameter_envelopes_of` whichever way the reader answers
([#1833](https://github.com/rigortype/rigor/issues/1833)): a file can add a
class mark (`Scope::DiscoveryIndex`'s object-extended or refined mark, a
`[:removed, name]` entry) to a class it does not declare, so neither the
reader's edge to the declaring files nor `class:` sees the mark appear or
vanish. Its producer (`IncrementalSession#mark_affected`) diffs the marks
of the changed, added and removed files between their seed bundles and
the recheck scan's merged envelope table
(`Incremental.changed_class_marks`), and fires the key for every class
whose marks moved; `mark:*` fires when an object-extended mark moves, for
the reader that scans every bucket for one. The seed bundles already
carry the envelope tables, so no row moves and `SCHEMA` is unchanged.
`Inference::SelfCallIvarWrites` reads the chain's buckets through it too
([#2137](https://github.com/rigortype/rigor/issues/2137)): a `refine` of
a class on the chain, from a file whose declared classes do not change,
fires no class key, so before this the ivar-write proof kept its answer.

`Inference::SelfCallIvarWrites`' `refined?` records the `refinement:<method
name>` and `refinement:*` keys whichever way it answers
([#2163](https://github.com/rigortype/rigor/issues/2163)), as every consumer
of the refinement table must (the producer is
`IncrementalSession#refinement_affected`): the proof gives up when a
`refine` block anywhere defines a name the callee calls, on any class. A
refined class off the chain (`Kernel`, `String`, `IO`) carries no `mark:`
the chain read files, so before this a file that started or stopped
refining the name, with its declarations unchanged, left the caller on its
previous answer.

The `mixin:<qualified name>` key in `missing` is recorded for every
qualified candidate name of every external entry on a resolution chain that a
`settle` verdict files beyond its answer, beside the entry's hook keys
([#1661](https://github.com/rigortype/rigor/issues/1661)): a new file can
taint an RBS-known module with a mixin the tables cannot position
(`module Comparable; include(*MODS); end`, `Comparable.include(x) if c`,
an `include` in a block), which makes a reader of the chain decline, and
the external entry has no declaring file for the reader's edge to name.
The same producer (`IncrementalSession#mark_affected`) diffs the
`unpositioned_mixins` tables of the changed, added and removed files
between their seed bundles and the recheck scan
(`Incremental.changed_unpositioned_owners`) and fires the key for every
class or module whose unpositioned edges moved. The table keys a
receiver-form owner by the spelling written (`class File;
Constants.include(*MODS); end` lands under `Constants`) and carries no
nesting, so an owner fires its own key and every recorded `mixin:` key
ending in `::<owner>` (`IncrementalSession#mixin_keys`): a relative
spelling over-fires to every module sharing its trailing segments, and a
qualified owner such as `Foo::Base` fires no reader of an external
`ActiveRecord::Base`. It is a separate key from
`mark:` because a plain reopening (`module Comparable; def zz = 1; end`)
moves the module's envelope bucket mark, and `mark:Comparable` on an
external entry would re-check every reader of the chain on any reopening.
The seed bundles already carry the table, so no row moves and `SCHEMA` is
unchanged.

Schema history worth pinning: `6` stored the seed bundles as
`(node_id, name, fingerprint)` def-node handles (ADR-85); `8` added each
bundle's comment-stripped `code_fingerprint` for the B1 comment-only gate;
`9` added `plugin_fact_digest` (ADR-88); `10` added `return_summaries`
(ADR-89); `11` added `param_table` (ADR-67 WD6c); `12` added the effects
sidecar (ADR-103 WD13); `13` added `constant_decls` (the per-file
constant PUBLICATION CENSUS — `{name => [literal] | :unpublishable}`, whose
diff drives the `constant:` edge's producer) and gave each seed bundle a
`constant_writes` census of its own
([#644](https://github.com/rigortype/rigor/issues/644)); `14`–`21` are
seed-bundle grammar bumps, each recorded against its issue in the numbered
comment on `IncrementalSnapshot::SCHEMA`; `22` added `run_level_rows`
([#796](https://github.com/rigortype/rigor/issues/796),
[#794](https://github.com/rigortype/rigor/issues/794)); `23` gave each seed
bundle a `parameter_envelopes` table
([#992](https://github.com/rigortype/rigor/issues/992)); `31` changed how
`plugin_fact_digest` and the `source_rbs_digest` of an unnamed synthesizer
output digest a value
([#1574](https://github.com/rigortype/rigor/issues/1574), below); `30` gave each seed
bundle a `source_rbs_digest`
([#1536](https://github.com/rigortype/rigor/issues/1536), below); `35` gave each
seed bundle a `siblings` Hash, the `possible_*` / `contested_*` halves of the
discovery-index pairs (ADR-119 WD1, [`inference-engine.md`](inference-engine.md)
§ "Discovery Index"), every one empty until a producer admits a possible fact;
`40` added `plugin_reads` ([#1553](https://github.com/rigortype/rigor/issues/1553), below);
`41` added `discovery_digests` ([#1583](https://github.com/rigortype/rigor/issues/1583), below);
`43` added `plugin_disclosures` ([#2020](https://github.com/rigortype/rigor/issues/2020), below);
`44` added `synthetic_surface_digest` ([#2286](https://github.com/rigortype/rigor/pull/2286), below);
`45` added the ivar-writer rows (`ivar_set`, `ivar_set_class`, `own_write`) to each seed bundle's `global_write_census` ([#1154](https://github.com/rigortype/rigor/issues/1154)).
A blob from an older schema mismatches the `SCHEMA` gate and loads as `nil` — a
clean cold rebuild, never a migration.

### `discovery_digests` — path arguments under a configured path ([#1583](https://github.com/rigortype/rigor/issues/1583))

A run over path arguments that differ from the configured `paths:` widens
its cross-file discovery to the configured paths as well
([#684](https://github.com/rigortype/rigor/issues/684)), so
`rigor check lib/b.rb` resolves a constant `lib/a.rb` defines. Every run an
`IncrementalSession` makes widens the same way: the baseline, a recheck's
`analyze_only:` closure run, and a `--verify-incremental` partition
(`reanalyze_subset`). Before #1583 only the baseline did, so a recheck or a
partition over `lib/b.rb` discovered `lib/b.rb` alone and answered
differently from the full run.

An analysed file outside the configured paths also discovers what it loads
with a literal `require_relative`, through targets that are themselves
outside them ([#2021](https://github.com/rigortype/rigor/issues/2021),
`Analysis::RequireRelativeClosure`). Those targets are discovered-not-analysed
files like any other: they join `discovery_digests`, the run-result
cache's per-file entries, and every session run's discovery. A target under a
configured path ends the walk, compared by real path, and `exclude:` drops a
target from discovery as it drops a configured file. A target the walk names
that is not a file is recorded as a `:kind` row in the run-result descriptor,
the `--incremental` baseline rows and the slot's derived rows, so a file
appearing there moves the answer; a session also re-walks on each warm run,
so the appearing file changes `discovery_digests` and re-baselines it.

A walked file is discovered as uncertain: the pre-pass classifies every one of
its method contributions `possible` (ADR-119 WD3,
`ScopeIndexer::Certainty.every_contribution`), and the seed-bundle pass
re-walks it each run and keeps no bundle for it. Its classes, modules and
constants resolve, and its methods exist, but no return type, arity or
visibility is read from its bodies, because a file the walk does not reach may
redefine them. The walked files fold after every other discovered file and
skip each def-node (instance or singleton), visibility and parameter-envelope
slot an earlier file wrote, so a walked file's slots never override a
configured file's. Constant value types are read from walked files as from any
other, and their ancestry and dynamic-dispatch declarations (`include`,
`extend`, `prepend`, a `define_method` on a receiver, `method_missing` /
`respond_to_missing?`) still apply, as in the run over the walked file's
directory.

A discovered-not-analysed file feeds the index the analysed files resolve
against, but it has no per-file row, edge or digest of its own. The session
records each one's ADR-87 packed stat-digest entry
(`Runner#discovery_only_file_set`) in `discovery_digests` at every baseline.
A recheck re-globs that set first and re-baselines the session when a member
was edited, added or removed: such files are not tracked per symbol, so the
closure cannot be narrowed. The re-baseline analyses the argument set alone
(its banner reads as a cold run) and persists the new digests, so the next
unchanged run is warm again. An edit under another configured path
(`paths: [lib, ext]`, `rigor check --incremental lib`, an `ext/` edit;
[#1560](https://github.com/rigortype/rigor/issues/1560)) takes the same route.

The set is globbed by a runner without the editor buffer. A buffered run
does not widen its discovery, so editor mode option B
([#146](https://github.com/rigortype/rigor/issues/146)) compares the same
set the snapshot's writer recorded: an unchanged project serves option B,
and a discovery-only edit makes the recheck re-baseline, which option B
declines (falling back to option A).

A session over the configured paths (no arguments, or arguments equal to
`paths:`) discovers nothing beyond what it analyses: `discovery_digests` is
empty and the check globs nothing. A session over arguments pays one extra
glob of the configured paths and one `File::Stat` per discovered file on
each warm run, plus the discovery fold over those files that the widened
recheck now makes (seed-bundle served, no re-parse of an unchanged file).

### `plugin_disclosures` — run-scoped plugin rows a recheck replays ([#2020](https://github.com/rigortype/rigor/issues/2020))

A plugin registers a run-scoped row (`Plugin::Base#disclose_once`, or a
positioned batch through `#emit_once`) from `#prepare` or from a per-file hook.
`#prepare` runs on every recheck, but a per-file hook runs only for the files
the recheck analyses, so before #2020 a recheck that analysed nothing dropped
every row registered from a hook, and the next unchanged run reported none of them.

- **Record.** While a file is analysed, every `#disclose_once` / `#emit_once`
  call is attributed to it (`Analysis::RunDisclosureCredit`), a repeat of a key
  the plugin already registered included: the in-tree disclosers memoise the
  input a notice is about and re-register it from each file's hook, and
  crediting only the first file would lose the row once that file is removed.
  `plugin_disclosures` holds `Analysis::RunDisclosureLedger#to_h`: `files` maps
  each analysed file to those records, tagged with their plugin id, one per
  `[plugin id, key]`; `reads` maps each `[plugin id, key]` to every row the
  registering plugin's boundary held when it was last registered, including
  the reads `#prepare` made. A batch registered empty is not recorded.
- **Replay.** A recheck hands the records of every file it serves from cache to
  the runner, which emits them beside this run's own registrations,
  de-duplicated by `[plugin id, key]`, with the row this run registered winning.
  A `--verify-incremental` partition replays them the same way.
- **Staleness.** A recheck validates each `[plugin id, key]`'s rows, and for
  every one with a row that no longer validates it puts ONE live registering
  file (the first by path, never a removed one) into the closure and withholds
  the key's replays. When that file registers the key, every other file that
  held it takes that record. When it registers nothing (an edit took the
  notice out of its text, the file no longer parses, the plugin raised), the
  recheck runs the closure again with every other live holder of the key
  added, and the key is dropped only if none of them registers it. A fixed
  input therefore stops being reported on the warm run. A re-analysed file's
  records are replaced by this run's; a removed file's are dropped.
  Re-analysing one registrant rather than all of them keeps an edit to an
  input the plugin read (one view template, under rigor-rails-i18n's view
  batch) from re-analysing every file that registered the key.
- **Bounds.** One shape stays unsound: a key whose registration or record
  depends both on an input the plugin read and on the registering file's own
  text. When the input changes and the chosen file still registers the key,
  the other holders take its record even where, re-analysed, they would
  register another record or none, until each is re-analysed itself. A key
  that depends on the file's text alone is not affected: a holder that stops
  registering it is the edited file, re-analysed in any case, and the second
  pass settles the others. `#disclose_once` asks a key not to vary between
  workers, which rules this shape out for a plugin that keeps the contract.
  Only inputs read through the plugin's boundary are tracked: state a plugin
  carries across files (`@seen ||= …`) or an input it reads around the
  boundary (`ENV`, a direct `File.read`) can leave a replayed row that never
  clears. Both are contract misuse (ADR-2).
- **Pool.** Each fork worker records its files' records and marshals them back
  beside its plugin reads.

### `plugin_reads` — plugin reads in the closure ([#1553](https://github.com/rigortype/rigor/issues/1553))

A plugin read made while a file is analysed is an input of that file's cached
rows, and no ADR-46 edge records it: the edges record type and declaration
reads. `plugin_reads` maps each analysed file to the rows
`Plugin::IoBoundary.attributing` collected while it was analysed (the
`FileEntry` rows of `#read_file`, of a `#file?` / `#directory?` probe and of a
read that found the path absent, and the `GlobEntry` rows of `#list_directory`
and `#glob`), as each read observed its input. A file whose analysis read
nothing has no key.

- **Closure.** A recheck validates every distinct row once, however many files
  made it, and every file holding a row that no longer validates joins the
  affected closure: the read file was edited or removed, a path a read or probe
  found absent appeared, or a listing or glob's match set moved. The reader's
  text is unchanged, so it joins alone, with no dependents of its own.
- **Refresh.** A re-analysed file's rows are replaced by this run's, so a read
  it no longer makes stops guarding it; a removed file's rows are dropped. A
  recheck that found a stale row is a change (`Recheck#no_change?` is false), so
  its snapshot is saved even when no source file moved: the refreshed rows
  validate on the next recheck, which re-analyses the reader no more.
- **Pool.** Each fork worker collects its rows per file and marshals them
  back beside its dependency records. A read a plugin makes once per process
  is credited to whichever file triggers it first in that process. Each worker
  is a process of its own, so a pooled run can credit such a read to a file in
  every worker where the sequential run credits it to one file, or to none
  when the read happened before the per-file loop. That over-includes readers
  in the closure, which is conservative.
- **Paths.** A row names the path the plugin passed, made absolute without
  resolving symlinks, the boundary's own rule; a content row stats through the
  link, so an edit to its target goes stale.
- **Bounds.** This closure covers what a read decides about the reader's own
  rows, a plugin diagnostic among them. A read that decides a TYPE other files
  consume must sit behind the ADR-88 plugin fact surface (the plugin's
  published facts, its producer values, or its `incremental_state_fingerprint`
  hook), which
  invalidates the whole snapshot. Within this closure only reads are credited,
  the rule `IoBoundary.attributing` states: a value reused without a read
  reaches later files uncredited, whether the plugin memoised it or the engine's
  cross-file inferred-return memo reused a return computed while another file
  was analysed, so only the file whose analysis made the read joins the closure.
  A read made outside any file's analysis (in `#prepare`, or by a producer
  computed there) is credited to no file and moves nothing into this closure.
- **Cost.** Every recheck pays one validation per distinct row: a `File.stat`
  for a content row whose stat tuple did not move, an existence check for a
  probe row, and a re-glob for a listing row. A recheck that finds a stale row
  also re-analyses its readers and rewrites the snapshot once; the next
  recheck finds none. A null run the run-result slot serves builds no session
  and validates nothing here.

### `plugin_fact_digest` — plugin-fact soundness ([ADR-88](../adr/88-incremental-plugin-fact-soundness.md))

Plugin-contributed types (a Sorbet catalog signature, a dry-types alias, an
ActiveRecord column type) are consumed through the ADR-52 compiled-dispatch
path, which never crosses the `DependencyRecorder` choke points that build
the `symbol_sources` / `ancestry_sources` edges — so a plugin fact records
no cross-file edge, and an edit that changes one could otherwise leave a
consumer stale. `plugin_fact_digest` closes this: it fingerprints the plugin
fact **surface** the global fingerprint cannot see — (a) every ADR-9
fact-store publication, (b) every ADR-60 producer's computed **value** (the
value, deliberately, not its watched inputs — a whole-tree `watch:` glob
would otherwise invalidate on every edit), and (c) each plugin's optional
`Plugin::Base#incremental_state_fingerprint` hook (see
[`plugin-cache-producers.md`](plugin-cache-producers.md)). A change to the
digest drops the snapshot (a conservative full re-analysis). A plugin that
contributes types but exposes none of (a)/(b)/(c) makes the snapshot
un-reusable and is named — a forcing function to declare its surface rather
than a silent stale reuse. The `--incremental` note states the reason for each
opaque plugin: it declares no surface, or the input it declares cannot be
digested (or its hook raised). An unreadable fact store is reported once, with
no plugin named.

Each value is digested with `Cache::ValueDigest`, which MUST be a function of
the value alone ([#1574](https://github.com/rigortype/rigor/issues/1574)): a
producer's value is computed on one run and served from its ADR-45 entry on
the next, the two are equal but share different objects, and a digest that
read the sharing (as one of `Marshal.dump` bytes did) invalidated the snapshot
on every switch between them. The digest keeps the distinctions Marshal keeps
— classes, Hash and Set insertion order, a Hash's default, a non-ASCII
String's encoding — and ignores identity and frozenness. It reads a Data's or
Struct's members, an exception's message, backtrace and cause, and every
object's instance variables through the core classes' own methods, so an
override cannot hide a field. A value it cannot digest — state outside Ruby, a
default proc, an anonymous class, or a cycle or anything else nested past 256
levels — makes the plugin that owns it opaque, and so does a published fact of
that kind. A few things Marshal keeps are outside the digest by design, so a
change confined to them does not move the snapshot: instance variables set on a
String, Array, Hash or Set (which `==` ignores too), modules an object was
extended with, and the hidden fields a C-implemented class keeps outside
`instance_variables` other than an exception's message, backtrace and cause
(`NameError#name` reaches the digest only through the message).

### `synthetic_surface_digest` — the synthetic-method index ([#2286](https://github.com/rigortype/rigor/pull/2286))

The ADR-16 synthetic-method index (`SyntheticMethodScanner`, [`macro-substrate.md`](macro-substrate.md))
is built from class-body DSL calls — `devise :confirmable`, a Tier C `attribute :name, T`. No
declaration signature records those calls and no dependency edge names the file that wrote one, so
an edit that adds or removes `devise` leaves the model declaration-stable and its consumers outside
the closure. `synthetic_surface_digest` is `SyntheticMethodIndex#surface_digest` at the run the
cache was built under: every `(kind, class, method)` row in first-wins order with its return type,
Tier B `origin_module` and plugin id, plus the synthesised class names; nil for the empty index.
The call site's path and line are left out, so an edit that only moves the `devise` line keeps it.
A recheck compares its own runner's digest after the run (the index is built by the run's pre-pass)
and re-baselines when it moved and the recheck served any file, which `--incremental` reports as
cold. The comparison is the same in pool mode: the coordinator builds the index.

### `return_summaries` — semantic propagation gates ([ADR-89](../adr/89-semantic-propagation-gates.md))

Generalises the B1 comment-only gate to body edits: a dependent of a changed
file is re-analysed only when something it can consume actually changed.
Two persisted summaries prove "nothing changed":

- **Declaration shape** (consumed by ancestry / file-level dependents) — the
  ADR-85 seed bundle carries per-def signature shape (name, kind,
  parameter structure, visibility) plus superclass / include / layout, and
  the joined [#992](https://github.com/rigortype/rigor/issues/992)
  parameter-envelope table (which also moves on a wrapping macro such as
  `memoize :f` that no per-def shape records). A
  body edit leaves it equal; an arity, visibility, or added/removed-method
  edit does not. A declaration-stable changed file drops its ancestry /
  file-level dependents from the closure.
- **Observed-key return summaries** — per-def `(receiver, args) → return`
  descriptors harvested from the ADR-84 memo, plus the ADR-56 content-mutation
  effect set (the callee-visible surface beyond the return). On a recheck a
  declaration-stable changed def is re-evaluated at each stored key through
  the memo; all-equal returns **and** equal effects drop the def's symbol
  dependents. Any mismatch, a changed signature, a missing def, an
  ineligible def (one that also exposes ivar/cvar writes or `yield` values),
  or a cap overflow keeps the dependents — the conservative direction.

Both gates are premised on a `plugin_fact_digest` match for the run (asserted
in code, not assumed); `--verify-incremental` is the standing byte-identity
backstop for the whole mechanism.

Both summaries read a file's Ruby side. What a source-RBS synthesizer derives
from its comments — every `#:` / `# @rbs` annotation under the auto-wired
`rigor-rbs-inline` — is compared through the synthesizers' output instead
([#1536](https://github.com/rigortype/rigor/issues/1536), ADR-89 Amendment
2026-09-28):

- Each seed bundle carries `source_rbs_digest`: a digest of the RBS every
  loaded `source_rbs_synthesizer` contributes for the file, `none` when nothing
  is contributed, or `nil` when an output could not be read.
  `Environment::SourceRbsSynthesis.digest` reads the same function and
  `Cache::Store` entries the loader is fed from. WD6 / WD12 notices are left
  out of the digest input, never out of the loaded buffer: they feed only
  run-level `source-rbs-*` rows, and they quote line numbers. A failed synthesis
  still counts as one stable value. The RBS text is digested whole, comments
  included. RBS reads a `# resolve-type-names:` magic comment at the start of a
  buffer, where rbs-inline copies the `.rb` file's first comment line, so a
  comment line can change the environment. Rewording any comment in an
  annotated file therefore re-analyses the project until
  [#1549](https://github.com/rigortype/rigor/issues/1549) lands.
- `Analysis::SourceRbsGate` stamps the bundles the runner built in a run. A
  reused bundle keeps its digest, which stays exact because reuse requires
  byte-identical content. A stamp must describe the synthesized RBS its file's
  readers were computed under. The reading the closure was decided on is
  stamped only when the file's SHA-256, read before and after it, equals the
  bundle's content digest. A file saved after the closure was decided is never
  re-read. It is stamped `nil`, and its recorded content digest is dropped from
  `digests`, so the next run detects it as changed. A bundle built without such
  a reading is stamped from a fresh reading only when every file was just
  re-analysed, and `nil` otherwise. A `nil` stamp is re-stamped when its file is
  next read for a closure, or on the next whole-project run.
- A recheck whose edit moved any synthesized output re-analyses every analysed
  file. The output has moved when a changed file's digest differs from its
  bundle's (or either is unknown), when an added file contributes anything, or
  when a removed file did. The fallback is the whole project because a read of
  a `virtual:` buffer records no edge back to its `.rb` file, so no dependent
  set bounds its readers
  ([#1544](https://github.com/rigortype/rigor/issues/1544) tracks recording
  those reads). Otherwise the declaration gate runs on the signature alone.
- The gate never decides by which plugins `plugins:` names. It digests with the
  synthesizers of a registry it loads itself from the same configuration,
  without `#prepare`, before the recheck runner exists. A project without
  annotations keeps both gates with `rigor-rbs-inline` loaded, and an
  `enabled: false` entry, which the loader skips, contributes no synthesizer.
- After every `--incremental` run, one that read no file included, the gate's
  set is reconciled with the set of the registry the run's environment was
  built from, after `#prepare`, compared by plugin id and order. That registry is the one ADR-88's `plugin_fact_digest`
  reads: the runner's on a sequential run, the sequential probe's on a pooled
  one. A mismatch means a synthesizer built in `#prepare`, which the gate could
  not see. The gate then turns untrusted for the session, every bundle's digest
  is saved as `nil`, and every later edit re-analyses the whole project. For an
  edit whose recheck had left files out, `run_incremental` re-analyses the
  project and `run_buffer_recheck` declines. A run that changed nothing stays a
  null run, since every edit under the untrusted gate already re-analysed the
  whole project. A recheck that found a stale plugin read (`plugin_reads`,
  above) counts as a change, so it too re-analyses the project. The contract a synthesizer must keep is in
  [`plugin.md`](plugin.md).

### `effect_collections` / `effects_identity` — the effects sidecar ([ADR-103](../adr/103-effect-labels.md) WD13)

`effect_collections` maps each analyzed path to the `Rigor::Effects::FileCollection`
that file contributed — the *direct* summaries and unresolved call edges, never the
propagated table, which is re-run over the merged whole on every run (a leaf's summary
reaches every caller, so a stored closure would have to be invalidated by all of them).
A recheck re-collects only the changed closure and folds the rest back from here,
into the session's table and into the recheck runner's own graph, which is what the
envelope pass judges (#1898).

`effects_identity` is a **second gate**, independent of the global fingerprint above,
and it exists because the `effects:` block is deliberately absent from
`configuration.to_h`: turning collection on must invalidate no diagnostics, so the
global fingerprint cannot be what tells a run whether the persisted summaries mean what
its vocabulary and catalogue say they mean. It stores `Rigor::Effects::Identity.digest`
— the vocabulary version, the catalogue identity (`Catalog#identity`: schema + a content
digest of `data/effects/core.yml`) and the `effects:` block digest — as of the run that
wrote it, and `nil` when collection was off. A mismatch drops the collections **only**;
the diagnostics half of the payload is untouched, and the session then takes a full
baseline, because a recheck re-collects only the closure and a partial collection cannot
be closed into a whole-project fixpoint. A run with collection off keeps no collections,
writes `{}` / `nil`, and behaves exactly as it did before the slot existed.

`effect_plugin_digest` (#1898) is the plugin effect-fact digest (`PluginFacts#digest`) the
collections were stamped under. `effects_identity` is compared before any plugin loads, so
it cannot carry it; a recheck compares this one after its run instead, and re-baselines
when it moved and the recheck served any collection.

The contract in full — both slots, the two identities, and what each invalidates — is
[`effect-summaries.md` § Caching](effect-summaries.md).

### Run-level rows the snapshot carries

A run-level row is one produced once per run off the environment and its reporters,
not by any file's analysis. **No run-level row is served from the per-file cache** —
`IncrementalSession` caches only `Runner#per_file_diagnostics`, so every run
regenerates every one of them
([#788](https://github.com/rigortype/rigor/pull/788)). `run_level_rows` does not
weaken that promise: it is not a diagnostic cache but a record of two INPUTS a
narrowed run cannot observe, replayed so that the run can produce the rows itself.

Exactly two live here, and the list is closed:

- **`definition_build_failures`** — the reported `rbs.coverage.definition-build-failed`
  details. Its producer is the ANALYSIS's own demand for a class's method surface, and
  [#696](https://github.com/rigortype/rigor/issues/696) binds the reported set to that
  demand and forbids a Rigor-owned demand from contributing — so a run whose closure is
  empty demands nothing and reports nothing, and a `--verify-incremental` partition
  reports a subset of the full run's. The FAILURE itself is a function of the signature
  set, and only which of those failures was DEMANDED varies — replaying the last full
  run's demand set is what makes the row invocation-independent, the property #696 exists
  to protect. But the signature set has THREE sources and the fingerprint reaches only
  two of them:

  | source | fingerprint slot | covered? |
  | --- | --- | --- |
  | every `.rbs` under `signature_paths:` | `sig:` (content digest, per file) | yes |
  | gem / collection RBS | `gems:`, `rbs_collection:` (lockfile digests) | yes |
  | virtual RBS — what a plugin's source-RBS synthesizer derives from `.rb` files, which under [ADR-93](../adr/93-default-rbs-inline-ingestion.md)'s auto-wired `rigor-rbs-inline` is every `#:` / `# @rbs` annotation | none | **no** |

  Digesting the third would mean running every synthesizer over every source file, which
  is an environment build in all but name — and the fingerprint exists to gate the
  snapshot load BEFORE one. So a duplicate declaration can be removed from a `.rb` file
  without moving the fingerprint, and a replayed row would outlive its cause. An entry
  whose conflicting buffers name a `virtual:` buffer of a file in this run's closure
  (`PoolCoordinator#stale_replayed_failure?`) is therefore not replayed as it stands but
  RE-DERIVED ([#1929](https://github.com/rigortype/rigor/issues/1929)): unless this run's
  own analysis already reported the class, `PoolCoordinator#redemand_stale_failures` asks
  for its definition again in this run's environment (`RbsLoader#redemand_definition`,
  both sides), and reports it, with its current tuple, exactly when it still fails. That
  demand stands in for the previous full run's analysis, which made it; it is not a new
  Rigor-owned demand in #696's sense. A pooled run has no coordinator-side environment
  after dispatch and resolves one only when a stale entry needs it. A `virtual:` buffer
  whose file no longer exists makes its entry stale too, closure or not, so deleting an
  inline source re-derives the classes its declarations failed. Dropping the entry
  instead, as #796 did, lost every class the edit left failing whose demanding file sat
  outside the closure — a missing superclass in the edited file fails every subclass, and
  the subclasses' demands live elsewhere — so a warm row listed fewer classes than a cold
  one.

  [#997](https://github.com/rigortype/rigor/issues/997) added a fifth element to each
  per-class tuple — `unresolved_type_name_detail`, `nil` for every failure kind but
  `RBS::NoTypeFoundError` — carrying the unresolved token, the position
  `RBS::Location#to_s` renders it at, and (when applicable) the full Rigor refinement
  name that token is the truncated head of. It is computed ONCE, from the live error, at
  the exact moment {Environment::RbsLoader#store_definition_build_detail} records the
  rest of the tuple, and frozen alongside it — never re-derived from a replayed tuple,
  which by the time it reaches this snapshot is plain strings with no live
  `RBS::NoTypeFoundError` behind them to re-inspect. This is what keeps it safe under the
  SAME hazard the member and buffer-name fields already navigate (the ADR-54 environment
  cache's `RBS::Location` marshal patch drops per-node POSITIONS, reconstructing a
  zero-range sentinel on a cache hit): the fifth element is derived data, not a `Location`
  object, so a warm run replays the exact string a cold run computed rather than
  re-deriving a degraded one from a cache-loaded declaration's sentinel position.
- **`hkt_scan_failure`** — the `rbs.coverage.hkt-scan-failed` outcome tuple
  ([#784](https://github.com/rigortype/rigor/issues/784)). The scan has ONE outcome per
  environment, so a replayed outcome is exactly as fresh as the environment it was
  scanned from — which is to say: as fresh as the fingerprint, with the same virtual-RBS
  blind spot as the row above, since the loader the scan reads carries the synthesized
  buffers too. Unlike a definition-build failure it is a single tuple naming no buffers,
  so there is nothing to attribute to a closure and no drop to make; the staleness stands
  and is listed below. Replaying it is what lets a nothing-changed recheck skip resolving
  an environment at all ([#794](https://github.com/rigortype/rigor/issues/794)): it was
  the last demand on that path that nothing else needed.

Every other `.rigor.yml`-level row stays uncached and is regenerated per run:
`synthesized-namespace`, `quarantined-signature`, `environment-build-failed`,
`signature-standdown`, the `conforms-to` results, the plugin `prepare` /
pool-degraded rows. Each is read off state the run's own environment already
carries when it builds one, and none of them depends on which files were analysed
— so there is nothing for a replay to add, and caching one would be caching a
diagnostic rather than an unobservable input. A new row joins this section only if
it fails that test.

A plugin's run-scoped rows fail it when a per-file hook registered them: which
files were analysed decides whether the hook ran. They do not join this section,
since their freshness is per file, not per fingerprint. They are replayed per file
through `plugin_disclosures` (above), whose records go stale with the boundary
reads the registering plugin had made. A row a plugin registers in `#prepare`
passes the test and stays uncached.

The replay is supplied to a NARROWED run only (a recheck's closure, an empty
closure, a `--verify-incremental` partition); a full run derives both for itself and
overwrites the section, so every staleness below is bounded by the next cold or full
run. "A full run" here means one that rewrites the snapshot: a cold `--incremental` run
after the fingerprint moves (`sig:`, a lockfile, the configuration, the engine) or after
`.rigor` is wiped. A plain `rigor check` or a `--no-cache` run reports the right row but
does not rewrite the snapshot, and `--verify-incremental` says OK, since it never reads
the snapshot. `absorb` persists each recheck's row, so a staleness below lasts across
every warm run until then. Three residuals stand, stated plainly:

1. **A demand that vanished (pre-existing, #796).** The demanding `.rb` file stops
   demanding a broken class — it is deleted, or an ordinary edit removes the reference —
   and nothing else demands it; a fresh full run would report nothing for that class,
   while the replay still reports it. Nothing in the fingerprint moved, and a tuple that
   names only `sig:` files (or bundled RBS) is never stale, so it replays unchanged. This
   is the price of #796's option 1 — the alternative (replaying the prior demand SET
   against a freshly resolved environment) buys the same answer for exactly the cost this
   section exists to avoid.
2. **A virtual-RBS change outside the closure re-derivation (pre-existing).** The
   re-derivation above covers the shape that matters (the edit is in a file the run
   analyses, or the file a tuple names was deleted) and the fingerprint covers `sig:`;
   what neither covers is a virtual-RBS edit that changes the row without touching a
   named conflicting buffer, or the `hkt_scan_failure` tuple, which names no buffers at
   all. Both survive until a full run.
3. **A re-derived class whose demand left with the edit (introduced by #1929).** A stale
   entry is re-derived without knowing which file demanded it. When the only demand was in
   the edited file and the edit removed it while the class still fails, the recheck keeps
   reporting the class and a full run does not. Before #1929 the drop gave the full run's
   answer on this shape, so it is a regression there: a false positive against the cold
   answer, lasting until a full run, which under `--fail-on warning` can flip the exit
   code. The failure is real; only the demand is stale. Closing it needs per-file demand
   attribution in the snapshot ([#2060](https://github.com/rigortype/rigor/issues/2060)). The trade bought by it: the drop lost every class the
   edit left failing whose demand sat outside the closure, which is the common shape (an
   inline superclass or mixin failing every subclass).

`--verify-incremental` does not bind any of this: `IncrementalSession#reanalyze_subset`
replays the rows off the SAME process's freshly computed baseline, so it verifies the
union logic and never the persisted snapshot. The cross-process oracle that does bind it
is `spec/rigor/analysis/incremental_session_spec.rb` — two `Cache::Store`s over one
snapshot directory, a `.rb` edit between them, compared against a `--no-cache` full run.

### The run-result key's analysis roots (ADR-45, #1559)

The plain `analysis.run-diagnostics` key (`RunCacheKey.descriptor`) names the analysed files
(`paths`), not the roots they expanded from, and a root that contributes no file still
changes the printed rows: `rigor check lib extra` with `extra` missing prints
`extra:1:1: warning: no such file or directory (skipped)` and `rigor check lib` does not.
`RunCacheKey.with_roots` therefore adds a `roots` config entry over the roots as the run was
given them, in order and as spelled (`Runner#expand_paths` carries them as `:roots`), to the
diagnostics key, on both readers: the runner's slot and the engine-free `RunCacheProbe`.
Unlike the `--incremental` slot's `incremental.roots` entry below, they are neither made
absolute nor sorted, so a reordered or respelled root set (`extra lib`, `./lib`, `lib/`, an
absolute path) is a slot of its own: a forgone hit, never another run's answer. The entry is
not part of `RunCacheKey.descriptor`, so the `--incremental` key built on it and the
ADR-103 effects sidecar identity (still one generation per analyzed-path SET) are unchanged.
A new key entry is a new slot, not a schema change: entries written before it are simply
never read again. The key fixes which roots were asked for; whether each exists, and as
what, is a `:kind` row in the slot's dependency descriptor (#1962, the run-descriptor row
inventory).

### The run-result slot (ADR-45 WD2)

After every run whose snapshot it persists, `IncrementalSession#run_incremental`
also writes an ADR-45 record-and-validate entry, `analysis.incremental-run-diagnostics`,
and `rigor check --incremental` serves a null run from it before loading the engine
(`Analysis::IncrementalRunSlot.serve`). The decision, and what a hit does and does not
guarantee, is [ADR-45](../adr/45-unchanged-project-fast-path.md) WD2; this is the contract.

- **Key.** `RunCacheKey.descriptor` exactly as the ADR-87 WD4 probe builds it —
  `RunCacheKey.libraries_config_entries`, no `template-units` slot, `explain: false`, its
  `dependencies:` rows for the opted-in gems included (#1814) —
  over the session's analysed-path set, plus an `incremental.roots` config entry over the
  analysis roots, normalised to absolute paths and sorted (`IncrementalRunSlot::Target`,
  `.normalize_roots`). The producer id and the roots entry each keep it apart from
  `analysis.run-diagnostics` on their own. A project whose plugins claim template globs is
  written and served: the template rows below validate what the plain key's
  `template-units` slot would key.
- **Value.** `IncrementalRunSlot::Entry(diagnostics, roots, baseline, pinned, reads, snapshot)`.
  `diagnostics` is what the run printed before the baseline filter; the CLI applies the
  filter, `--fail-on` and the output format to it exactly as the full incremental path
  does (`CheckCommand#write_incremental_result`). `roots` are the roots as the run was
  given them (`.as_written`), and the probe serves the entry only to a run that names them
  the same way in the same order. `baseline`, `pinned` and `reads` (`{path => Descriptor}`) are
  the chain a later recheck carries forward; `snapshot` is the `(size, mtime_ns, ctime_ns, inode)` of the
  snapshot file the writing run left behind.
- **Dependency descriptor.** A `:stat` row per analysed file, from the session's own
  `digests` (the bytes each answer was computed from), re-packed by
  `Cache::FileDigest.refresh_stat` when the bytes, hashed afresh rather than from the
  per-run memo, still match and the tuple packed after that hash is the one taken before
  it; `Runner#incremental_slot_rows`' `observed` rows (every plugin boundary row, each
  producer's `watch:` globs among them, recorded as the plugin read) and `derived` rows
  (taken when the run ends: the template files and one `:names` row per claimed glob, and
  a `:kind` row per analysis root and `pre_eval:` entry); the chain's `baseline` and
  `pinned` (`Runner#baseline_dependency_rows`: the signature tree and a `:kind` row per
  signature root, the discovered-not-analysed files and a listing row per discovery root on
  every run that widened, whether or not the widening added a file (#1583),
  the `pre_eval:` files outside the analysed set; `pinned` holds the signature files
  outside the project's own signature roots, which the key's engine slot or lockfiles
  identify, and `baseline` the rest); and
  every file's `reads`. A file's `reads` are what `Plugin::IoBoundary.attributing` collected
  while it was analysed: every row a live recorder took and every row `IoBoundary#replay`
  handed back for a producer served during that analysis (#1558), the rows a held row
  wins over included.
- **Carrying.** A full run starts the chain. A recheck takes the previous slot's `Entry` —
  read with `peek_unvalidated`, keyed by the path set of the snapshot it restored and the
  same roots — carries `baseline` unchanged, keeps the reads of the files it served from
  cache, replaces those of the files it re-analysed, and drops the removed files'. It
  writes NOTHING when the previous entry is missing, or names a snapshot file other than
  the one it restored; the fast path then stays off until the next full run starts a
  fresh chain. When the path set moved it discards the previous entry after writing its own.
- **Write guard.** `IncrementalRunSlot::WriteGuard` takes a mark before the run reads
  anything: the change time and device of a stamp file written under
  `<cache>/incremental/` (the filesystem's own clock). The mark is taken on a tick
  boundary: stamps are written until one carries a change time later than the first
  stamp's, on the same device, and that later change time is the mark. A save before the
  run then carries at most the first stamp's change time and is admitted, while a save at
  or after the mark, in the same tick or later, is refused (`>=`). A filesystem that does
  not tick within the wait bound (`TICK_WAIT_LIMIT`, 50 ms, monotonic clock) takes no mark,
  so no slot is written. No mark is taken, and no slot
  written, when the stamp is not on the device of the working directory, or when the
  snapshot fingerprint the run was given, recomputed after the stamp, has moved. The slot is
  written only when, at write time, nothing the guard watches moved: every lockfile the
  key or the fingerprint may read (`bundler.lockfile`, `rbs_collection.lockfile`,
  `Gemfile.lock`, `rbs_collection.lock.yaml`), one present at the mark still there with
  its change time before it and one absent still absent; every opted-in gem still resolving
  to the `(name, version, mode)` it did at the mark (#1814); the analysed files' rows, the
  `derived` rows and the chain's `baseline`, carried or taken; and the chain's `pinned`.
  No path a content row names, no directory a glob row lists and no file a `:stat` glob
  matches may have a change time at or after the mark. The mark records what each of the
  analysis roots, the `pre_eval:` entries and the signature roots is (`FileEntry.kind_of`).
  A `:kind` row for one of those paths moved if the path's kind differs from the mark's,
  and an existence row if its presence does (#1977); its directory's change time is not asked,
  so an editor's lock file beside it does not refuse the write, and a path that comes and
  goes again within the run is not seen. A glob row still compares its directory's change
  time, so a file created and removed in a listed directory (an editor's swap file in
  `lib/` during a run that overran the mark) refuses the write; that is safe, and known.
  Any other existence or `:kind` row is judged by its own
  change time, or its nearest existing ancestor's when absent. A path whose change time is
  asked refuses the write when it is on another device, except a `pinned` row's, which is
  passed over. A content row whose file is gone passes; the row is stale already. The `observed` rows and
  the carried `reads` are not asked about: a later save leaves a row taken as it was read
  stale. The plugin-read rows (`observed` and `reads`) and every other `:stat` row of the slot
  are written with their recording instant lowered to the mark (`WriteGuard#mark_racy`), so a
  file whose mtime is at or after the mark is racy and re-hashed on validation, rather than
  trusted on an unmoved stat tuple after a same-size save in a coarse tick. Bounds of the mark:
  - The guard takes one more stamp when it is asked, and refuses when that stamp's change time
    is earlier than the mark, or the stamp cannot be written or is on another device: a clock
    stepped backwards during the run (an NTP correction) is seen. A step undone before the run
    ends is not.
  - A filesystem whose first stamp lands on a whole second (HFS+, FAT, ext3) ticks too coarsely
    to wait out, and takes no mark at once.
  - Native Windows takes no mark: `File::Stat#ctime` is the creation time there.
  - A network or FUSE filesystem (NFS with its attribute cache, virtiofs, gRPC-FUSE, sshfs) may
    report a change time from before a save; nothing detects that.
- **Not written** for an editor buffer, a pool run, an `--explain` run (the key has no
  explain slot), a project with effect collection
  on, a run with an opaque plugin, a run in which a boundary row changed during the
  per-file loop without being credited to a file, or a run after which the session holds no content digest for some analysed file
  — the #1536 source-RBS gate forgets the digest of a file saved after the closure was
  decided (`forget_unbound_digests`), and no row could then say what that file's readers
  were computed from. A run under an untrusted gate is written: the gate decides the
  closure, and an analysed file's row declines for any edit whatever it decided. Nor
  when the write guard sees an input that changed after its mark.
  **Not served** under `--no-cache`, `--verify-incremental`, `--explain`,
  a worker pool, `--coverage`, `--cache-stats`, a `RIGOR_*_TRACE` probe, or effect
  collection.

A hit reads and writes nothing of the snapshot, as a null recheck already writes
nothing (ADR-87 WD3).

## Bundled RBS producer contract

Every bundled RBS-derived producer documented below (`RbsConstantTable`, `RbsKnownClassNames`, `RbsClassAncestorTable`, `RbsClassTypeParamNames`, `RbsEnvironment`) satisfies one shape — a class object responding to `fetch(loader:, store:)` and returning the cached or freshly computed value. This is codified as the structural interface `_CacheProducer` in [`sig/rigor/cache.rbs`](../../sig/rigor/cache.rbs): a structural interface (the RBS/Go sense), not an ADR-28 protocol contract, and distinct from the plugin-side producer surface in [`plugin-cache-producers.md`](plugin-cache-producers.md).

The `fetch` body is identical across producers: read the shared RBS descriptor (`loader.rbs_cache_descriptor`, the per-loader memo around `RbsDescriptor.build`), then call `store.fetch_or_compute(producer_id:, params: {}, descriptor:, generation_cap:)` yielding to the producer's `compute(loader)` — or, when that descriptor is `nil` (an engine whose source could not be digested, #1014), call `compute(loader)` directly and store nothing. Only the `PRODUCER_ID` constant and the `compute` body differ. That shared wiring lives on the `Rigor::Cache::RbsCacheProducer` base; a producer MUST subclass it and declare its own `PRODUCER_ID` and a (private) `self.compute(loader)`. The base also declares `self.generation_cap` (2 — see § "Compaction"), which a subclass inherits and may override; no `rbs.*` producer can therefore be added without a compaction budget. The base reads `self::PRODUCER_ID` so the constant resolves on the concrete subclass. The per-producer sections below specify each producer's `PRODUCER_ID`, `compute` output type, and the `cache_store` consumer that reads it.

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
Marshal-safe shape. Both options were out of scope for the v0.0.8
slice budget — see [ADR-6 § 8 "RBS::Environment serialisation"](../adr/6-cache-persistence-backend.md)
— and neither was taken: v0.0.9 resolved it by a third route
neither option anticipated, an additive `RBS::Location` Marshal
patch that lets the env ride the default `Marshal` path. See
[§ `Rigor::Cache::RbsEnvironment`](#rigorcacherbsenvironment-v009-c2).

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
returns `Rigor::Type::Bot` or raises `RBS::BaseError` (a broken
signature) are dropped from the table — analyzer-internal errors
propagate rather than corrupting the table silently.

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
`rescue ::RBS::BaseError` inside the iterator means a broken RBS
environment yields no names rather than aborting the whole run.
Analyzer-internal errors (`NameError`, `NoMethodError`,
`LoadError`) are deliberately **not** swallowed — a v0.0.9
regression hid behind a broader rescue here.

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
{`RbsDescriptor.build`} so a single signature change, an rbs gem
bump, or an engine edit in a checkout (§ "Engine identity in a
computed-value key") invalidates this producer alongside the four
post-translation caches.

### `RbsEnvironment.fetch(loader:, store:) -> ::RBS::Environment`

Returns the env. The producer block calls
`Rigor::Environment::RbsLoader.build_env_for(libraries:, signature_paths:, virtual_rbs:)`
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
  def _dump(_) = buffer&.name.to_s
  def self._load(name) = new(buffer: Buffer.new(name: name, content: ""), start_pos: 0, end_pos: 0)
end
```

The patch is purely additive (only adds methods that previously
raised `TypeError` on dispatch) and idempotent (gated behind
`method_defined?(:_dump)`).

A cached location keeps the buffer NAME and drops the per-node
source POSITION. The name is not inert:
`rbs.coverage.definition-build-failed` names the conflicting
signature files, and a name-less dump made a warm run omit that
clause while a cold run printed it (issue #696). The position is
dropped because it is far more numerous — one per AST node — and
no analysis path consults it: every diagnostic over Ruby code
flows through Prism's own location. Code paths that DO read a
Location after a cache hit (e.g. third-party tools) see a benign
zero-range sentinel rather than crashing.

**Annotations are the exception, and MUST carry their position.**
`RBS::AST::Annotation` defines its own `marshal_dump` /
`marshal_load` (issue #799) which carry
`[string, [name, start_line, start_column, end_line, end_column]]`,
reconstructed through `Rigor::Cache::AnnotationLocation`, whose
nested `Buffer` is a content-less `RBS::Buffer` subclass that
answers `pos_to_loc` from the carried pairs — all that
`RBS::Location`'s C-level `start_line` and siblings consult.
The two `conforms-to` rows,
`rbs_extended.unsatisfied-conformance` and
`dynamic.rbs-extended.unresolved`, are positioned at the `%a{…}`
the author wrote rather than at any Ruby `def`, so an
annotation's position is the one position in a cached environment
that a diagnostic reads. (`effect.unknown-label` is positioned at
an annotation too, but `EnvelopeScanner` reaches it by parsing
the project's own `.rbs` rather than the built environment —
refusing this loss is one of the two reasons it does.) Without
the carry it
collapsed to `1:1`: `rigor check --verify-incremental` FAILED on
every project with an unsatisfied `conforms-to` (the replica
normalises rows by position, and only one side of the comparison
runs against the cached environment), and a warm `--incremental`
run moved the row on a tree that had not changed. Scoping the
carry to annotations rather than doing it in `RBS::Location#_dump`
is what keeps it free: a Location hangs off every AST node, and
carrying its position measured +2.9% on the environment blob,
where the same carry on annotations alone — 18 of them in that
env — measured +1.4 KB on ~10 MB.

A blob written before the carry still loads — Marshal encodes an
ivar dump and a `marshal_dump` payload differently, and only the
latter reaches `marshal_load` — so `Store::FORMAT_VERSION` is
what stops a stale blob from reporting the moved position
indefinitely — the LRU size cap (ADR-54 WD3) evicts by size, not by
staleness, so a blob under the cap does not age out on its own.

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

Every RBS-derived producer (`RbsConstantTable`,
`RbsKnownClassNames`, `RbsClassAncestorTable`,
`RbsClassTypeParamNames`, `RbsEnvironment`) depends on the same
RBS environment state, so they share one descriptor builder —
memoised per loader as `RbsLoader#rbs_cache_descriptor`
([ADR-54](../adr/54-cache-slimming.md) WD4), so the `.rbs` tree is
digested once per process rather than once per producer:

```ruby
Rigor::Cache::RbsDescriptor.build(loader)
# => Descriptor with:
#    gems    = [{ name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION }]
#    files   = [...]   # :digest entries for every .rbs under signature_paths
#                      # + the vendored gem sigs + the core overlay
#    configs = [{ key: "rbs.libraries",  value_hash: SHA256(sorted-libraries) },
#               { key: "rbs.virtual_rbs", value_hash: SHA256(sorted-pairs) },
#               { key: "engine-source",   value_hash: SHA256(engine identity) }]
```

The `engine-source` row is the #1014 slot — see § "Engine identity in a
computed-value key". It comes from `EngineSource.key_config_entries`, is
absent for a version-pinned tree, and raises
`EngineSource::Unavailable` out of `.build` for an engine that cannot be
digested, which `RbsLoader#rbs_cache_descriptor` turns into `nil` and
`RbsCacheProducer.fetch` into an uncached compute. It rides in `.build`
only, never in `.config_entries`.

The `rbs.virtual_rbs` row is the ADR-32 WD5 slot: it hashes the
loader's plugin-contributed synthesised RBS strings so the env
cache invalidates when one changes or first appears. It is
omitted entirely when the loader has no `virtual_rbs` entries, so
a project with no synthesizer-emitting plugin pays no descriptor
cost for it.

Sharing the builder means a single signature change or rbs gem
bump invalidates every RBS-derived cached producer in lockstep.

### `RbsDescriptor.build_run(loader) -> RunDescriptor`

The lazy-`files` variant behind the ADR-45 run-diagnostics
record-and-validate cache. `RunDescriptor` is **not** a
`Descriptor` — it is never composed, hashed, or `==`'d, and only
its four readers (`gems`, `configs`, `files`, `globs`) are consulted — so
`files` can be deferred without costing soundness. `gems` and
`configs` are supplied eagerly and are byte-identical to
`.build`'s shared half — `RbsDescriptor.config_entries`, without the
env-only rows and without the `engine-source` row, which `RunCacheKey`
contributes on its own behalf (the run cache key is unchanged); `files` is computed on
first access and memoised, so a warm HIT never digests the large
vendored RBS tree at all. When it is read — only on a MISS, by
the run's dependency descriptor — it uses the `:stat` comparator
rather than `:digest`, since a validated descriptor may carry
machine-local stat data (`.build`'s cache-KEY `files` stay
`:digest`). `RbsDescriptor.rbs_gem_entry` is public for the same
reason: the ADR-87 WD4 probe reconstructs the identical `gems` +
`rbs.libraries` key slots without holding a loader.

`globs` ([#979](https://github.com/rigortype/rigor/issues/979)) is the
directory-LISTING half, one `GlobEntry` per signature root over
`**/*.rbs` (`RbsDescriptor.glob_entries`). `files` answers only "did a
signature file I read change", which is a question about the files that
existed while the run read them — so a `sig/roles.rbs` written after the
run was in no row, the `analysis.run-diagnostics` dependency descriptor
validated fresh, and the warm run replayed diagnostics computed without
it (an unsatisfied `conforms-to` kept reporting `unresolved` after the
interface it names was declared). A glob row re-globs on the next run and
sees the appearance, exactly as the `IoBoundary#list_directory` row does
for a plugin-listed directory. It is recorded once per signature ROOT,
not per file: validation is a single `Dir.glob` per root whatever the
tree's size.

The rows are `:names` mode. What they add is which signature files exist;
every edit to one of them is already carried by that file's own `:stat`
`FileEntry` row, which survives a moved stat tuple by falling back to the
recorded content digest. A `:stat` glob would not, so a `git checkout`
touching a `.rbs`, a `bundle install`, an `rbs collection install`, or any
CI run with a restored cache over a fresh checkout would cost a full
re-analysis while changing no RBS at all. Names mode also reads no stat,
so these rows neither pay for nor perturb the per-run
`FileDigest.validation_stat` memo a collecting run shares between its two
validation passes.

The roots are the loader's own `signature_paths` — the project's
configured paths (including the auto-detected `sig/`), the bundled
plugins' `sig/` trees ([ADR-25](../adr/25-plugin-contributed-rbs.md)),
the bundle walk, `rbs collection`, and the ADR-72 overlays. Rigor's own
`data/` signature trees (`vendored_gem_sigs/`, `core_overlay/`,
`capability_roles/`) get `files` rows and deliberately no glob row: they
are engine-owned, so a file appears under one only when the engine tree
itself is edited, which for an installed gem means a different
`Rigor::VERSION` and for a checkout normally arrives with the `lib/`
change that reads it — and that re-keys every computed-value slot through
`EngineSource`. The residue (adding a `.rbs` under `data/` in a checkout
and touching no `.rb`, since `EngineSource` digests `.rb` only) is an
engine-development edit, not a project edit, and buying it would cost
every project a stat walk of the vendored gem-signature tree on every
warm run.

### The run-descriptor row inventory

`Analysis::Runner#build_run_dependency_descriptor` composes, for the
ADR-45 `analysis.run-diagnostics` slot:

| Row | Source | Catches |
| --- | --- | --- |
| `:stat` file, per analyzed file | `analyzed_file_entries` | an edit to any file the run analyzed |
| `:stat` file, per discovered-not-analyzed file | `discovery_file_entries` ([#684](https://github.com/rigortype/rigor/issues/684)) | an edit to a file a widened run only discovered |
| `:stat` file, per `pre_eval:` file | `pre_eval_file_entries` ([#352](https://github.com/rigortype/rigor/issues/352)) | an edit to an ADR-17 pre-evaluated file |
| `:stat` file, per **template** file the run READ — the ones that produced a unit AND the ones that failed | `template_unit_file_entries` ([#392](https://github.com/rigortype/rigor/issues/392)) | an edit to a `.erb` / `.rbx` / … a plugin claimed, including one whose transform raised or whose bytes could not be read |
| names glob, per configured root, on a run that widened its discovery | `discovery_glob_entries` ([#1583](https://github.com/rigortype/rigor/issues/1583)) | a file APPEARING under a configured path a run over path arguments discovers, including when the widening had added no file before it |
| names glob, per claimed `template_globs:` pattern | `template_unit_glob_entries` (#392) | a template APPEARING under or vanishing from a claimed glob |
| `:stat` file, per `.rbs` under every signature root and under Rigor's own `data/` trees (`vendored_gem_sigs/`, `core_overlay/`, `capability_roles/`) | `RunDescriptor#files` → `RbsDescriptor.file_entries` | an edit to a signature file the run read |
| names glob, per signature root (`**/*.rbs`) | `RunDescriptor#globs` (#979) | a `.rbs` APPEARING under or vanishing from a signature root |
| `:stat` / `:exists` file, per plugin `IoBoundary` read | `IoBoundary#cache_descriptor` ([#577](https://github.com/rigortype/rigor/issues/577)) | an edit to — or the appearance of — a file a plugin read or probed |
| glob, per plugin-listed directory | `IoBoundary#cache_descriptor` ([#954](https://github.com/rigortype/rigor/issues/954)) | a file appearing in a directory a plugin listed |
| every row of a producer entry the plugin was served from | `IoBoundary#cache_descriptor`, replayed by `Plugin::Base#cache_for` ([#1558](https://github.com/rigortype/rigor/issues/1558)) | an edit to a served producer's input, which this run never read |
| glob, per producer `watch:` pattern | `Plugin::Base#watch_glob_entries` (ADR-60 WD3) | an edit under a producer's declared watch |
| `:kind` file, per analysis root | `root_presence_entries` ([#1962](https://github.com/rigortype/rigor/issues/1962)) | a root appearing, vanishing, or turning from a directory into a file or back, which moves its path-error row (`no such file or directory`, `not a Ruby file`) while the analysed set stays the same |
| `:kind` file, per `pre_eval:` entry and per project signature root (configured, or the auto-detected `sig`) | `root_presence_entries` (#1962, [#1555](https://github.com/rigortype/rigor/issues/1555)) | a missing `pre_eval:` file or signature root being created, or a directory and a file trading places there, which no other row covers |

The ADR-103 effects sidecar validates against this same descriptor, but its identity is one
generation per analysed-path set, not per root set. So the root `:kind` rows can cost it a
warm start it would otherwise have had: `rigor check lib x` with `x` missing, then
`mkdir x`, then `rigor check lib` finds the sidecar's `x` row stale and re-collects. That
is a recomputation, never a wrong answer, and it is a known cost of sharing the descriptor.

The two template rows are the validation half of a pair. The KEY carries a
`template-units` `configs:` slot hashing **the claimed globs, every unit's
compiled digest** (`ruby_source` bytes + transform id + synthesis version) **and
every failure**, keyed by path — which is what decides whether a cached answer
describes this world; the rows above are what notice that a template on disk
moved, appeared or vanished. The failures are in the slot because a run that
produced only failures still produced an ANSWER (one `plugin_loader` row per
file): without them such a run's key equalled the no-templates key, and the
answer outlived both the repair and the deletion of the template that caused
it. The slot is nil — and so absent — only when no plugin claimed a glob at
all, so a project with no template-unit plugin keeps exactly the key and
descriptor it had.

A plugin editing its own `template_globs:` therefore moves the key, because the
sorted claimed patterns are hashed into the slot.

Both halves are unchanged by [#1038](https://github.com/rigortype/rigor/issues/1038),
which lets a long-lived owner (`LanguageServer::ProjectContext`) carry the
compiled index across runs on its `Analysis::ProjectScan`. A carried unit is
reused only when the template's own ADR-87 stat-then-digest pack still validates
against the file on disk — and, since
[#1047](https://github.com/rigortype/rigor/issues/1047), only when no other
template its plugin claims has moved either — so a reused unit has, by
construction, exactly the
digest a freshly compiled one would have had: the key slot and both descriptor
rows are byte-identical either way, and the carry is invisible to this cache.

The ADR-87 boot-slim probe loads no plugin and therefore reconstructs no
`template-units` slot: on a project whose plugins claim any glob the probe
simply misses and the full path takes over, the same forgone-fast-lane trade
`rbs.virtual_rbs` already makes, and never a wrong hit.

The `--incremental` slot records the same rows, with the analysed files'
digests taken from the session rather than re-read, a `:kind` row per
analysis root, `pre_eval:` entry and signature root, the rows a recheck does
not re-derive carried from the last full run, and the plugin reads kept per
analysed file; see § "The run-result slot (ADR-45 WD2)".

Non-file inputs (the engine source, the lockfiles, the resolved
configuration, the RBS library list) belong to the cache KEY
(`Analysis::RunCacheKey`), never here: `Descriptor#fresh?` refuses any
descriptor carrying a `gems` / `plugins` / `configs` / `dependencies`
slot.

The persisted SHAPE barely changed — `globs` is an existing slot (v4), and
the rows only add a `mode` field that serialises to nothing in the default
mode — but
`SCHEMA_VERSION` still went 8 → 9, for the migration reason v8 records one
slot over: an entry written before #979 carries no signature-root row, so
it would validate FRESH across exactly the file-appearance edit the row
exists to catch, and would keep replaying pre-fix diagnostics until it
missed for some unrelated reason. The bump makes every pre-fix entry read
as a miss once and rebuild carrying the rows.

The served-producer rows (#1558) are the rows the producer's entry
recorded when it was computed: its own reads, the rows its plugin's
boundary already held then, and its `watch:` globs, all validated by
the hit. A replayed `watch:` row equals the one the last table row
recomputes, and the descriptor's glob `uniq` drops the duplicate.
`SCHEMA_VERSION` went 10 → 11 with them, for v8's migration reason: an
entry written before the fix, while a producer hit, lacks the rows and
would validate fresh across exactly the edit they exist to catch. Two
cases were covered without the bump. A checkout, `path:` or `github:`
install carries the engine's source digest in this slot's key and in
every producer key, so the fixing tree missed its old entries; and a
release bump changes `PAYLOAD_ABI_VERSION`, which clears the root. The
case left over was a build installed under `gems/rigortype-<VERSION>`
with an unchanged `VERSION` (a `gem build` of unreleased `master`):
`EngineSource` treats that layout as version-pinned and adds no digest
(#285), so it would have kept serving pre-fix entries. The bump costs
one cold run where a release would not already have cleared the root.

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
  schema_version: 0.3.1.6.2
  3 entries, 12.4 KiB
    rbs.constant_type_table: 1 entries, 11.0 KiB
    rbs.environment: 2 entries, 1.4 KiB
  this run: 5 hits, 1 miss, 1 write
    rbs.constant_type_table: 5 hits, 1 miss, 1 write
```

The `schema_version` line is not a fixed literal — it is
`Store.schema_marker_value`, i.e.
`"<PAYLOAD_ABI_VERSION>.<Descriptor::SCHEMA_VERSION>.<Store::FORMAT_VERSION>"`,
where `PAYLOAD_ABI_VERSION` is `Rigor::VERSION`. The sample above
is what that composes to as of this writing (`0.3.1` + schema `6`
+ format `2`); read a mismatch against your installed release as
this sample being stale, not as a fault.

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
at zero. Bumped inside `#fetch_or_compute`, `#fetch_or_validate`,
and `#peek_validated` (which records hits only). A hit increments
`:hits`. On a miss both `:misses` and `:writes` are recorded
*after* the producer block returns and the write is attempted —
`:writes` only when the entry actually landed, so a read-only
store or a swallowed filesystem error records a miss with no
write, and a producer block that raises records nothing at all.
Per-producer counts mirror the totals so callers can report the
breakdown shown above.

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

This carries ADR-2's plugin-observability story (`plugin.<id>`,
`rbs_extended`, `generated.<provider>`). The surface is live: the
runner stamps `plugin.<manifest.id>` on every plugin diagnostic
(plugin authors must not set it themselves — any value they pass
is overwritten), `RBS::Extended` emits `:rbs_extended`, the
contribution merger `:contribution_merge`, and the plugin loader
`:plugin_loader`. **As of this writing `generated.<provider>` is
reserved with no consumer.**
