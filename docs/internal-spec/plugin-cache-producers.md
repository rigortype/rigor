# Plugin-side Cache Producers (slice 6)

Status: **v0.1.0 slice 6 normative.** Pins the plugin-author
surface for declaring cached producers — the
`Plugin::Base.producer` DSL, `Plugin::Base#cache_for` callable,
automatic `PluginEntry` attachment, and the
`plugin.<manifest.id>.` cache-id sandbox. Working decisions
behind these surfaces are recorded in
[ADR-7 § "Slice 6"](../adr/7-v0.1.0-slice-decisions.md); when
this document disagrees with the ADR, the ADR binds.

## Why this exists

Rigor's persistent cache (ADR-6, v0.0.8 / v0.0.9) is a single
sharded directory of binary entries keyed by
`(producer_id, params, descriptor)`. Slice 6 extends the
producer side of that contract to plugin authors so that
plugin contributions whose computation is expensive
(parsing schemas, building dynamic-member tables, indexing
generated metadata) cache across `rigor check` runs and
invalidate correctly when their inputs change.

ADR-7 § "Slice 6" pins three implementation choices:

- **6-A.** A DSL declaration (`Plugin::Base.producer`) plus an
  imperative helper (`Plugin::Base#cache_for`) hybrid. The
  declaration carries the id and serialiser pair; the helper
  performs the round-trip so plugin authors do not have to
  construct a `Cache::Descriptor` by hand.
- **6-B.** The loader / Services helper auto-attaches a
  per-plugin `PluginEntry` template (id, version,
  config_hash) to every `cache_for` round-trip. Plugin id +
  version + config invariants are enforced by construction.
- **6-C.** Plugin-declared producer ids are auto-prefixed
  `plugin.<manifest.id>.` so plugin caches stay sandboxed
  from built-in producers (`rbs.*` etc.) and from each
  other.

## Public surface (drift-pinned)

### `Rigor::Plugin::Base.producer(id, watch: nil, serialize: nil, deserialize: nil, &block)`

Class-level DSL that registers a producer. The block is the
producer body; it runs through `instance_exec` so `self`
inside the block is the plugin instance — `io_boundary`,
`services`, `manifest`, `config` are all in scope. The block
receives the call-site `params` Hash as its sole argument;
`params` mixes into the cache key per
`Cache::Descriptor#cache_key_for` (v0.0.8).

`watch:` (ADR-60 WD3) declares the glob coverage of a
discovery-style producer — the directories whose file
*additions* / *removals* must invalidate the cached value even
when the producer block read its inputs by globbing (so an
in-block read can't see a file that wasn't there). It is either
a static `Array` of `[roots, pattern, …]` tuples (`roots` a
`String` or `Array<String>`; one or more glob-pattern suffixes
per tuple), or a `Proc` run through `instance_exec` on the
plugin instance at `cache_for` time (NOT at class-definition
time — search roots are typically computed in `#init` from
config) returning that Array. Each evaluated `(root, pattern)`
becomes a `Cache::Descriptor::GlobEntry` row in the producer's
dependency descriptor — one entry digests the whole glob, so a
content change, an addition, or a removal all invalidate.

`serialize:` / `deserialize:` apply to the producer's return
**value** (the cache layer wraps them around the stored
`[value, dependency_descriptor]` pair). Default round-trip is
`Marshal.dump` / `Marshal.load` per the v0.0.9 callable
surface; producers whose return values are not Marshal-clean
(RBS-native objects with `RBS::Location` members, raw `IO`,
…) MUST supply their own pair.

`Plugin::Base.producers` returns a frozen `{ id => entry }`
snapshot. Inherited producers from a superclass are NOT
surfaced — the loader instantiates one subclass per
registration and producer tables stay flat.

### `Rigor::Plugin::Base#io_boundary`

Memoised per-plugin `Rigor::Plugin::IoBoundary` (slice 2). The
boundary's accumulated entries feed cache invalidation for
`cache_for` round-trips: under ADR-60 WD3 record-and-validate the
boundary snapshot is taken **after** the producer block runs, so
every read the block performs (including reads it discovers
mid-computation) is captured — there is no "read before
`cache_for`" ordering requirement. `#read_file(path)` records a
`:digest` `FileEntry`; `#open_url(url)` records a `ConfigEntry`
keyed `"url:#{url}"` whose `value_hash` is the response body's
SHA-256. A `ConfigEntry` (URL read) in the dependency descriptor
makes the entry never-fresh — a producer that fetched a URL
recomputes every run, which is sound (a remote document has no
cheap local re-validation). See "Invalidation contract" below.

`Plugin::Base#glob_descriptor(roots, *patterns)` became **private**
in ADR-60 WD3 (it is the building block `watch:` is implemented on);
plugin code declares `watch:` instead of composing descriptors by
hand.

### `Rigor::Plugin::Base#cache_for(producer_id, params: {}, descriptor: nil)`

