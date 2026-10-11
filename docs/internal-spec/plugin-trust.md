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
| `network_policy` | `:disabled` (default) or `:allowlist` (v0.1.2). The two values `Configuration` accepts. |
| `allowed_url_hosts` | Sorted, deduplicated, lower-cased list of hostnames plugins may fetch from when `network_policy` is `:allowlist`. Empty (and ignored) under `:disabled`. |

Predicates: `#allow_read?(path)` (absolute-path containment under
any allowed root), `#network_allowed?` (`true` only when the policy
is `:allowlist`), `#allow_url?(url)` (HTTPS + parsed host in
`allowed_url_hosts`), `#gem_trusted?(name)`. `#to_h` returns a
serialisable Hash for diagnostics and cache descriptors.

### `Rigor::Plugin::IoBoundary`

Per-plugin helper service constructed by
{Rigor::Plugin::Services#io_boundary_for}. Holds a frozen
`TrustPolicy` and a per-instance accumulator of read entries.

| Method | Purpose |
| --- | --- |
| `#read_file(path)` | Validates the absolute path against the policy, reads the bytes, and adds a `:stat` (ADR-87 WD1) {Cache::Descriptor::FileEntry} to the boundary's accumulated entries. Raises {Rigor::Plugin::AccessDeniedError} (`reason: :read_outside_scope`) on a denied path. When the read fails because the path does not exist (`Errno::ENOENT`, or `Errno::ENOTDIR` for a parent component that is a regular file) it records an **absence row** (`FileEntry.absent`, ADR-45 WD1 / #577) and re-raises, so every cache built on the boundary's descriptor invalidates once the path appears; any other read failure (`EISDIR`, a permission error) records nothing and propagates. |
| `#file?(path)` / `#directory?(path)` | The **existence probe** (ADR-45 WD1b / #613). Returns exactly what `File.file?` / `File.directory?` returns — for every path, in scope or out, and never raising — and records the answer as an `:exists` {Cache::Descriptor::FileEntry}: `FileEntry.present` when the probe found what it asked for, `FileEntry.absent` when nothing exists at the path, and **nothing** when something exists there but is not what was asked for (a directory where a file was wanted, the same bound `#read_file` pins for `EISDIR`). Recording — not the answer — is what the policy gates: an out-of-scope path contributes no row, exactly as an out-of-scope read contributes none. Plugin code MUST prefer these over `File.file?` / `File.directory?` on a project path: a bare `File` probe records nothing, so a result shaped by the miss is served again after the file appears. |
| `#list_directory(path)` | The **directory-listing fingerprint** (ADR-45 WD1c / #629). Returns the absolute paths directly under `path` (`[]` when it is not a directory), for every path in scope or out and never raising, and records ONE {Cache::Descriptor::GlobEntry} over `path/*` — the whole listing, so any file added to or removed from the directory, and any content edit under it, reads stale. It is the row for a caller that asks "which of these N candidate files exists here?": rigor-actionpack's template lookup tries nine extensions per view root per `render`, so per-path `#file?` rows would scale with (renders × extensions × roots) while one listing row per consulted `app/views/<controller>` directory covers strictly more names for a warm-run validation count equal to the number of directories consulted. As with `#file?`, the policy gates RECORDING and not the answer. Re-listing a directory REPLACES its row (the last reader's view of the directory is the one the run was shaped on), unlike the first-row-wins `||=` the file rows use. |
| `#glob(root, pattern)` | The **glob membership fingerprint** ([#1652](https://github.com/rigortype/rigor/issues/1652)). Returns the absolute paths (files and directories) matching a `Dir.glob` `pattern` under `root`, `**` included, for every root in scope or out, and records ONE `:names` {Cache::Descriptor::GlobEntry} over `root` and `pattern`: it reads stale when a match appears or disappears, in a subdirectory created after the read too, and NOT when a match's bytes or stat tuple move, so a `touch`, a checkout or a restored CI cache leaves it fresh (the #979 reasoning). A caller whose answer depends on a match's content MUST `#read_file` each match it reads; that `:stat` row carries the edit. Unlike `#list_directory`, whose `:stat` listing row also covers edits under the directory, a `#glob` row never does. A `..` segment in `pattern`, and any brace or backslash (with which `Dir.glob` can spell `..`, as in `{..,x}` or `.\./`), raises {Rigor::Plugin::AccessDeniedError} (`reason: :read_outside_scope`), since the policy is checked against `root` alone. The policy gates recording, not the answer, and re-globbing the same `(root, pattern)` replaces its row. |
| `#open_url(url)` | Under `:disabled` raises {Rigor::Plugin::AccessDeniedError} (`reason: :network_disabled`). Under `:allowlist` (v0.1.2) performs a GET over HTTPS when the parsed host is in `allowed_url_hosts`, enforcing a request timeout (10 s) and a response-body size cap (10 MB); raises `AccessDeniedError` with `reason:` one of `:invalid_url_scheme`, `:host_not_allowed`, `:http_error`, `:request_timeout`, `:body_too_large` on failure. |
| `#cache_descriptor` | Returns a fresh frozen {Cache::Descriptor} with the boundary's accumulated `FileEntry`, `GlobEntry` (`#list_directory`, `#glob`) and `ConfigEntry` (`#open_url`) rows. Subsequent reads expand the underlying record table; each call returns a new descriptor reflecting the read history at that moment. |
| `#replay(descriptor)` | Records the `files`, `configs` and `globs` rows of `descriptor` as though the boundary had observed them, reading no file and consulting no policy ([#1558](https://github.com/rigortype/rigor/issues/1558)). `Plugin::Base#cache_for` calls it with a served producer entry's stored dependency descriptor, which a fresh hit has just validated, so the producer's inputs reach the run-result descriptor and the entry of any producer computed around it although no block ran (see [`plugin-cache-producers.md`](plugin-cache-producers.md) § `cache_for`). It merges by the ordering below; a replayed row never displaces one already held except a content row over an existence row. |

Per-path reads are deduplicated by absolute path; re-reading a
file with changed content updates the entry's digest in place. A
successful read replaces an earlier absence row for the same path
(the file appeared and its bytes were consumed); an absence row
never replaces an earlier content row (two outcomes for one path in
one run mean the file moved under the analysis, and the content row
is the one whose validation covers both content and existence). The
same ordering ranks the probe rows: a content row replaces any
existence row, and between two existence rows for one path the
first recorded stands — whichever it is, it describes the world the
earlier decision was shaped on and reads stale the moment the world
stops matching it, so a mid-run mutation costs a recompute rather
than a wrong hit.

`#replay` follows the same ordering, with one difference: a
replayed content row replaces an existence row, but never a content
row the boundary already holds, and a replayed glob row never
replaces a held row for the same `(root, pattern, mode)` slot. A
hit's rows validated against the current filesystem moments before,
so the two rows agree on the bytes; the held one carries the newer
stat tuple, which keeps the next warm run on the ADR-87 stat fast
path. Every table is keyed by path, glob slot or URL key, so
replaying a descriptor twice adds nothing.

### `Rigor::Plugin::AccessDeniedError`

Public exception for boundary violations. Reasons:

- `:read_outside_scope` — `read_file` called with a path outside
  every allowed read root.
- `:network_disabled` — `open_url` called while
  `network_policy == :disabled`.
- `:invalid_url_scheme` / `:host_not_allowed` / `:http_error` /
  `:request_timeout` / `:body_too_large` — `open_url` failures under
  the `:allowlist` policy (v0.1.2).

Carries the offending `resource` (path or URL).

### `Rigor::Plugin::Services` (trust + fact-store additions)

Slice 2 added the trust surfaces; v0.1.1 (ADR-9) added `fact_store`:

| Method | Purpose |
| --- | --- |
| `#trust_policy` | The {TrustPolicy} for the run. Constructed by `Analysis::Runner` from the project's `.rigor.yml`. |
| `#io_boundary_for(plugin_id)` | Returns a fresh per-plugin {IoBoundary}. The contribution merger (slice 3) constructs one per plugin per run and feeds the resulting cache descriptor through the same pipeline as built-in producers. |
| `#fact_store` | The per-run cross-plugin {Rigor::Plugin::FactStore} (ADR-9 / v0.1.1). Producers publish via `#prepare(services)`; consumers read in `#diagnostics_for_file` / `dynamic_return` blocks. |

## `.rigor.yml` `plugins_io` section

```yaml
plugins_io:
  network: disabled              # :disabled (default) or :allowlist (v0.1.2)
  allowed_url_hosts:             # required hostnames when network: allowlist
    - example.com
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
   (`:disabled` default, or `:allowlist` with
   `Configuration#plugins_io_allowed_url_hosts`, v0.1.2).

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

- **Wire the boundary's cache descriptor into `Cache::Store`.**
  That was slice 6's job — plugin-side cache producers ride
  `Store#fetch_or_validate(serialize:, deserialize:)` (ADR-60 WD3
  record-and-validate) with `PluginEntry` rows in the descriptor schema
  ([plugin-cache-producers.md](plugin-cache-producers.md)). Slice 2 only
  built the descriptor.

v0.1.2 lifted the network gate: `network_policy` now also accepts
`:allowlist`, which permits HTTPS GETs to hosts in
`allowed_url_hosts` through `IoBoundary#open_url`, with a request
timeout and a response-size cap. The default stays `:disabled`.

The descriptor a boundary accumulates is no longer unconsumed:
`Analysis::Runner#run_dependency_descriptor` folds every plugin
boundary's `#cache_descriptor` files into the run's dependency
descriptor, so a file a plugin read through the boundary participates
in run-result cache invalidation like any analyzed file or `sig` file.
Since #1558 that includes the files behind every producer value the
plugin was served from its own cache, which `cache_for` replays into
the boundary.
