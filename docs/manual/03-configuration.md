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
| `parameter_inference` | Boolean | `false` | Opt-in call-site parameter type inference on the `check` walk ([ADR-67](../adr/67-parameter-type-inference.md) WD6). When `true`, an undeclared `def` / `initialize` / setter parameter is typed to the union of its resolved call-site argument types, sharpening downstream ivar reads, folds, and protection coverage. Precision-additive only — the negative rules never fire against an inferred parameter. Cannot be combined with `--incremental`. |

### Type sources

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `libraries` | Array | `[]` | Standard-library / gem names whose bundled RBS to load. |
| `signature_paths` | Array | `nil` | Extra directories of `.rbs` files. Relative entries resolve against the config file's directory. |
| `pre_eval` | Array | `[]` | Files (or globs) walked before per-file analysis, to register project monkey-patches and publish their top-level constants project-wide. |
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
| `bleeding_edge` | Boolean / Array / Hash | `false` | Adopt the next major's queued changes early ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) § WD2). `false` adopts none; `true` adopts the whole overlay; a list of feature ids adopts only those; `{ all: true, except: [ids] }` adopts all but the named. Orthogonal to `severity_profile`. Override it for a single run with [`rigor check --bleeding-edge[=ids]`](02-cli-reference.md#rigor-check) / `--no-bleeding-edge`. Inspect with [`rigor show-bleedingedge`](02-cli-reference.md#rigor-show-bleedingedge). |

A queued feature is one of two kinds, and `bleeding_edge:` selects both the
same way:

- A **severity** feature promotes one or more rules — a discipline Rigor
  already reports quietly becomes an error or a warning. Its diff is a list
  of rule ids, printed by `rigor show-bleedingedge`.
- A **behaviour** feature changes a measurement, an algorithm, or a
  default, and moves no rule's severity. There is no rule-id diff to read,
  so its summary in `rigor show-bleedingedge` is the whole description of
  what adopting it does.

An id you name that this version of Rigor does not know is ignored rather
than rejected, so a shared `.rigor.yml` can name a feature that only some
of the versions in use have queued.

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
| `cache.validation` | String | `"auto"` | How the cache checks whether a file is unchanged: `auto` behaves as `digest` when a CI environment is detected and as `stat` otherwise; `stat` compares size + nanosecond timestamps + inode and only re-hashes a file whose stat moved; `digest` re-hashes every file's content every run. Both keep the content hash as the sole change authority — `stat` just skips the hash when the stat proves a file untouched. See [Caching § How a file is checked for changes](12-caching.md#how-a-file-is-checked-for-changes). The `RIGOR_STRICT_VALIDATION=1` environment variable forces `digest` for one run and wins over this key; `RIGOR_CI_DETECT=0` disables the CI detection. |
| `parallel.workers` | Integer | `0` | Parallel worker processes for per-file analysis (fork-based pool today; ADR-15); `0` is sequential. CLI `--workers` and `RIGOR_RACTOR_WORKERS` take precedence. Applies to `--incremental` re-checks as well as full runs. |
| `plugins_io.network` | String | `"disabled"` | Plugin network policy — `disabled` or `allowlist`. |
| `plugins_io.allowed_paths` | Array | `[]` | Filesystem paths plugins may read. |
| `plugins_io.allowed_url_hosts` | Array | `[]` | URL hosts plugins may fetch from when `network: allowlist`. |

### Effect labels

