# Cache slice taxonomy — pre-v0.1.0 design notes

Status: **Draft.** Not normative. Captures the cache descriptor
schema that v0.1.0's persistent on-disk cache (per [MILESTONES.md](../MILESTONES.md)
and [ADR-2 § "Registration, Configuration, and Caching"](../adr/2-extension-api.md))
will be built against. Pure design output — no code changes flow
from this document. The successor to this draft will be a normative
spec in `docs/internal-spec/` once the schema is implemented.

This work is the next pre-v0.1.0 sub-slice after the v0.0.7
Reflection facade migration ([`docs/internal-spec/reflection.md`](../internal-spec/reflection.md);
sequencing in [`20260505-v0.1.0-readiness.md`](20260505-v0.1.0-readiness.md)).
The persistence layer that follows from this design is **not** part
of v0.0.x — it ships in v0.1.0 alongside the plugin API.

When this draft disagrees with [ADR-2](../adr/2-extension-api.md),
the ADR binds and the draft is out of date.

## Goal

Define a single, typed cache-key schema that every analyzer-internal
producer uses to attach an invalidation descriptor to the values it
caches. The schema must:

1. Enable a warm `rigor check` run to skip work whose inputs have
   not changed.
2. Compose deterministically when multiple producers contribute to
   the same value (e.g. a method's resolved type uses RBS sigs +
   in-source `def` shape + plugin dynamic-member facts).
3. Stay narrow enough that "edit one source file" or "bump one gem
   version" invalidates the smallest possible slice — never the
   whole cache.
4. Be extensible without breaking existing consumers: adding a new
   slot is an additive change; renaming or removing a slot needs
   schema-version migration.

## Non-goals

- **Persistent storage layout.** The on-disk format (sqlite,
  msgpack, single-file flat, sharded directory, …) is out of scope
  for this draft. The schema below is storage-agnostic.
- **Hot reload.** v0.1.0 caches are between-runs only.
  Long-running daemons / LSPs are a future surface.
- **Cross-machine cache sharing.** All paths in the schema are
  project-relative; a cache built on one machine is consumable on
  another with the same project / gem state, but distribution
  semantics are not part of this draft.

## ADR-2's working answer

ADR-2 § "Registration, Configuration, and Caching" already pinned
the four-slot shape:

> Cache dependencies should be explicit descriptors rather than an
> after-the-fact list of arbitrary reads. The first implementation
> uses a typed-slot schema with a fixed set of slots and per-entry
> comparators, rather than a flat list of kind-tagged entries:
>
> - `files`: project or external file inputs. Each entry carries a
>   path and a digest or mtime policy.
> - `gems`: gem name and version constraint or pinned version.
> - `plugins`: plugin identifier and pinned plugin gem version.
> - `configs`: configuration keys and a hash of their accepted
>   value, so a toggled feature flag invalidates only the depending
>   slice.

This design doc fills in the per-slot shape detail and the
composition / invalidation semantics that ADR-2 left to the
implementation.

## Per-slot detail

The cache descriptor is a `Rigor::Cache::Descriptor` value object
with four slots. Every slot is an array of typed entries; an empty
array means "no dependency in this slot".

### `files`

Each entry pins a single file input — project source, generated
signature, vendored RBS, schema, fixture, anything the producer
read while building the cached value.

```
FileEntry := { path: String, comparator: Comparator, value: String }

Comparator := :digest | :mtime | :exists
```

- `path` is project-relative whenever the file is under the project
  root; absolute otherwise. Symlinks resolve to their target before
  hashing.
- `comparator: :digest` carries a SHA-256 of the file contents.
  The default for source files; deterministic across machines.
- `comparator: :mtime` carries the file's mtime as an ISO-8601
  string. Cheaper to check than digesting; appropriate for large
  vendored RBS / generated artefacts where digest cost dominates.
  The producer chooses; the cache layer treats both uniformly.
- `comparator: :exists` carries `"yes"` or `"no"`. Used when a
  value depends on the existence of a file (e.g. an optional
  `sig/local.rbs`) rather than its contents.

A `FileEntry` for a project file MUST use the project-relative
path. Cache descriptors built relative to one project directory
are valid for that project's root only.

### `gems`

Each entry pins a Bundler / RubyGems dependency.

```
GemEntry := { name: String, requirement: String, locked: String? }
```

- `name` is the gem name (e.g. `"rbs"`, `"prism"`).
- `requirement` is the active version constraint as written in the
  Gemfile / gemspec (`">= 4.0"`, `"~> 0.20"`). When the producer
  cares only about the locked version, set `requirement: "*"`.
