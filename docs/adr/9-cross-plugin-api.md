# ADR-9 — Cross-plugin API

Status: **proposed, 2026-05-08.** Implementation queued for
v0.1.x; this ADR fixes the design so Tier 1 plugin authoring
can proceed without depending on its arrival.

## Context

The v0.1.0 plugin contract ([ADR-2](2-extension-api.md)) gives
every plugin its own per-file analysis hook
(`#diagnostics_for_file(path:, scope:, root:)`), its own
`IoBoundary` for file reads, and its own
`Plugin::Base.producer` namespace for caching. Plugins are
**fully independent** — one plugin cannot read another
plugin's parsed state, and the producer namespace
(`plugin.<id>.<producer>`) is intentionally sandboxed per
[ADR-7 § "Slice 6-C"](7-v0.1.0-slice-decisions.md).

This independence is the right default for v0.1.0 because
plugins were unproven. With seven worked examples landed and
the Rails ecosystem roadmap
([`docs/design/20260508-rails-plugins-roadmap.md`](../design/20260508-rails-plugins-roadmap.md))
captured, the constraint now bites concretely:

- `rigor-actionpack` Phase 1 (strong parameters) needs the
  model index that `rigor-activerecord` already builds.
  Re-reading and re-parsing `db/schema.rb` from scratch is
  wasteful, and re-implementing the model discoverer would
  drift against `rigor-activerecord`'s rules.
- `rigor-factorybot` needs the same model index for factory
  attribute validation.
- `rigor-actionpack` Phase 4 (route-helper consumption) needs
  the helper table that `rigor-rails-routes` builds.

These cross-plugin reads recur throughout the Rails ecosystem
plugins. Without a sanctioned API, plugin authors will either
duplicate work or invent ad-hoc workarounds (e.g. shared
producer ids that violate the slice 6-C sandbox).

## Decision

Add three additions to the v0.1.0 plugin contract, gated as a
v0.1.x slice:

1. **A per-run `Plugin::FactStore`** that lets plugins publish
   typed key-value tuples. Other plugins read by `(plugin_id,
   fact_name)`.
2. **A new `Plugin::Base#prepare(services)` hook** invoked
   once per `Analysis::Runner.run`, after `#init` and before
   any `#diagnostics_for_file` call. Plugins compute and
   publish facts here.
3. **A new `manifest(consumes: [...])` declaration** that
   declares the `(plugin_id, fact_name)` pairs a plugin reads
   from the fact store. The loader uses it for topological
   sort + early failure on missing producers.

### `Plugin::FactStore`

Public read-only-once value object with publish / read /
iterate operations. Lives on `Plugin::Services#fact_store`.

```ruby
module Rigor
  module Plugin
    class FactStore
      Fact = Data.define(:plugin_id, :name, :value)

      def publish(plugin_id:, name:, value:)
        # Writes to the store. Idempotent if called twice with
        # the same value (== comparison). Raises
        # Plugin::FactStore::Conflict if a different value is
        # published under the same (plugin_id, name).
      end

      def read(plugin_id:, name:)
        # Returns the published value or nil. Reads do not
        # establish a dependency — that is what `consumes:`
        # is for; reads are the data access mechanism.
      end

      def published?(plugin_id:, name:)
        # Predicate sibling for read.
      end

      def each_fact(&block)
        # Enumerate every published fact across plugins.
        # Used by the runner for diagnostic provenance.
      end
    end
  end
end
```

Lifecycle: a fresh `FactStore` instance is constructed at the
start of every `Analysis::Runner.run` and discarded at the
end. The store is NOT cached across runs — caching the
underlying expensive computation is the producer's job
(`Plugin::Base.producer`); the FactStore just publishes the
*reference* to that already-cached result.

Conflict semantics: if two plugins publish under the same
`(plugin_id, name)`, the second write either matches the first
(no-op) or differs (raises). Since `plugin_id` namespaces the
key, conflicts only happen when a single plugin publishes
twice — so the conflict signals a plugin-author bug, not a
loader-time conflict between unrelated plugins.

### `Plugin::Base#prepare(services)` hook

Default no-op. Plugins override to compute and publish facts
that other plugins consume:

