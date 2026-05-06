# Plugin Registration / Loading (slice 1)

Status: **v0.1.0 slice 1 normative.** Pins the public surface plugin
authors interact with for *registering* a plugin, declaring its
*manifest*, and being *loaded* by `Analysis::Runner`. The
contribution protocols (dynamic-return, type-specifying, dynamic
reflection) attach in subsequent v0.1.0 slices and are not defined
here.

The binding design surface is [ADR-2](../adr/2-extension-api.md);
the v0.1.0 readiness map is at
[`docs/design/20260505-v0.1.0-readiness.md`](../design/20260505-v0.1.0-readiness.md).
When this spec disagrees with ADR-2, the ADR binds.

## Public namespaces (drift-pinned)

Every namespace below is locked by
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb).
Signature changes update the matching `PublicApiDriftSnapshots::*`
constant in the same commit.

### `Rigor::Plugin`

Module-level entry for plugin registration.

| Method | Purpose |
| --- | --- |
| `Rigor::Plugin.register(plugin_class)` | Plugin gem calls this at load time to advertise its `Rigor::Plugin::Base` subclass. |
| `Rigor::Plugin.registered_for(id)` | Loader-side lookup by manifest id. |
| `Rigor::Plugin.registered` | Frozen `{ id => class }` snapshot. |
| `Rigor::Plugin.unregister!(id = nil)` | Test-only reset. The plugin contract does not require gem authors to call this. |

The registry is process-global and mutex-guarded. Registering the
same class twice is a no-op; registering a different class under
the same id raises `Rigor::Plugin::LoadError` so two plugins
cannot silently shadow each other.

### `Rigor::Plugin::Base`

Base class every plugin subclasses.

```ruby
class MyPlugin < Rigor::Plugin::Base
  manifest(
    id: "my-plugin",
    version: "0.1.0",
    description: "...",
    protocols: [],
    config_schema: { "flag" => :boolean }
  )

  def init(services)
    @reflection = services.reflection
  end
end
```

Class-level `manifest(**fields)` declares the manifest once at
class definition time; the same method without arguments returns
the cached `Manifest`. Instance-level `manifest` delegates to the
class.

`#initialize(services:, config: {})` stores the injected services
and a frozen copy of the user's config. `#init(services)` is the
override hook plugins use to wire up state from the service
container; the default implementation is a no-op.

`#diagnostics_for_file(path:, scope:, root:)` (slice 5) is the
per-file diagnostic emission hook. The default returns an empty
array. Plugin authors override it to walk `root` (the parsed
`Prism::Node`) and return an array of
`Rigor::Analysis::Diagnostic` rows; the runner re-stamps every
returned diagnostic with `source_family: "plugin.<manifest.id>"`
per ADR-7 § "Slice 5-B" so plugin authors cannot accidentally
publish under another plugin's id. Plugin exceptions inside the
hook isolate as a `:plugin_loader` `runtime-error` diagnostic
rather than crashing `rigor check`.

### `Rigor::Plugin::Manifest`

Frozen value object describing one plugin's identity. Fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `id` | `String` matching `/\A[a-z][a-z0-9._-]*\z/` | Stable identifier; used as the `PluginEntry#id` and the `plugin.<id>.<rule>` diagnostic prefix. |
| `version` | non-empty `String` | Plugin version; lands in `PluginEntry#version` for cache invalidation. |
| `description` | `String?` | Human-readable summary. |
| `protocols` | `Array<Symbol>` | Protocol names this plugin implements. Slice 1 leaves this empty; protocol slices populate it. |
| `config_schema` | `{ String => Symbol }` | Accepted config keys mapped to value kinds (`:string`, `:boolean`, `:integer`, `:array`, `:hash`, `:any`). |

`#validate_config(config)` returns an array of error strings; the
loader converts a non-empty result into a `LoadError`.

### `Rigor::Plugin::Services`

Frozen DI container handed to every plugin's `#initialize` and
`#init`. Slice-1 surface:

| Service | Type |
| --- | --- |
| `reflection` | `Rigor::Reflection` (module). |
| `type` | `Rigor::Type::Combinator` (module). |
| `configuration` | `Rigor::Configuration` (read-only project config). |
| `cache_store` | `Rigor::Cache::Store` or `nil` (slice 6 wires plugin-side cache producers through this). |