- `locked` is the resolved version from `Gemfile.lock` (`"4.0.3"`).
  When `nil`, the entry matches any version satisfying
  `requirement`.

Two `GemEntry` values are equal when their `name` matches AND
`(requirement, locked)` matches. A null `locked` matches any
locked value satisfying `requirement`; this lets producers depend
on the version range without re-invalidating on every patch bump.

### `plugins`

Each entry pins a plugin gem and the user-supplied plugin
configuration that controls the producer.

```
PluginEntry := { id: String, version: String, config_hash: String? }
```

- `id` is the plugin identifier (matches the namespace ADR-2 §
  "Plugin Diagnostic Provenance" reserves: `plugin.<plugin-id>`).
- `version` is the resolved plugin gem version. Required —
  plugin-derived facts MUST recompute when the plugin's code
  changes.
- `config_hash` is a SHA-256 of the plugin's normalised
  configuration (sorted keys, JSON-serialised values). When two
  plugin entries differ only in configuration, the cache slice
  that depends on `:strict_mode` invalidates separately from the
  slice that depends on `:include_paths`.

### `configs`

Each entry pins a single Rigor configuration key whose value
affected the producer.

```
ConfigEntry := { key: String, value_hash: String }
```

- `key` is the dotted configuration path, e.g. `"target_ruby"`,
  `"fold_platform_specific_paths"`,
  `"plugins.rails.eager_load_paths"`.
- `value_hash` is a SHA-256 of the JSON-serialised configuration
  value. Hashing keeps the descriptor's payload small even when
  the configuration value is a large hash or array.

## Composition

A cached value's descriptor is the **union** of every dependency
descriptor that contributed to producing it. Two producers
contributing the same `(slot, key)` MUST agree on the comparator
and value; conflicting contributions are a cache integrity error
and the cache layer surfaces a diagnostic rather than choosing
silently.

Composition rules per slot:

- `files`: union by `path`. If two producers attach a `FileEntry`
  for the same path with different comparators, the **stricter**
  comparator wins (digest beats mtime beats exists). If the
  values disagree under the stricter comparator, the cache slice
  is invalidated.
- `gems`: union by `name`. Conflicts on `(requirement, locked)`
  invalidate the slice.
- `plugins`: union by `id`. Conflicts on `(version, config_hash)`
  invalidate the slice.
- `configs`: union by `key`. Conflicts on `value_hash` invalidate
  the slice.

A producer MUST NOT add the same `(slot, key)` to its own
descriptor twice — duplicate detection is a producer-side bug,
not a cache-layer concern.

## Cache key derivation

The cache key for a stored value is a SHA-256 over a stable
serialisation of:

1. The schema version (a Rigor-side integer that bumps on
   breaking schema changes).
2. The producer's identifier (e.g. `"reflection.method_definition"`,
   `"plugin.rails.dynamic_attributes"`).
3. The producer's input parameters (the arguments the producer
   was called with — for a method-definition cache, the
   `(class_name, method_name, kind)` tuple).
4. The composed `Descriptor` (slots sorted, entries sorted by
   key, hashes lower-cased hex).

The serialisation MUST be canonical: sorted keys, no whitespace,
fixed encoding (UTF-8 NFC). Two equivalent descriptors built by
different code paths MUST produce identical cache keys.

## Producer responsibilities

Each cache producer (built-in or plugin) MUST:

- Construct a `Descriptor` for every value it caches, naming
  every input it read while computing the value.
