# Plugin Trust and I/O Policy (slice 2)

Status: **v0.1.0 slice 2 normative.** Pins the trust model and the
analyzer-side I/O surface plugins are expected to flow through. The
binding design surface is [ADR-2 § "Plugin Trust and I/O Policy"](../adr/2-extension-api.md);
when this document disagrees with the ADR, the ADR binds.

## Why this exists

ADR-2 fixes the slice-2 contract around three points:

1. Plugins are *trusted Ruby gems* selected by the user, their
   Gemfile, or `.rigor.yml`. Slice 1's loader already enforces this
   trust boundary by requiring plugin gems to be listed in
   configuration; slice 2 adds the **declarative** policy plugins
   are expected to operate under.
2. **Network access is disabled by default** during analysis for
   determinism.
3. **File reads are scoped** to the project, the project's RBS
   signatures, the active Gemfile.lock, and each trusted gem's
   `Gem::Specification#full_gem_path`. Reads outside that scope
   require explicit configuration and a cache-dependency
   descriptor.

ADR-2 explicitly chooses **documentation over forced isolation**:
plugins that bypass the boundary with raw `File.read` or
`Net::HTTP` are out of scope for slice 2. The contract is that
when a plugin uses the analyzer-side {Rigor::Plugin::IoBoundary},
its reads are validated, its network calls are denied, and its
inputs feed cache invalidation through the
{Rigor::Cache::Descriptor} pipeline.

## Public namespaces (drift-pinned)

Both classes below are pinned by
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb).

### `Rigor::Plugin::TrustPolicy`

Frozen value object describing the per-run trust scope.

| Field | Purpose |
| --- | --- |
| `trusted_gems` | Sorted, deduplicated list of gem names the user has authorised. Derived from the gem-name half of every `.rigor.yml` `plugins:` entry. |
| `allowed_read_roots` | Sorted absolute paths plugins may read from through the {IoBoundary}. Default contents: project root (CWD), every `signature_paths` entry, each trusted gem's `Gem::Specification#full_gem_path`, and any extra paths the user lists under `plugins_io.allowed_paths`. |
| `network_policy` | `:disabled` in slice 2 — the only value `Configuration` accepts today. |

Predicates: `#allow_read?(path)` (absolute-path containment under
any allowed root), `#network_allowed?` (always `false` while the
policy is `:disabled`), `#gem_trusted?(name)`. `#to_h` returns a
serialisable Hash for diagnostics and cache descriptors.

### `Rigor::Plugin::IoBoundary`

Per-plugin helper service constructed by
{Rigor::Plugin::Services#io_boundary_for}. Holds a frozen
`TrustPolicy` and a per-instance accumulator of read entries.

| Method | Purpose |
| --- | --- |
| `#read_file(path)` | Validates the absolute path against the policy, reads the bytes, and adds a `:digest` {Cache::Descriptor::FileEntry} to the boundary's accumulated entries. Raises {Rigor::Plugin::AccessDeniedError} (`reason: :read_outside_scope`) on a denied path. |
| `#open_url(url)` | Always raises {Rigor::Plugin::AccessDeniedError} (`reason: :network_disabled`) while the policy is `:disabled` (slice 2's only setting). The hook is reserved so future slices can lift the gate without re-defining the API. |
| `#cache_descriptor` | Returns a fresh frozen {Cache::Descriptor} with the boundary's accumulated `FileEntry` rows. Subsequent reads expand the underlying record table; each call returns a new descriptor reflecting the read history at that moment. |

Per-path reads are deduplicated by absolute path; re-reading a
file with changed content updates the entry's digest in place.

### `Rigor::Plugin::AccessDeniedError`

Public exception for boundary violations. Slice-2 reasons:

- `:read_outside_scope` — `read_file` called with a path outside
  every allowed read root.
- `:network_disabled` — `open_url` called while
  `network_policy == :disabled`.

Carries the offending `resource` (path or URL).

### `Rigor::Plugin::Services` (slice-2 additions)

Slice 2 adds two surfaces:

| Method | Purpose |
| --- | --- |
| `#trust_policy` | The {TrustPolicy} for the run. Constructed by `Analysis::Runner` from the project's `.rigor.yml`. |
| `#io_boundary_for(plugin_id)` | Returns a fresh per-plugin {IoBoundary}. The contribution merger (slice 3) constructs one per plugin per run and feeds the resulting cache descriptor through the same pipeline as built-in producers. |

## `.rigor.yml` `plugins_io` section

```yaml
plugins_io:
  network: disabled              # only :disabled accepted in slice 2
  allowed_paths:                 # extra read roots beyond project + sig + trusted gems
    - vendor/generated
    - db/schema.rb
```

`Configuration#plugins_io_network` returns the parsed Symbol;
`Configuration#plugins_io_allowed_paths` returns a frozen
`Array<String>` of the user-supplied extras (relative paths are
expanded to absolute by the runner when building the policy).

## Analyzer wiring (`Analysis::Runner`)

Slice 2's runner builds a `TrustPolicy` once per run:

1. `trusted_gems` ← gem-name half of every `Configuration#plugins`
   entry.
2. `allowed_read_roots`:
   - `Dir.pwd` (project root).
   - Every `Configuration#signature_paths` entry, expanded.
   - For each trusted gem: `Gem.loaded_specs[gem_name]&.full_gem_path`,
     when the gem is loadable (failures are silent — the gem may
     be project-local with no installed spec).
   - Every `Configuration#plugins_io_allowed_paths` entry,
     expanded.
3. `network_policy` ← `Configuration#plugins_io_network`
   (`:disabled` in slice 2).

The policy lands on `Plugin::Services` and from there on every
plugin's `Services#io_boundary_for` call. Plugins that do not use
the boundary still receive the policy through `services.trust_policy`
for documentation.

## What slice 2 deliberately does NOT do

- **Force isolation.** ADR-2 explicitly accepts the trade-off:
  plugins that bypass the boundary are out of scope; slice 2's job
  is to provide the declarative policy + the documented edges.
  Stronger isolation (Ruby::Box, process boundary) is a future
  option, not a slice-2 commitment.
- **Resolve symlinks via `realpath`.** `File.expand_path` is the
  only normalisation step. Adversarial plugins are out of scope.
- **Enable any network policy other than `:disabled`.** The
  `network_allowed?` hook exists so slices that need offline-replay
  / cached-fetch behaviour can lift the gate without re-defining
  the API; slice 2's accepted set is `[:disabled]`.
- **Wire the boundary's cache descriptor into `Cache::Store`.**
  That's slice 6's job — plugin-side cache producers ride
  `Store#fetch_or_compute(serialize:, deserialize:)` with
  `PluginEntry` rows in the descriptor schema. Slice 2 only
  builds the descriptor; nothing consumes it yet.
