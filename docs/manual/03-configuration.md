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
| `signature_paths` | Array | `nil` | Extra directories of `.rbs` files. |
| `pre_eval` | Array | `[]` | Files (or globs) walked before per-file analysis, to register project monkey-patches. |
| `plugins` | Array | `[]` | Plugins to activate — see [Using plugins](07-plugins.md). |

### Diagnostics

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `disable` | Array | `[]` | Rule IDs or families to suppress project-wide. |
| `severity_profile` | String | `"balanced"` | `lenient`, `balanced`, or `strict` — see [Diagnostics](04-diagnostics.md). |
| `severity_overrides` | Hash | `{}` | Per-rule / per-family severity, e.g. `{ call: warning, flow.always-truthy-condition: off }`. |
| `baseline` | String / `false` | `nil` | Path to a `.rigor-baseline.yml`, or `false` to disable an inherited one. See [Baselines](06-baseline.md). |

### Dependency RBS discovery

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `bundler.auto_detect` | Boolean | `true` | Auto-detect the Bundler install path and lockfile. |
| `bundler.bundle_path` | String | `nil` | Explicit Bundler install root. |
| `bundler.lockfile` | String | `nil` | Explicit `Gemfile.lock` path. |
| `rbs_collection.auto_detect` | Boolean | `true` | Auto-discover `rbs_collection.lock.yaml`. |
| `rbs_collection.lockfile` | String | `nil` | Explicit `rbs_collection.lock.yaml` path. |
| `dependencies.source_inference` | Array | `[]` | Per-gem source-inference modes (ADR-10). |
| `dependencies.budget_per_gem` | Integer | `1000` | Per-gem inference time budget, in ms. |

### Execution

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `cache.path` | String | `.rigor/cache` | Persistent cache directory. See [Caching](12-caching.md). |
| `parallel.workers` | Integer | `0` | Parallel worker processes for per-file analysis (fork-based pool today; ADR-15); `0` is sequential. CLI `--workers` and `RIGOR_RACTOR_WORKERS` take precedence. |
| `plugins_io.network` | String | `"disabled"` | Plugin network policy — `disabled` or `allowlist`. |
| `plugins_io.allowed_paths` | Array | `[]` | Filesystem paths plugins may read. |
| `plugins_io.allowed_url_hosts` | Array | `[]` | URL hosts plugins may fetch from when `network: allowlist`. |

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