The key reference is below; the workflow these keys serve — the vocabulary, the report, the committed
snapshot, the CI gate — is [Effect labels](19-effect-labels.md).

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `effects` | Hash | absent | **Opt-in to effect labels ([ADR-103](../adr/103-effect-labels.md)).** The *presence* of this block is the switch — `effects: {}` enables collection with every sub-key at its default, and leaving it out keeps `rigor check` byte-identical and free. Nothing else turns collection on: an `%a{pure}` or `%a{rigor:v1:effect …}` annotation in your RBS does not, because an annotation must not silently make every run more expensive — such a project gets one `effect.annotations-unchecked` `:info` per run instead, saying the annotations are inert. `rigor effects` runs under an implicit empty block when the key is absent, so you can try the report before configuring anything. Effect summaries are cached under their own identity (Rigor's effect vocabulary, its built-in catalogue and this block), so `rigor effects` after `rigor check` in the same job is a cache hit plus the propagation, and turning this block on or off does not invalidate your diagnostics cache. The sub-keys are below. `views` is declared in the schema and reserved: accepted and **not yet read**. See [`rigor effects`](02-cli-reference.md#rigor-effects). |
| `effects.check` | Boolean | `true` | Whether the envelopes you declared — `%a{pure}` and `%a{rigor:v1:effect …}` in RBS, and the `effects.envelopes:` stanzas below — are checked against what Rigor proved, surfacing `effect.envelope-exceeded` and, for a label the vocabulary does not recognise, `effect.unknown-label`. Set it to `false` to keep the report and the snapshot while silencing both. Never on without an `effects:` block. |
| `effects.snapshot.path` | String | `.rigor-effects.yml` | Where `rigor effects update` writes the committed record. |
| `effects.snapshot.reach` | Array | `[]` | Entry points whose **transitive** footprint the snapshot records under `reach:`. The default is empty **deliberately**: Rigor could infer `[rails]` from your plugin list, but a snapshot is a record you agree to and review the diff of, and one whose contents moved because your plugin list moved would be the worse artefact. `rigor effects update` names the presets your plugins registered and leaves the same hint in the written file. Each entry is a project-relative file glob (the `unused --entry-point` semantics — `**` is the only way across a directory boundary) or the name of an entry-point **preset** a plugin registered. On a Rails app, `reach: [rails]` is the one you want — see below. A name nothing registered is an error when the snapshot is built (not when the configuration loads, because the plugins that name presets load *from* that configuration); the error lists the presets your plugins did register, so it names the fix. |
| `effects.snapshot.gate` | String | `symmetric` | What `rigor effects check` treats as drift. `symmetric` fails on any difference — a job that *stopped* enqueueing is news too; `additions` is the growth-only ratchet. |
| `effects.labels` | Array | `[]` | Effect labels **your project** registers, layered over Rigor's shipped vocabulary. A project may open any root (`acme.cache`) — listing the label here is the vouching act. Once registered, a label is usable in every other key below and stops being reported as unknown. Malformed spellings are a load error. |
| `effects.attribution` | Hash | `{}` | What a call into code Rigor cannot see *does*, keyed by method: `{"Net::HTTP.get": [io.net.http], "Logger#info": [telemetry]}`. Keys are method keys — `Owner#instance_method` or `Owner.singleton_method` — and anything else is a load error. The labels land in the caller's **declared** lane and never in the proven one, so an attribution can never make a diagnostic fire; the call still counts as unresolved, because you told Rigor what that code does and Rigor did not read it. Use it for gems nobody has written a plugin for. |
| `effects.envelopes` | Array | `[]` | Effect envelopes by **convention**, so a whole architectural layer is bounded by one stanza instead of a per-method annotation. Each entry names exactly one of `match:` (a project-relative path glob over the files a class is defined in) or `namespace:` (a constant glob: `*` is one segment, `**` is one or more), plus `effect:` — the labels the selected classes may perform, or `[]` for pure. Nearest wins: a per-method annotation beats a class-level one, which beats a stanza; among stanzas the **first** match wins. See the example below. |
| `effects.tolerated` | Array | `[]` | Labels your project has decided not to act on. Applied when a bound or a difference is **judged**, never when a record is written, and **per origin**: `Logger#info` carries `io` and `telemetry` together, so `tolerated: [telemetry]` frees the `io` that came with the logging and leaves an `io.fs.read` from a `File.read` in the same method exactly where it was. `rigor check --no-tolerated-effects` (and the same flag on `rigor effects check`) re-judges as if the list were empty — the audit switch for the policy. |

Want the block on without writing it? The
[`effects-on-by-default`](02-cli-reference.md#rigor-show-bleedingedge)
bleeding-edge feature (`bleeding_edge: [effects-on-by-default]`) makes a
config with no `effects:` key at all behave as `effects: {}` — collection,
`effects.check`, and everything else on this page all turn on at their
defaults. It only fills an *absence*: write `effects: false` and you stay
opted out regardless, and any `effects:` block you do write is left exactly
as written. It previews what becomes the default at **v0.4.0**
([ADR-103](../adr/103-effect-labels.md) § WD15).

#### Entry-point presets

`reach:` asks "whose footprint should the record cover", and on a framework the honest answer is a fact
about the framework rather than about your code. So the plugin that models it names the set, and you
adopt it:

```yaml
plugins:
  - rigor-railties
  - rigor-activerecord
  - rigor-actionpack

effects:
  snapshot:
    reach: [rails]
```

`rails` — registered by `rigor-railties`, which is a distinct plugin from the
[`rigor-rails`](plugins/rigor-rails.md) convenience grouping — stands for `app/controllers/**`,
`app/jobs/**`, `app/mailers/**` and `app/channels/**`: every way the outside world enters the
application. The component plugins also register the narrower `rails-controllers`, `rails-jobs`,
`rails-mailers` and `rails-channels` if you want one layer's footprint rather than all four. A preset is
just a name for globs; mixing the two in one list is fine.

Listing the plugin is what registers its preset, so `reach: [rails]` without `rigor-railties` in
`plugins:` is an error saying so.

#### Envelopes by convention

The `envelopes:` list is the surface that pays on day one, before you have written any RBS:

```yaml
effects:
  envelopes:
    - match: "app/presenters/**/*.rb"   # presenters render; they do not query
      effect: []
    - namespace: "Policies::*"          # Policies::Edit, not Policies::Admin::Edit
      effect: [mutate.local]
    - match: "app/jobs/**/*.rb"
      effect: [io]
  tolerated: [telemetry]
```

A stanza attaches its bound to every method of every class it selects, exactly as an annotation on the
class would. A method that exceeds it gets one `effect.envelope-exceeded` at its `def`, naming the
stanza it broke:

```
app/presenters/user_presenter.rb:14:1: warning: Method Presenters::User#render performs io.fs.read
  (File.read), but is declared effect: [] at .rigor.yml effects.envelopes[0], so io.fs.read exceeds
  the envelope.
```

When one method is a deliberate exception, write the narrower envelope on it in RBS — nearest wins,
and no `except:` key is needed. When a whole *kind* of effect is acceptable everywhere, name it in
`tolerated:` instead of loosening every stanza.

**One stanza can land hundreds of warnings**, one per (method, label) pair — on a mid-size Rails
application, `match: "app/helpers/**/*.rb"` with `effect: []` produced 343 across 18 files. That is
the layer telling you what it does rather than a misconfiguration, but it is not a work list either;
[Effect labels § Envelopes by convention](19-effect-labels.md) walks the recipe for working it down.

A stanza is checked against **proven** labels only, so on a Rails application it cannot fire on
`io.db.*`, `cache.*`, `telemetry`, `email.send`, `job.enqueue` or any `rails.*`: those come from a
plugin modelling a framework Rigor did not read, and a claim about unread code must not be able to
fail your build. The enforcement path for that half is the committed snapshot, whose `rigor effects
check` marks a declared-lane addition with `≤+` — [Effect labels § What a bound can and cannot
see](19-effect-labels.md#what-a-bound-can-and-cannot-see), and
[ADR-103](../adr/103-effect-labels.md) § WD17 for why.

If a layer is not ready for a bound yet, leave `envelopes:` out and start with the committed snapshot
([`rigor effects update`](02-cli-reference.md#the-effect-snapshot)) — it needs no declaration at all,
and stanzas are the second step, written once the record has told you what the layer actually does.
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
