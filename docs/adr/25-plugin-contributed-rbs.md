# ADR-25 — Plugin-contributed RBS signatures

Status: **Accepted, 2026-05-21.**

Records the decision to let a
plugin gem contribute RBS signature directories to Rigor's analysis
environment through its manifest — closing the gap that today forces
an RBS-only "bundle" gem to be wired by a hand-written
`signature_paths:` path. WD1 (a `Manifest` field, not a
`signature_gems:` config key) is ratified; the rejected config-key
alternative is recorded for the written premise.

## Context

Rigor today feeds its RBS environment from three sources, all
resolved into `RbsLoader`'s `signature_paths`:

1. **`signature_paths:`** in `.rigor.yml` — an explicit list of
   directory paths. `.rigor.yml` is parsed with plain
   `YAML.safe_load_file` (no ERB), so an entry is a literal path —
   a gem name does not resolve, and there is no portable way to name
   "the `sig/` inside an installed gem".
2. **`bundler:` discovery** (`Environment::BundleSigDiscovery`) —
   walks `<bundle_path>/ruby/*/gems/*/sig/`. Auto-detects only the
   `vendor/bundle` / `.bundle/config` `BUNDLE_PATH` layouts, and is
   *indiscriminate*: it admits every non-skipped gem's `sig/`, not a
   chosen set. A project that runs a plain `bundle install` (gems in
   the system / rbenv gem dir) gets nothing without an explicit
   `bundle_path:`.
3. **`rbs_collection:`** — parses `rbs_collection.lock.yaml`.

A `Plugin::Base` plugin can contribute diagnostics
(`diagnostics_for_file`), per-call return types
(`flow_contribution_for`), macro-substrate declarations, type-node
resolvers, and cross-plugin facts — but it **cannot contribute RBS**.
There is no manifest hook for "extend the signature environment when
this plugin loads".

The concrete victim is `rigor-activesupport-core-ext`. It is a gem
whose entire purpose is to ship `sig/` for the ActiveSupport
`core_ext` selectors (the single largest `call.undefined-method`
cluster on Rails projects — a measured Mastodon run: ~365 of 488
diagnostics). Because no plugin-side RBS hook exists, it is **not a
plugin at all** — its `lib/rigor-activesupport-core-ext.rb` is a bare
comment, and the user must hand-wire `signature_paths:` to the gem's
`sig/`. With no ERB in config, the only working forms are an
absolute, version-pinned path (`bundle show …`) or a vendored copy
of the directory. The gem's own README documents this manual step as
a known wart and names the missing mechanism: *"Until Rigor grows a
plugin manifest entry for 'extend `signature_paths` when loaded', the
simplest packaging is a `sig/` directory the user wires in by hand."*

The same gap blocks any future plugin from shipping RBS overlays
alongside its analyzer code — e.g. a Rails plugin that wants to ship
both diagnostics and a `sig/` overlay for the framework classes it
recognises.

This ADR closes that gap.

## Decision

Add an optional **`signature_paths:`** field to the plugin
`Manifest`. A plugin declares the RBS directories it ships, as paths
relative to its own gem root. When the plugin is listed in
`.rigor.yml`'s `plugins:` and successfully loads, `Plugin::Loader`
resolves each declared directory to an absolute path and the
resolved set is merged into the RBS environment alongside the
configuration's `signature_paths:` and the `bundler:` /
`rbs_collection:` discovery output.

A **pure RBS bundle becomes a trivial plugin**: a `Plugin::Base`
subclass with a manifest that declares `signature_paths:` and nothing
else (no `diagnostics_for_file`, no `flow_contribution_for`).
`rigor-activesupport-core-ext` converts to exactly this shape, and a
project activates it the same way it activates any plugin —
`plugins: [rigor-activesupport-core-ext]` — with no path, no
vendoring, no absolute reference. The plugin gem resolves its own
`sig/` location internally.

## Working decisions

### WD1 — A manifest field, not a config key

The mechanism is a `Manifest` field, not a new `.rigor.yml`
top-level key (e.g. a rejected `signature_gems:`).

- The manifest already carries every other plugin contribution
  declaration — `config_schema`, `produces` / `consumes`,
  `owns_receivers`, `type_node_resolvers`, `block_as_methods`,
  `heredoc_templates`, `trait_registries`, `external_files`,
  `hkt_registrations`. RBS contribution belongs in the same place;
  it is a property of the plugin, declared once by its author, not
  per-project configuration.
- A `signature_gems:` config key would be a *second* mechanism for
  users to learn, redundant the moment plugins can contribute RBS —
  a project that wants a gem's `sig/` just lists the gem under
  `plugins:`.
- Activation stays in one list. A reviewer reading `.rigor.yml`
  sees every Rigor extension — diagnostic plugins and RBS bundles
  alike — under `plugins:`.

### WD2 — Paths are relative to the plugin's gem root

The manifest field holds **relative** directory strings (`["sig"]`
for the common case). Absolute paths in a published gem are
meaningless on another machine.

`Plugin::Loader` already `require`s each plugin gem and observes the
plugin class it registers. The loader records that class's defining
file (`Object.const_source_location`), walks up to the gem root
(the directory containing `lib/`), and resolves each manifest
`signature_paths:` entry against it. A declared directory that does
not exist is a load-time `LoadError` for that plugin — loud, not
silent, because a missing `sig/` means the bundle gem is broken.

### WD3 — A pure RBS bundle is still a plugin

An RBS-only gem (no analyzer code) is packaged as a `Plugin::Base`
subclass whose manifest declares `signature_paths:` and which
overrides no hook. `diagnostics_for_file` inherits the base no-op.
This is a deliberate, small amount of ceremony — one ~10-line plugin
class — in exchange for: portable activation, a single `plugins:`
list, and uniformity with every other Rigor extension.