```ruby
class Activerecord < Plugin::Base
  manifest(id: "activerecord", version: "0.2.0")

  producer :model_index do |_params|
    # ... existing code ...
  end

  def prepare(services)
    services.fact_store.publish(
      plugin_id: manifest.id,
      name: :model_index,
      value: model_index
    )
  end
end
```

Calling order within a single `Analysis::Runner.run`:

1. `Plugin::Loader.load` constructs every plugin instance and
   calls each plugin's `#init(services)`.
2. The loader topologically sorts plugins by their `consumes:`
   declarations (producer first; cycles are a load error).
3. **For each plugin in topological order**, the runner calls
   `#prepare(services)`. Plugins publish their facts here.
4. The runner iterates files. For each file, every plugin's
   `#diagnostics_for_file` runs (in registration order — the
   existing semantics). Hooks read from `services.fact_store`
   freely.

Plugins that have no facts to publish leave `#prepare` as the
default no-op.

Failure isolation: a `#prepare` raise isolates as a
`:plugin_loader runtime-error` diagnostic per ADR-2 § "Plugin
Trust and I/O Policy", same shape as a
`#diagnostics_for_file` raise. Plugins that fail in `#prepare`
have their facts considered un-published; downstream consumers
see `nil` from `fact_store.read` and degrade gracefully.

### `manifest(consumes:)` declaration

Optional manifest field. An array of `{ plugin_id:, name: }`
hashes naming the facts a plugin reads:

```ruby
class Actionpack < Plugin::Base
  manifest(
    id: "actionpack",
    version: "0.1.0",
    consumes: [
      { plugin_id: "activerecord", name: :model_index },
      { plugin_id: "rails-routes", name: :helper_table }
    ]
  )
end
```

`Plugin::Manifest::Consumption` value object: frozen
`Data.define(:plugin_id, :name)`. The manifest validates the
shape at class-definition time; malformed declarations raise
`ArgumentError` with a message naming the offending entry.

The loader uses `consumes` for two things:

1. **Topological sort** — a depth-first walk over the
   `consumes` graph orders plugin `#prepare` invocations so
   producers fire before consumers. Cycles raise
   `Plugin::LoadError(:dependency-cycle)`. Determinism
   tie-break: `plugin_id` alphabetical when no dependency
   relation exists.
2. **Early validation** — at the end of `Plugin::Loader.load`,
   the loader checks that every consumed `(plugin_id, name)`
   has a plugin in the registry whose manifest declares the
   matching production. This is enforced via a manifest field
   on the producer side: `manifest(produces: [:model_index])`.
   Missing producer surfaces as a `:plugin_loader load-error`
   diagnostic before any analysis runs.

Optional `consumes:` entry semantics: an entry tagged
`optional: true` skips the early-validation check. The
consumer's `fact_store.read` returns `nil` and the consumer
must degrade gracefully:

```ruby
manifest(
  consumes: [
    { plugin_id: "activerecord", name: :model_index, optional: true }
  ]
)

def diagnostics_for_file(path:, scope:, root:)
  ar_index = services.fact_store.read(plugin_id: "activerecord", name: :model_index)
  return [] if ar_index.nil?  # graceful degrade — no AR loaded
  # ...
end
```

Use `optional: true` for plugins whose ergonomics improve when
a sibling is loaded but who must function alone. `rigor-factorybot`
is the canonical example — works without `rigor-activerecord`,
benefits from it.

## Public-API drift surface

This ADR adds:

- `Rigor::Plugin::FactStore` (new namespace) — `publish`,
  `read`, `published?`, `each_fact`, `Fact` (frozen Data),
  `Conflict` (exception class).
- `Rigor::Plugin::Services#fact_store` (new accessor).
- `Rigor::Plugin::Base#prepare(services)` (new hook, default no-op).
- `Rigor::Plugin::Manifest#consumes` (new attr_reader; default `[]`).
- `Rigor::Plugin::Manifest#produces` (new attr_reader; default `[]`).
- `Rigor::Plugin::Manifest::Consumption` (new frozen Data).
- `Rigor::Plugin::LoadError` gains `:dependency-cycle` and
  `:missing-producer` reason codes.

All updates land in `spec/rigor/public_api_drift_spec.rb` in
the same commit as the implementation.

## Implementation slicing

Recommended order; each slice independently shippable:

