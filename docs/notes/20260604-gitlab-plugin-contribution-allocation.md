# Profiling `rigor check` on GitLab: plugin-contribution churn

*2026-06-04. Profiling note — informational, not normative. The spec binds.*

## Question

The [Mastodon allocation profile](20260604-mastodon-allocation-profile.md)
characterised a 6-plugin Rails app. GitLab is the larger, **plugin-heavy**
anchor — does a bigger plugin set move the bottleneck? Profiled with
plugins **on** and a **warm** cache, as requested.

## Setup

- Target: `gitlab-foss` @ `9cdbf8ef1`, the configured subset
  (`app/controllers` + `app/mailers` + `app/workers` + `app/services`) =
  **2,630 `.rb` files**.
- Config: **11 Rails plugins** (actionpack, activerecord, actionmailer,
  rails-routes, rails-i18n, activesupport-core-ext, activejob,
  activestorage, actioncable, rspec-rails, devise), `severity_profile:
  lenient`, `--workers 0`.
- Cache **warm** (one build run first; cold build = 163.9 s — warm saves
  little, consistent with the Mastodon cache finding: the cache holds the
  RBS env + plugin tables, not per-file results).
- Envelope: ~163 s wall, **180 diagnostics** (164 errors).
- Measured after the four Mastodon-era allocation cuts were already in.

## Headline: the plugin-contribution path dominates allocation

GitLab allocates **522 M objects** for 2,630 files — **~198,500
objects/file, 3× Mastodon's 67k/file.** The extra factor is the plugin
set. CPU is GC-bound (`(sweeping)` 35.7 % + `(marking)` 7.3 % ≈ 43 %),
but the *allocation* profile (stackprof `:object`) points squarely at the
plugin contribution machinery:

| alloc % | site |
|--:|---|
| **17.1 %** | `Kernel#dup` (74 % from `dynamic_returns`, 20 % from `type_specifiers`) |
| **12.8 %** | `Plugin::Base.dynamic_returns` |
| **12.8 %** | `MethodDispatcher.collect_plugin_contributions` |
| 3.5 % | `StatementEvaluator#collect_plugin_contributions` |
| 3.5 % | `Plugin::Base#type_specifier_facts` |
| 3.5 % | `Plugin::Base.type_specifiers` |
| 2.0 % | `Data#initialize` (CallContext) |
| 1.9 % | `Scope#rebuild` |

`collect_plugin_contributions` is **40.7 % inclusive** — it runs per
call-site dispatch and `flat_map`s over *every* plugin:

```ruby
registry.plugins.flat_map { |plugin| ... plugin.dynamic_return_type ... }
```

and each plugin's reader did, **per call**:

```ruby
def dynamic_returns;  (@dynamic_returns || []).dup.freeze; end   # base.rb:225
def type_specifiers;  (@type_specifiers || []).dup.freeze; end   # base.rb:255
```

`@dynamic_returns` / `@type_specifiers` are built **once at plugin
class-definition time** and every element is already frozen, yet the
reader allocated a fresh `dup.freeze` copy on every read — 11 plugins ×
every dispatch × 2,630 files. That single `.dup` (the `Kernel#dup` at
17 %) plus the readers' self-allocation is **~36 % of all objects**.

## Landed: memoise the contribution snapshots

`dynamic_returns` / `type_specifiers` now memoise the frozen snapshot
(`@…_snapshot ||= (@… || []).dup.freeze`). The array is immutable and
fixed before analysis, so one shared frozen instance is safe; callers
already treated the result as read-only.

Clean A/B on the same target (warm, plugins on, `--workers 0`):

| metric | before | after | Δ |
|---|--:|--:|--:|
| objects allocated | 522.0 M | **351.9 M** | **−33 %** |
| wall | 163.0 s | **150.6 s** | **−7.6 %** (−12.4 s) |
| `GC.stat[:time]` | 15.83 s | 11.72 s | −26 % |
| GC runs | 379 | 263 | −31 % |
| diagnostics | 180 / 164 | **180 / 164** | byte-identical |