- NOT cache values whose inputs include sources outside the
  declared schema. New input dimensions require a schema change
  (and an ADR amendment per ADR-2 § "Cache Invalidation Needs a
  Declarative API").
- Use the **narrowest** slice the value depends on. A reflection
  cache for `class_definition_for("Foo")` should depend on the
  source file declaring `Foo`, not on every file in the project.
- Surface its producer identifier through the cache key so
  invalidation is per-producer, not per-class.

## Invalidation policy

A cache value is **valid** when, for every entry in its
`Descriptor`, the live value of the entry's input matches the
cached value:

- `FileEntry` with `:digest`: live SHA-256 equals cached value.
- `FileEntry` with `:mtime`: live mtime equals cached value.
- `FileEntry` with `:exists`: live existence equals cached value.
- `GemEntry`: live `requirement` and live `locked` match.
- `PluginEntry`: live plugin version and config-hash match.
- `ConfigEntry`: live value-hash matches.

Any single mismatch invalidates the cache value. The cache
layer MUST drop the value and re-run the producer; it MUST NOT
attempt partial invalidation across slot entries.

## Granularity guidance

ADR-2 nominates the **narrowest practical slice** for every
producer. Concretely:

| Producer family | Per-slice key | Example dependency descriptor |
| --- | --- | --- |
| `reflection.class_definition_for(name)` | `name` | `files: [<file declaring class>]` + `gems: [<rbs gem locked>]` |
| `reflection.method_definition_for(class, method, kind)` | `(class, method, kind)` | inherits `class_definition_for(class)` deps + RBS-side method-record file |
| `inference.user_method_return(def_node)` | def-node fingerprint | `files: [<def's source file>]` + every reflection / catalog dep transitively read |
| `plugin.<id>.<provider>` | provider's own key | `files`, `gems`, `plugins: [<id, version, config_hash>]`, `configs: [<keys read>]` |
| `catalog.<class>.method_record(name)` | `(class, name)` | `files: [<data/builtins/ruby_core/<class>.yml mtime>]` |

Plugin-wide invalidation (depending on the whole plugin's
configuration) is permitted but discouraged. The preferred
grain is per dynamic-member provider, generated-signature unit,
receiver family, or flow contribution — see ADR-2's working
response to "Cache Invalidation Needs a Declarative API".

## Schema versioning

The schema version is part of the cache key. Bumping it
invalidates every cached value. Versioning rules:

- **Additive change** (new optional comparator, new slot entry
  shape that defaults to nil for older producers): no version
  bump required. Older descriptors stay readable.
- **Renaming or removing a slot or comparator**: bump the
  version. Old caches drop on first read of a value with the
  old schema marker.
- **Adding a new top-level slot** (e.g. `env_vars`, `host`):
  ADR amendment + version bump. ADR-2 explicitly notes that
  environment variables would be such a change.

## Worked example

`Rigor::Reflection.instance_method_definition("Hash", :fetch)`
produces a cached `MethodDefinition`. Its descriptor:

```
files: [
  { path: "vendor/bundle/ruby/4.0.0/gems/rbs-4.0.0/core/hash.rbs",
    comparator: :digest, value: "<sha256>" }
]
gems: [
  { name: "rbs", requirement: ">= 4", locked: "4.0.0" }
]
plugins: []
configs: []
```

Producer identifier: `"reflection.instance_method_definition"`.
Input params: `(class_name: "Hash", method_name: :fetch)`.

Cache key: SHA-256 of canonical-JSON over
`(schema_version, producer_id, params, descriptor)`.

When the user upgrades RBS to 4.1.0, the locked version changes,
the descriptor's `gems` entry no longer matches, the cache value
is dropped, and the next analysis re-resolves the method through
RBS. **Only Hash#fetch's cache slice and other slices that depend
on the `rbs` gem invalidate** — every other reflection cache
that does not name the `rbs` gem stays valid.

## Open questions

These are intentionally left for the implementation phase; the
working response is the design contract.

1. **Concurrent cache writes.** Multi-process `rigor check` runs
   could race. Working answer: file-locked sqlite with a single
   writer process, per-key writes. v0.1.0 ships with a single-
   process model; concurrency comes later.
2. **Cache size cap.** No bound today. Working answer: LRU with
   a configurable byte cap, defaulting to a generous bound (e.g.
   256 MiB) so most projects never hit it.
3. **Plugin trust + cache poisoning.** A malicious plugin could
   write descriptors that always claim valid. Working answer:
   the trusted-gem trust model from ADR-2 holds — plugins are
   selected by the user's Gemfile and are trusted Ruby code.
   Cache integrity beyond that is an in-process invariant, not
   a security boundary.
4. **Cross-Ruby compatibility.** Cache built under Ruby 4.0
   probably should not be reused under Ruby 4.1. Working
   answer: the schema version implicitly captures Rigor-side
   structural changes; Ruby version goes into the cache key as
   part of the producer identifier suffix.
5. **`Gemfile.lock` parser implementation.** Bundler-side or
   hand-rolled? Working answer: Bundler when available, fall
   back to a regex parser for the few fields the schema needs
   (gem name + locked version). The cache layer itself does
   not need Bundler runtime.

## Status of the design doc itself

This is a snapshot of the v0.0.7 working tree's cache design
intent. It will be updated when:

- The persistence layer's first implementation slice lands —
  storage backend, locking model, eviction policy.
- ADR-2's open questions on cache (concurrent writes, size
  caps, environment-variable input slot) close into normative
  rules.
- A producer family beyond reflection / inference / catalog /
  plugin needs cache-key support and exposes a new slot or
  composition rule.

After the persistence layer ships in v0.1.0, this document is
superseded by the normative spec in `docs/internal-spec/cache.md`
and stays in `docs/design/` as a historical record.