1. **`Plugin::FactStore` value object + spec.** Pure value
   object; no plugin loader changes yet. Drift snapshot
   landed.
2. **`Plugin::Services#fact_store` accessor.** A FactStore
   instance is constructed per Services. Plugins can publish
   and read; nothing else changes.
3. **`Plugin::Base#prepare(services)` default hook + Runner
   invocation.** Runner calls `#prepare` on every plugin
   before per-file iteration. Order: registration order (no
   topological sort yet — that's slice 5).
4. **`manifest(produces:)` + `manifest(consumes:)`
   declarations + validation.** Manifest carries the
   declarations but the loader does not yet enforce them.
5. **Topological sort + missing-producer / cycle detection in
   `Plugin::Loader`.** This is the slice that makes
   `consumes:` binding.
6. **Documentation update** —
   `docs/internal-spec/plugin-cross-plugin.md` (new file)
   + the `rigor-plugin-author` SKILL gains a "Phase 4.7 —
   cross-plugin facts" section.

`rigor-actionpack` Phase 1 lands AFTER slice 5 ships. Tier 1
plugins (rigor-rails-routes, rigor-rails-i18n,
rigor-actionmailer, rigor-activejob) DON'T need any of these
slices and can land in parallel.

## Working decisions

### WD1 — Why not a method-call passthrough?

An alternative design would let plugins query each other's
public methods directly:

```ruby
ar_plugin = services.plugin_registry.find("activerecord")
ar_plugin.model_index  # call public method
```

This was rejected because:

- It couples plugins to each other's class-level API; a method
  rename in `rigor-activerecord` breaks every consumer.
- Plugin instances are private to the runner; exposing them
  would leak unrelated state (`@io_boundary`, `@config`).
- The "fact" abstraction is closer to what consumers actually
  want — a value object the producer chose to publish, not the
  plugin's internal state.

The FactStore design prevents accidental coupling: the only
contract is the published value's shape, which can be pinned
by a typed Data class living in `lib/rigor-<id>-facts.rb` (a
shared shape gem) if cross-version compatibility becomes a
concern.

### WD2 — Why not RBS for fact shapes?

RBS could declare the fact value's type contract. Considered
and deferred — the shape contract is best owned by the
producing plugin's own code (e.g.
`Rigor::Plugin::Activerecord::ModelIndex`), and consumers
import the producing gem to access its types. RBS adds rigor
but requires every plugin to ship `.rbs` for its public types,
which is currently not the convention. Revisit when one of the
plugin gems hits a v1.0.0 stability commitment.

### WD3 — Cache descriptor composition

When a consumer plugin uses a fact in its own cache producer
key, the descriptor needs to include the producer's
identity + version so a producer upgrade invalidates the
consumer's cache:

```ruby
producer :strong_params_validation do |params|
  ar_plugin = services.fact_store.read(...)  # current run only
  cache_for(:strong_params_validation,
            params: params,
            descriptor: Cache::Descriptor.new(
              plugins: [Cache::Descriptor::PluginEntry.new(
                id: "activerecord",
                version: ar_plugin_version,  # how to get this?
                config_hash: ""
              )]
            )).call
end
```

Open question: how does the consumer learn the producer's
version? Options:

A. The producer publishes its version as part of the fact
   payload: `{ plugin_id:, name:, value:, producer_version: }`.
B. `services.fact_store.read` returns a wrapper carrying
   producer metadata: `Fact(value:, producer_version:)`.
C. The consumer reads the producer's manifest:
   `services.plugin_registry.find("activerecord").manifest.version`.

Option B is cleanest — implementation defers the wrapper
shape until the first concrete need (likely `rigor-actionpack`
Phase 1).

## Alternatives considered

- **Shared producer ids** (a consumer registers
  `producer :"plugin.activerecord.model_index"`). Rejected: violates
  ADR-7 § "Slice 6-C" sandbox; cache attribution becomes
  ambiguous.
- **Plugin-to-plugin require / direct constant lookup**. Rejected:
  forces gem dependencies between plugin gems. The whole point of
  the FactStore is to keep gems independently extractable.
- **Capability-based message passing**. Considered. Heavier than
  needed for the current use cases.

## Revision history

- 2026-05-08 — initial proposal. Triggered by the Rails
  ecosystem roadmap landing.