`make verify` green (5,418 examples, self-check + plugin-contract check
clean). `Kernel#dup` and the two readers leave the allocation top-table
entirely.

## Faithful re-profile (cwd = gitlab, real `.rigor.yml`)

The runs above were taken from `cwd = rigor` with an absolute-path config,
which left the plugins' *relative* paths (`routes_file`, `helper_paths`)
unresolved, so plugin file-discovery was mostly a no-op. Re-profiled the
real way — `cd gitlab-foss && rigor check` against the project's own
`.rigor.yml` (relative paths resolve to GitLab's tree), `--workers 0`
(the sequential default), `--no-cache`, profiling the only addition.
Faithful diagnostics: **2,323** (38 errors / 20 warnings / 2,265 info),
~146 s.

Two corrections fell out:

- **The routes-read hotspot was a cwd artifact.** With routes resolving,
  `IoBoundary#read_file` is **17,003 calls over 6,901 unique paths = 0.47 s
  (0.3 % of wall)** — not a bottleneck. (The 105,724-read explosion that
  motivated the `rigor-rails-routes` nil-table memo fix only happens when
  the routes file is *absent/unparseable*; that fix is a real robustness
  win but not a GitLab hot path.)
- **`collect_plugin_contributions` is the true #1 allocator.** Post the
  `dynamic_returns` dup fix, the faithful `:object` profile puts it at
  **19.2 % of all allocations** alone (≈34 % with `type_specifier_facts`,
  the sibling `StatementEvaluator` collector, and `flat_map`). `Kernel#dup`
  fell from 17 % → 1.2 %, confirming the dup fix held.

### Landed: lazy contribution accumulation

Both `collect_plugin_contributions` methods (MethodDispatcher +
StatementEvaluator) ran a `flat_map` that allocated a per-plugin
`contributions = []` *and* the flattened result on every dispatch, even
though almost every plugin contributes nothing for a given receiver. They
now accumulate lazily — allocate only when a contribution actually
appears, and share one frozen empty array otherwise. The callers treat
the result as read-only (`.empty?` / `Merger.merge`).

Clean faithful A/B (cwd = gitlab, plugins on, `--no-cache`):

| metric | before | after | Δ |
|---|--:|--:|--:|
| objects allocated | 347.3 M | **246.8 M** | **−29 %** |
| wall | 146.6 s | **143.2 s** | −2.4 % |
| GC runs | 402 | 385 | −4 % |
| diagnostics | 2,323 / 38 err | **2,323 / 38 err** | byte-identical |

The wall gain is modest relative to the allocation drop: the eliminated
objects are short-lived empty arrays, cheap to allocate and sweep. Still
a real −29 % allocation cut with `make verify` green.

## Still open

`collect_plugin_contributions` still **iterates all 11 plugins on every
dispatch** (the allocation is gone, but the iteration CPU — ~3.7 % self —
remains). Indexing plugins by their `dynamic_return(receivers:)` /
`type_specifier(methods:)` applicability — so only relevant plugins are
consulted per call — is the next lever, but it is a dispatch-path
redesign, not a local rewrite. The structural `Scope#rebuild` /
`CallContext` churn (carried over from the Mastodon note) also remains.

## Reproduction

Inside the Flake dev shell, from the rigor checkout, with a config whose
`paths:` point at the GitLab subset, `cache.path:` at a scratch dir, and
the 11 plugins listed:

```sh
# warm the cache once, then profile / account:
bundle exec exe/rigor check --config /tmp/rigor-gitlab.yml --workers 0 --format json >/dev/null
GEM_HOME=/tmp/rigor_gems gem install --no-document stackprof   # if absent
env GEM_PATH=/tmp/rigor_gems:$(ruby -e 'puts Gem.path.join(":")') \
  bundle exec ruby -I/tmp/rigor_gems/gems/stackprof-0.2.28/lib \
  /tmp/rigor_alloc_warm.rb /tmp/rigor-gitlab.yml          # mode: :object
bundle exec ruby /tmp/gl_gc.rb /tmp/rigor-gitlab.yml      # GC.stat A/B
```