Rejected alternative — a distinct "RBS bundle" artefact type with
its own loader path: it would duplicate the loader's gem-require /
registration / id-uniqueness machinery for no behavioural gain.

### WD4 — Plugin sigs are additive; conflicts degrade gracefully

Plugin-contributed `signature_paths:` are merged with — never
replace — the configuration's `signature_paths:`, the `bundler:`
discovery output, and `rbs_collection:`. A duplicate-declaration
conflict (a plugin's `sig/` redeclares a constant another source
already defines) degrades through the **same O7 failure-memo path**
in `RbsLoader#env` that `BundleSigDiscovery` conflicts already use:
one warning naming the offending file, analysis continues. No new
conflict-handling surface.

### WD5 — Targeted contribution vs. broad discovery

`BundleSigDiscovery` (the `bundler:` config) stays. The two are
complementary:

| | Plugin-contributed (this ADR) | `BundleSigDiscovery` |
| --- | --- | --- |
| Scope | Exactly the plugins under `plugins:` | Every non-skipped gem in `vendor/bundle` |
| Intent | The author *declares* "this gem is an RBS source" | Opportunistic — picks up whatever ships `sig/` |
| Layout | Any — the plugin resolves its own path | `vendor/bundle` / `.bundle/config` only |

Plugin contribution is the **intentional, portable** path; bundle
discovery remains the opportunistic catch-all. Extending
`BundleSigDiscovery` to the default `bundle install` layout is a
separate, smaller follow-up (noted in § "Out of scope").

### WD6 — Additive to the pre-1.0 plugin contract

The plugin contract (ADR-2) is pre-1.0. This change is a **new
optional manifest field** — a plugin that does not declare
`signature_paths:` is unaffected, and no existing plugin breaks. It
is safe to land within the v0.1.x line and should be part of the
public surface the v1.0.0 contract freezes. (Amended per
[ADR-50](50-release-engineering-and-stability-strategy.md): the hard
freeze is **v1.0.0**; **v0.2.0** begins enumerating the surface and
pledges minor-non-break as the trajectory — it does not itself
freeze. This supersedes the original "v0.2.0 freezes" wording.)

## Consequences

### Positive

- **`rigor-activesupport-core-ext` gets a portable, one-line
  activation.** `plugins: [rigor-activesupport-core-ext]` — no
  `bundle show`, no absolute path, no vendoring. The README's manual
  wiring section and its v0.1.x wart disappear.
- **The `rigor-project-init` SKILL simplifies.** Its
  `signature_paths:` step for the AS bundle (currently a
  vendor-the-directory instruction) collapses into the ordinary
  plugin-selection step.
- **Future plugins can ship RBS overlays.** A Rails plugin can ship
  diagnostics *and* a `sig/` overlay for the classes it models, in
  one gem, declared in one manifest.
- **One activation surface.** Every Rigor extension — diagnostic
  plugin or RBS bundle — is a `plugins:` entry.

### Negative

- **A pure RBS bundle now carries a plugin class.** ~10 lines of
  ceremony where today there is a bare gem. Judged worth it for the
  portability and uniformity (WD3).
- **One more manifest field** on a pre-1.0 contract. Additive and
  low-risk (WD6).

### Carry-over

- Extending `BundleSigDiscovery` auto-detection to the default
  `bundle install` gem layout is *not* solved here — it stays an
  opportunistic-discovery improvement, queued separately.

## Implementation slicing (proposed)

### Slice 1 — manifest field + loader resolution + environment merge

- `Manifest` gains an optional `signature_paths:` field (array of
  relative strings, frozen).
- `Plugin::Loader` resolves each loaded plugin's declared directories
  to absolute paths against the plugin gem root (WD2); a missing
  directory is a `LoadError` for that plugin.
- `Runner` / `Environment.for_project` merge the registry's resolved
  plugin sig directories into the signature-path set passed to
  `RbsLoader` (the registry is already threaded into
  `Environment.for_project`).
- Specs: manifest field plumbing, loader resolution + missing-dir
  error, end-to-end `Environment` pickup.

### Slice 2 — convert `rigor-activesupport-core-ext` to a plugin

- Add a `Rigor::Plugin::ActivesupportCoreExt < Plugin::Base` class
  whose manifest declares `signature_paths: ["sig"]`; register it.
- Rewrite the README's "Usage" around `plugins:` activation; drop
  the manual `signature_paths:` / vendoring instructions.

### Slice 3 — onboarding follow-through

- Update the `rigor-project-init` SKILL: the AS bundle moves from a
  `signature_paths:` wiring step into ordinary plugin selection.
- Cross-reference from the `bundler:` / `rbs_collection:`
  configuration docs.

## References

- [ADR-2](2-extension-api.md) — the plugin contract this extends.
- `plugins/rigor-activesupport-core-ext/README.md` § "Why a `sig/`
  bundle and not a `Rigor::Plugin::Base` subclass" — the gap this
  ADR closes, named by the bundle itself.
- [`docs/notes/20260521-mastodon-v4.5-regression-sweep.md`](../notes/20260521-mastodon-v4.5-regression-sweep.md)
  and [`docs/notes/20260515-real-world-rails-survey.md`](../notes/20260515-real-world-rails-survey.md)
  — the surveys establishing the ActiveSupport `core_ext` cluster as
  the dominant Rails diagnostic source.
- `lib/rigor/environment/bundle_sig_discovery.rb` — the
  opportunistic discovery this ADR's targeted mechanism complements.
