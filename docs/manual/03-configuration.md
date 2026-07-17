# Configuration

Rigor reads a single YAML configuration file from the project
root. `rigor init` writes a starter one.

## Discovery and precedence

With no `--config` flag, Rigor looks for, in order:

1. `.rigor.yml`
2. `.rigor.dist.yml`

The **first file found wins** — the two are not merged. The
convention is to commit `.rigor.dist.yml` as the shared
project config and let an individual developer drop an
(un-tracked) `.rigor.yml` to override it locally.

To *layer* configs rather than replace, a config file can name
a base with `includes:` (recursive). `--config=PATH` bypasses
discovery entirely.

All relative paths in a config file resolve against that
file's own directory.

## Editor validation

Rigor ships a JSON Schema for this file. Editors that
understand the [`yaml-language-server`](https://github.com/redhat-developer/yaml-language-server)
magic comment — VS Code's YAML extension, the IntelliJ
family, Helix, Neovim with `yaml-ls` — give you
autocomplete, hover docs, and structural validation as you
type:

```yaml
# yaml-language-server: $schema=https://github.com/rigortype/rigor/raw/master/schemas/rigor-config.schema.json
```

`rigor init` writes that line for you. The schema is not a
copy of this page — it is a source of truth in its own
right, kept in step with the loader by a spec, so a key it
rejects is a key Rigor does not accept.

## A minimal config

```yaml
target_ruby: "4.0"
paths:
  - lib
plugins: []
cache:
  path: .rigor/cache
```

## Key reference

### Sources and target

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `target_ruby` | String | `"4.0"` | The Ruby version *your* project runs — `"X.Y"`, `"X.Y.Z"`, or `"latest"`. Independent of the Ruby Rigor itself runs on. |
| `paths` | Array | `["lib"]` | Directories or files to analyse. |
| `exclude` | Array | `[]` | Glob patterns to skip. `vendor/bundle`, `.bundle`, and `node_modules` are always excluded. |
| `includes` | Array | `[]` | Other config files to layer underneath this one. |
| `fold_platform_specific_paths` | Boolean | `false` | Resolve Ruby-version-conditional load paths when discovering sources. |

### Type sources

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `libraries` | Array | `[]` | Standard-library / gem names whose bundled RBS to load. |
| `signature_paths` | Array | `nil` | Extra directories of `.rbs` files. Relative entries resolve against the config file's directory. |
| `pre_eval` | Array | `[]` | Files (or globs) walked before per-file analysis, to register project monkey-patches. |
| `plugins` | Array | `[]` | Plugins to activate — see [Using plugins](07-plugins.md). |

### Config validation warnings

`rigor check` warns on STDERR when a configured value silently resolves to
nothing — the class of mistake where a typo loads zero signatures (or
leaves a suppression inert) and the only symptom is downstream and
confusing. A missing RBS path, for instance, turns every call into the
types it was meant to describe into a high-confidence
`call.undefined-method`, so a one-character mistake can look like hundreds
of real type errors. The audit covers:

```
rigor: `excludee` is not a recognized configuration key; it has no effect. Did you mean `exclude`?
rigor: signature_paths: "/path/to/sig" does not exist (no signatures loaded from it)
rigor: signature_paths: "/path/to/sig" matched 0 signature files
rigor: libraries: "csb" is not an available RBS library (no signatures loaded from it)
rigor: disable: "call.undefined-methdo" is not a recognized rule id; the suppression has no effect
rigor: severity_overrides: "flow.bogus" is not a recognized rule id; the override has no effect
rigor: bundler.lockfile: "./missing/Gemfile.lock" does not exist
```

The unrecognised-key check covers **top-level** keys, and skips
the namespaces reserved for other implementations (see below).
A typo *inside* a group — `cache: { pth: … }` — is caught by
the JSON schema as you type rather than at check time.

These are warnings, not errors — partial or optional bundles and
forward-looking config are valid setups. The audit only fires on explicit,
working-setup-safe signals: an unset default (auto-detected `<root>/sig`,
auto-detected bundle) is never warned about, and a `disable:` /
`severity_overrides:` token under a *plugin* family (`rspec.…`,
`rbs_extended.…`) is left alone, since its rule id cannot be enumerated
statically and may resolve at run time. The same findings appear in the
`--format=json` payload under `config_warnings` (each tagged with a
`kind`), so CI can assert on them.

### Diagnostics

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `disable` | Array | `[]` | Rule IDs or families to suppress project-wide. |
| `severity_profile` | String | `"balanced"` | `lenient`, `balanced`, or `strict` — see [Diagnostics](04-diagnostics.md). |
| `severity_overrides` | Hash | `{}` | Per-rule / per-family severity, e.g. `{ call: warning, flow.always-truthy-condition: off }`. |
| `baseline` | String / `false` | `nil` | Path to a `.rigor-baseline.yml`, or `false` to disable an inherited one. See [Baselines](06-baseline.md). |
| `bleeding_edge` | Boolean / Array / Hash | `false` | Adopt the next major's queued diagnostic disciplines early ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) § WD2). `false` adopts none; `true` adopts the whole overlay; a list of feature ids adopts only those; `{ all: true, except: [ids] }` adopts all but the named. Orthogonal to `severity_profile`. Override it for a single run with [`rigor check --bleeding-edge[=ids]`](02-cli-reference.md#rigor-check) / `--no-bleeding-edge`. Inspect with [`rigor show-bleedingedge`](02-cli-reference.md#rigor-show-bleedingedge). |

### Dependency RBS discovery

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `bundler.auto_detect` | Boolean | `true` | Auto-detect the Bundler install path and lockfile. |
| `bundler.bundle_path` | String | `nil` | Explicit Bundler install root. |
| `bundler.lockfile` | String | `nil` | Explicit `Gemfile.lock` path. |

`bundler.auto_detect` looks for the Bundler install root in project-local
locations first — the `path` recorded in `<project>/.bundle/config`, then a
`<project>/vendor/bundle/` directory — and falls back to a user-global
`bundle config set --global path …` (`~/.bundle/config`) when the project
has no in-tree bundle.

It deliberately does **not** read `BUNDLE_PATH` from rigor's own
environment, and it cannot reach gems installed at the *default* shared
location (the active Ruby's `GEM_HOME`, when no `path` is configured):
rigor runs in its own isolated Ruby and reads your project as data
([ADR-27](../adr/27-tool-distribution-model.md)), so it does not know the
project Ruby's gem home without running your toolchain. If `rigor check`'s
`--stats` shows gems whose RBS it could not find, point it at the bundle
explicitly with `bundler.bundle_path:`, or supply signatures another way:
`rbs collection install` (auto-discovered) or `dependencies.source_inference:`.
| `rbs_collection.auto_detect` | Boolean | `true` | Auto-discover `rbs_collection.lock.yaml`. |
| `rbs_collection.lockfile` | String | `nil` | Explicit `rbs_collection.lock.yaml` path. |
| `dependencies.source_inference` | Array | `[]` | Per-gem source-inference modes (ADR-10). |
| `dependencies.budget_per_gem` | Integer | `5000` | Per-gem source-walk cap, counted in **method definitions** (not time): the walker stops harvesting a gem's catalog once it reaches this many `def`s, then emits `dynamic.dependency-source.budget-exceeded` and degrades the rest to `Dynamic[top]`. Range 1250–20000. |
| `dependencies.budget_overrun_strategy` | String | `"walker_cap"` | What happens to calls on a gem that hit `budget_per_gem` (ADR-10 § 5b). `walker_cap` (default) lets methods past the cap fall through to the engine's normal user-class resolution. `dependency_silence` instead resolves any call on a class from a budget-exceeded gem to `Dynamic[top]`, silencing `call.undefined-method` on that gem's unrecorded surface at the cost of weaker static checking there. |

### Execution

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `cache.path` | String | `.rigor/cache` | Persistent cache directory. See [Caching](12-caching.md). |
| `cache.max_bytes` | Integer or `null` | `268435456` (256 MB) | LRU eviction cap for the cache directory; `null` disables eviction. See [Caching § Size and eviction](12-caching.md#size-and-eviction). |
| `cache.validation` | String | `"stat"` | How the cache checks whether a file is unchanged: `stat` compares size + nanosecond timestamps + inode and only re-hashes a file whose stat moved; `digest` re-hashes every file's content every run. Both keep the content hash as the sole change authority — `stat` just skips the hash when the stat proves a file untouched. See [Caching § How a file is checked for changes](12-caching.md#how-a-file-is-checked-for-changes). The `RIGOR_STRICT_VALIDATION=1` environment variable forces `digest` for one run and wins over this key. |
| `parallel.workers` | Integer | `0` | Parallel worker processes for per-file analysis (fork-based pool today; ADR-15); `0` is sequential. CLI `--workers` and `RIGOR_RACTOR_WORKERS` take precedence. Applies to `--incremental` re-checks as well as full runs. |
| `plugins_io.network` | String | `"disabled"` | Plugin network policy — `disabled` or `allowlist`. |
| `plugins_io.allowed_paths` | Array | `[]` | Filesystem paths plugins may read. |
| `plugins_io.allowed_url_hosts` | Array | `[]` | URL hosts plugins may fetch from when `network: allowlist`. |

### Reserved for other implementations

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `rigor_rs` | Hash | — | **Reserved; this implementation skips it.** Another Rigor implementation reads keys under this namespace, so one `.rigor.yml` can serve both. Rigor validates its shape at the schema level only — it never reads the value, and an invalid one is never a runtime error here. Leave it alone unless the tool that reads it tells you otherwise. |

## A worked example

```yaml
target_ruby: "3.4"
paths:
  - lib
  - app
exclude:
  - "**/*_pb.rb"
plugins:
  - rigor-activerecord
  - rigor-rspec
severity_profile: balanced
severity_overrides:
  flow.dead-assignment: warning
baseline: .rigor-baseline.yml
```