A logger service will join this list when the diagnostics
formatter grows a progress channel.

### `Rigor::Plugin::Registry`

Read-only snapshot of plugins loaded for a single
`Analysis::Runner.run`. Returned by `Rigor::Plugin::Loader.load`
and exposed as `Analysis::Runner#plugin_registry`.

| Method | Returns |
| --- | --- |
| `#plugins` | Loaded `Rigor::Plugin::Base` instances in deterministic order. |
| `#ids` | `Array<String>` of manifest ids, parallel to `#plugins`. |
| `#find(id)` | Lookup by id; `nil` when absent. |
| `#load_errors` | `Array<Rigor::Plugin::LoadError>` collected during loading. |
| `#empty?` / `#any_load_errors?` | Predicates. |

`Registry::EMPTY` is the singleton frozen empty registry the
runner uses before plugins load.

### `Rigor::Plugin::LoadError`

Public exception raised inside the loader when a plugin entry
cannot be resolved. Carries `plugin_ref` (the offending gem name
or plugin id) and `cause_class` (the underlying exception class,
when applicable). The runner converts each one into a
`Rigor::Analysis::Diagnostic` with `source_family: :plugin_loader`
and `rule: "load-error"`.

## Internal surfaces (NOT public)

- `Rigor::Plugin::Loader` — the loader is internal infrastructure.
  Plugin authors should not subclass or depend on its private
  helpers; the public entry point is `Loader.load(configuration:,
  services:, requirer:)`.

## `.rigor.yml` plugin entries

The configuration's `plugins:` field accepts both shorthand and
explicit forms:

```yaml
plugins:
  - rigor-rails                         # bare gem name
  - gem: rigor-rspec
    id: rspec                           # only required when the gem registers > 1 plugin
    config:
      include_specs: true
```

`Configuration` normalises every entry to one of those two shapes
and exposes them via `Configuration#plugins`.

## Load order

The loader processes `.rigor.yml` `plugins:` entries in the order
the user wrote them. For an entry that resolves to multiple
registered plugin classes (one gem registering > 1 plugin), the
explicit `id:` field disambiguates; without it the loader emits a
`LoadError` rather than guessing. Duplicate ids across entries are
an error, not a silent dedupe.

## Failure isolation (per ADR-2 § "Plugin Trust and I/O Policy")

Loading runs every plugin entry independently; a failure on one
entry does not abort the others. Each failure is collected as a
`LoadError` on the resulting registry, then surfaced by
`Analysis::Runner#run` as an `:error` `Diagnostic` with:

- `path`: `".rigor.yml"`
- `line`: `1`
- `column`: `1`
- `source_family`: `:plugin_loader`
- `rule`: `"load-error"`
- `message`: the `LoadError`'s message (gem path / registration /
  config-schema / `#init` exception, depending on the failure
  kind).

`rigor check` continues with the analysis; plugins that loaded
successfully still participate in later v0.1.0 slices.

## Slice-1 boundaries (intentionally NOT covered)

- **Plugin contribution emission** (`FlowContribution` bundles,
  capability roles, dynamic returns). Slice 3 has shipped the
  standalone {Rigor::FlowContribution::Merger}
  ([`flow-contribution-merger.md`](flow-contribution-merger.md));
  protocols on `Rigor::Plugin::Base` that produce bundles arrive
  alongside slice 4 (FlowContribution wiring through internal
  narrowing).
- **Plugin diagnostic provenance** beyond the `:plugin_loader`
  family for load failures. Slice 5 routes plugin-emitted
  diagnostics through `Diagnostic#source_family` with
  `plugin.<id>.<rule>` prefixes.
- **Plugin trust / I/O policy enforcement.** Slice 2 ships the
  declarative {Rigor::Plugin::TrustPolicy} + {Rigor::Plugin::IoBoundary}
  surface plugins are expected to use; see [`plugin-trust.md`](plugin-trust.md).
- **Plugin-side cache producers.** Slice 6 wires
  `Store#fetch_or_compute` for plugins via `PluginEntry`
  descriptors.
- **Per-method Reflection caches.** Carry-over from v0.0.9; lands
  alongside slice 6.