Returns a callable that performs the cache round-trip for the
named producer through `Cache::Store#fetch_or_validate` (the
ADR-45 record-and-validate path). The callable, when called,
returns the cached value when the recorded dependencies are
still fresh, or runs the producer block and records a fresh
entry otherwise.

When `services.cache_store` is `nil` (e.g. CLI `--no-cache`),
the callable bypasses the cache and runs the producer block
every time — same semantics as the v0.0.9 cache surface for
built-in producers.

Producer ids are auto-prefixed `plugin.<manifest.id>.`; the
cache-store layout for a producer registered as `:schema_table`
on a plugin with `manifest.id = "rails"` lives at
`<root>/plugin.rails.schema_table/<2-prefix>/<62-suffix>.entry`.

The optional `descriptor:` kwarg supplies extra
`Cache::Descriptor` rows for **identity** inputs that belong in
the cache *key* — typically gem-version `GemEntry` pins or
`ConfigEntry` rows for external state the `IoBoundary` cannot
capture itself. The passed descriptor flows through
`Cache::Descriptor.compose` with the auto-built `PluginEntry`
template; per-slot conflicts raise `Cache::Descriptor::Conflict`
so divergent inputs surface rather than silently shadowing. The
`IoBoundary` read history does NOT enter the key — it is recorded
post-compute into the dependency descriptor.

## Cache descriptor composition (6-B)

`Plugin::Base#cache_for` keys the entry on the stable identity
inputs and records the read dependencies separately:

- **Key descriptor** — the plugin's **`PluginEntry` template**
  `(id, version, config_hash)` (where `config_hash` is the
  SHA-256 of the canonicalised plugin config — sorted keys,
  recursive Symbol → String — so two instances with different
  `config:` land in different slices), composed with the
  optional `descriptor:` identity extras, plus the user's
  **`params:`** hash (mixed through `Descriptor#cache_key_for`).
- **Dependency descriptor** (recorded after the block runs, then
  re-validated by re-digest on the next run via
  `Descriptor#fresh?`) — the `IoBoundary`'s post-compute
  `FileEntry` / `ConfigEntry` reads plus the evaluated `watch:`
  `GlobEntry` rows.

Plugin authors do not construct descriptors manually: in-block
reads are captured automatically, and `watch:` declares glob
coverage.

## Invalidation contract

Under ADR-60 WD3 the dependency descriptor is recorded **after**
the producer block runs, so a producer reads its inputs inside
the block and `watch:` covers a directory glob's additions /
removals:

```ruby
class MyRailsPlugin < Rigor::Plugin::Base
  manifest(id: "rails", version: "0.1.0")

  # Single named file: the in-block read is captured; no watch: needed.
  producer :schema_table do |params|
    schema = io_boundary.read_file(params.fetch(:schema_path))
    parse_schema(schema, params.fetch(:table))
  end

  # Directory glob: watch: covers additions/removals. The Proc is
  # instance_exec'd at cache_for time, so #init-derived roots are in scope.
  producer :model_index, watch: -> { [[@model_search_paths, "**/*.rb"]] } do |_params|
    ModelDiscoverer.new(io_boundary: io_boundary, search_paths: @model_search_paths).discover
  end

  def schema_for(table)
    producer_value(:schema_table, params: { schema_path: "db/schema.rb", table: table })
  end
end
```

The producer's in-block `read_file` records a `:digest`
`FileEntry` into the dependency descriptor; if the file changes
between runs, the recorded digest no longer matches, the entry
is not fresh, and `cache_for` recomputes. A `watch:` glob digests
every matching file, so adding or removing a file under the glob
also invalidates. `producer_value(id, params:)` (ADR-60 WD4)
runs the round-trip with a nil-inclusive memo and a
`StandardError` rescue (`producer_error(id)` surfaces the failure);
a plugin that needs distinct per-failure messages keeps a bespoke
`rescue` ladder around `cache_for(id).call`.

Identity inputs (gem versions, sibling-plugin config, external
state the boundary can't read) compose into the **key** via the
`descriptor:` kwarg; a key change is a cache miss.

## Cache-id sandbox (6-C)

`Plugin::Base#cache_for` rewrites the producer id to
`plugin.<manifest.id>.<id>` so plugin authors cannot collide
with built-in producers (which use unprefixed `rbs.*` ids
today) or with each other (every plugin's ids live under their
own manifest id namespace). The prefix lives within the
existing `Cache::Store::VALID_PRODUCER_ID = /\A[a-z][a-z0-9._-]*\z/`
regex; on-disk attribution is unambiguous through
`rigor check --cache-stats`.

## What slice 6 deliberately does NOT do

- **Re-attempt the v0.0.9 per-method `Reflection` cache
  carry-over.** Per ADR-7 § "Slice 6-D", that work is
  descoped and lands in a separate v0.1.x ticket so the
  engine-internal regression investigation does not entangle
  with the new public plugin API.
- **Cross-machine cache sharing.** Per ADR-6 the cache is
  single-machine; plugin-side producers inherit that
  constraint.
- **LRU eviction / size cap.** Plugin caches share the
  unbounded layout described in ADR-6; users run
  `--clear-cache` if needed.
