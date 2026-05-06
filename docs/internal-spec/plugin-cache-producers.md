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

### `Rigor::Plugin::Base.producer(id, serialize: nil, deserialize: nil, &block)`

Class-level DSL that registers a producer. The block is the
producer body; it runs through `instance_exec` so `self`
inside the block is the plugin instance — `io_boundary`,
`services`, `manifest`, `config` are all in scope. The block
receives the call-site `params` Hash as its sole argument;
`params` mixes into the cache key per
`Cache::Descriptor#cache_key_for` (v0.0.8).

`serialize:` / `deserialize:` are forwarded verbatim to
`Cache::Store#fetch_or_compute`. Default round-trip is
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
boundary's accumulated `FileEntry` rows feed cache invalidation
for `cache_for` round-trips: file reads through `io_boundary`
that happen **before** `cache_for` is called include the file
digest in the descriptor. See "Invalidation contract" below.

### `Rigor::Plugin::Base#cache_for(producer_id, params: {}, descriptor: nil)`

Returns a callable that performs the cache round-trip for the
named producer. The callable, when called, returns the cached
value (on hit) or runs the producer block (on miss) and writes
the result.

When `services.cache_store` is `nil` (e.g. CLI `--no-cache`),
the callable bypasses the cache and runs the producer block
every time — same semantics as the v0.0.9 cache surface for
built-in producers.

Producer ids are auto-prefixed `plugin.<manifest.id>.`; the
cache-store layout for a producer registered as `:schema_table`
on a plugin with `manifest.id = "rails"` lives at
`<root>/plugin.rails.schema_table/<2-prefix>/<62-suffix>.entry`.

The optional `descriptor:` kwarg supplies extra
`Cache::Descriptor` rows the plugin author wants to compose
into the auto-built descriptor — typically gem-version
`GemEntry`, configuration-file `FileEntry` digests, or
`ConfigEntry` rows for external state the {IoBoundary} cannot
capture itself. The passed descriptor flows through
`Cache::Descriptor.compose` with the auto-built one
(`PluginEntry` template + boundary reads); per-slot conflicts
raise `Cache::Descriptor::Conflict` so divergent inputs
surface rather than silently shadowing.

## Cache descriptor composition (6-B)

`Plugin::Base#cache_for` auto-assembles the descriptor from:

- The plugin's **`PluginEntry` template**: `(id, version,
  config_hash)`. `config_hash` is the SHA-256 of the
  canonicalised plugin config (sorted keys, recursive Symbol
  → String) so two instances of the same plugin with
  different `config:` values land in different cache slices.
- The plugin's **`IoBoundary#cache_descriptor`**: every
  `:digest` `FileEntry` the boundary recorded by the time
  `cache_for` is called.
- The user's **`params:`** hash (mixed into the cache key
  through `Descriptor#cache_key_for`).

Plugin authors do not construct descriptors manually. Custom
descriptor extensions (extra `FileEntry` / `GemEntry` /
`ConfigEntry` rows beyond the boundary's reads) ride a future
API; slice 6 ships only the auto-built path.

## Invalidation contract

The IoBoundary integration only reflects reads that happen
**before** `cache_for` is called. The recommended pattern is:

```ruby
class MyRailsPlugin < Rigor::Plugin::Base
  manifest(id: "rails", version: "0.1.0")

  producer :schema_table do |params|
    schema = io_boundary.read_file(params.fetch(:schema_path))
    parse_schema(schema, params.fetch(:table))
  end

  def schema_for(table)
    schema_path = "db/schema.rb"
    io_boundary.read_file(schema_path)             # populate boundary BEFORE cache_for
    cache_for(:schema_table, params: { schema_path: schema_path, table: table }).call
  end
end
```

The pre-`cache_for` `read_file` records a `:digest` `FileEntry`
that lands in the descriptor; if the file changes between
runs, the digest changes, the cache key changes, and
`cache_for` falls through to the producer. The producer body
re-reads the file at the same path; on a cache miss the
boundary is re-populated and the post-fact digest is written
into the new entry.

Plugin authors who want richer invalidation (gem versions,
external configuration files, sibling plugin state) compose
those into the params hash today; a future extension may add
explicit descriptor parameters to `cache_for`.

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
