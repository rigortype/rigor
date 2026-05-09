# Opt-in Dependency-Source Inference

Status: **v0.1.3 in progress.** Slices 1, 2a, 2b-i, 2b-ii, 3,
4, and 5 of
[ADR-10](../adr/10-dependency-source-inference.md) have all
landed unreleased on `master`; ADR-10's implementation envelope
is complete. This document fixes the analyzer contract for the
delivered surface and names the open follow-ups still tracked
on ADR-10 § "Open questions".

The binding design surface is
[ADR-10](../adr/10-dependency-source-inference.md); the
release-by-release commitment envelope is in
[`docs/MILESTONES.md`](../MILESTONES.md). When this spec
disagrees with ADR-10, the ADR binds and this document is out of
date.

## Scope

Rigor's default inference boundary is RBS. Methods on a class
that has no signature (RBS / RBS::Inline / generated stub /
plugin contract) resolve to `Dynamic[top]` — the engine does not
walk third-party source. ADR-10 carves out a deliberate
exception: gems the user **opts into** via
`.rigor.yml`'s `dependencies.source_inference:` may have their
Ruby implementation walked by the same engine that walks
`paths:`. Inferences crossing the gem boundary are wrapped in
`Dynamic[T]` so the proof is treated as third-party rather than
authored.

The opt-in is per gem and orthogonal to `paths:` (the user's
own source) and `signature_paths:` / `libraries:` (the RBS
boundary). Gems not listed under `dependencies:` keep the
existing default.

## Configuration

```yaml
# .rigor.yml
paths:
  - lib

dependencies:
  source_inference:
    - gem: rack
      mode: when_missing
    - gem: faraday
      mode: when_missing
      roots: [lib]
    - gem: legacy-noop-gem
      mode: disabled
```

The shape is parsed by
[`Rigor::Configuration::Dependencies`](../../lib/rigor/configuration/dependencies.rb).
The JSON schema row at
[`schemas/rigor-config.schema.json`](../../schemas/rigor-config.schema.json)
mirrors the parser.

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `gem` | non-empty String | yes | — | Bundle-resolvable gem name. |
| `mode` | enum | no | `when_missing` | One of `disabled`, `when_missing`, `full`. |
| `roots` | Array&lt;String&gt; | no | `["lib"]` | Per-gem subdirectories the walker MAY visit. |
| `dependencies.budget_per_gem` | Integer | no | `5000` | Per-gem catalog cap (method-definition count). Range `1250 .. 20000` (0.25× – 4× of the default per ADR-10 § "Budget interaction"). When the walker hits the cap for a gem, harvesting stops and the runner emits a `dynamic.dependency-source.budget-exceeded` warning. |

### Modes

| Mode | Behaviour |
| --- | --- |
| `disabled` | Listed for documentation / future-toggle convenience. The {Builder} skips the entry before resolution; the gem contributes nothing. |
| `when_missing` | Walk gem source only when no signature contract is available for the receiver class / method pair. RBS / RBS::Inline / generated stubs / plugin contracts always win. **Recommended default.** |
| `full` | Always walk gem source even if RBS is also present. Reserved for cases where the user has decided gem source is more accurate than its bundled RBS; carries acknowledged churn risk per ADR-10 § "Decision". |

The dispatcher tier in v0.1.3 implements both `when_missing` and
`full` identically — both flow through the same
`try_dependency_source` site. Mode-distinguishing behaviour at
the dispatcher (e.g. `full` overriding RBS, RBS-conflict
diagnostics) is queued for a follow-up slice; the configuration
surface is fixed now so consumers can express the eventual
distinction without `.rigor.yml` rewrites later.

### Hard exclusions

Even when listed, the walker MUST skip:

- **C extensions and other non-Ruby sources.** Walker only loads
  `.rb` files; nothing else can reach the catalog.
- **Top-level `spec/` / `test/` / `bin/` roots.** Filtered before
  any filesystem walk runs by
  `DependencySourceInference::Walker::HARD_EXCLUDED_ROOTS`.
  Nested `spec/` / `test/` directories deeper inside `lib/` are
  NOT filtered (a few gems legitimately ship `lib/.../spec/`).
- **Files outside the gem's listed `roots:`.** The default is
  `lib/` only; the user MAY widen this per entry, but the
  walker never reads outside the listed roots.

The exclusions are baked into the loader; the user cannot
override them via configuration.

## Public-API drift surface

Every namespace below is locked by
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb).
Signature changes update the matching
`PublicApiDriftSnapshots::*` constant in the same commit.

| Surface | Module | Slice |
| --- | --- | --- |
| `Rigor::Configuration#dependencies` | Configuration | Slice 1 |
| `Rigor::Configuration::Dependencies` value object | Configuration | Slice 1 |
| `Rigor::Configuration::Dependencies::Entry` Data shape | Configuration | Slice 1 |
| `Rigor::Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM` / `MIN_BUDGET_PER_GEM` / `MAX_BUDGET_PER_GEM` | Configuration | Slice 4 |
| `Rigor::Configuration::Dependencies#budget_per_gem` | Configuration | Slice 4 |
| `Rigor::Analysis::DependencySourceInference` namespace | Analysis | Slice 2a |
| `Rigor::Analysis::DependencySourceInference::GemResolver.resolve` | Analysis | Slice 2a |
| `Rigor::Analysis::DependencySourceInference::Index` | Analysis | Slice 2a / 2b-i |
| `Rigor::Analysis::DependencySourceInference::Index#budget_exceeded` | Analysis | Slice 4 |
| `Rigor::Analysis::DependencySourceInference::Builder.build` | Analysis | Slice 2a |
| `Rigor::Analysis::DependencySourceInference::Walker.walk(budget:)` | Analysis | Slice 2b-i / 4 |
| `Rigor::Analysis::DependencySourceInference::Walker::Outcome` Data shape | Analysis | Slice 4 |
| `Rigor::Environment#dependency_source_index` | Environment | Slice 2b-ii |
| `Rigor::Cache::Descriptor::DependencyEntry` | Cache | Slice 3 |
| `Rigor::Cache::Descriptor#dependencies` slot | Cache | Slice 3 |
| `Rigor::Analysis::DependencySourceInference::Index#cache_descriptor` | Analysis | Slice 3 |

## Resolution and indexing (slice 2a)

`Analysis::Runner#run` builds a per-run
`DependencySourceInference::Index` once at run start, after
plugin loading and before per-file iteration:

```text
Configuration::Dependencies      ─┐
                                   │
Builder.build(dependencies)        ▼
                                  resolves entries via GemResolver
                                  walks resolved gems via Walker (slice 2b-i)
                                  returns frozen Index
```

`GemResolver.resolve(entry)` consults `Gem.loaded_specs[name]`
first and falls back to `Gem::Specification.find_by_name(name)`.

| Outcome | Meaning |
| --- | --- |
| `Resolved(gem_name:, version:, gem_dir:, mode:, roots:)` | RubyGems located the spec; `version` is the spec version as a String so it round-trips into cache descriptors. |
| `Unresolvable(gem_name:, reason: :not_in_bundle)` | Spec absent. The runner surfaces a `dynamic.dependency-source.gem-not-found` `:warning` diagnostic and the gem contributes nothing for the run. |

`Builder.build` partitions the entries: `Resolved` rows feed the
walker, `Unresolvable` rows surface as the diagnostic above.
Entries with `mode: :disabled` are skipped before resolution
(no missing-gem diagnostic for a deliberately-listed-and-off
gem).

`Index` exposes:

- `#resolved_gems` — Array of `Resolved`.
- `#unresolvable` — Array of `Unresolvable`.
- `#method_catalog` — flat
  `Hash{[class_name, method_name] => :instance | :singleton}`
  populated by the walker (slice 2b-i).
- `#contribution_for(class_name:, method_name:)` — returns the
  recorded kind or `nil`.
- `#empty?` — true when no resolved gems were registered.
- `#cache_descriptor` — frozen
  [`Cache::Descriptor`](cache.md) with one `DependencyEntry`
  per resolved gem (slice 3; see "Cache slice" below).

`Index::EMPTY` is the singleton frozen empty index used when no
gem opted in.

## Walker (slice 2b-i)

`DependencySourceInference::Walker.walk(gem_dir:, roots:)`
parses every `*.rb` file under each accepted root and returns a
flat catalog mapping `(class_name, method_name)` to the method
kind. The walker is decoupled from `Inference::Scope` because
gem-source inference runs without a scope context.

Recognition rules:

- `class Foo` / `module Bar` push `Foo` / `Bar` onto the
  qualified-name prefix and recurse into the body.
- `class << self` (only — `class << expr` for any other `expr`
  is treated as opaque) pushes a singleton-scope flag.
- `def foo` records `(Class, :foo, :instance)` (or
  `:singleton` under the singleton-scope flag).
- `def self.foo` records `(Class, :foo, :singleton)` regardless
  of the surrounding flag.
- Per-class first-write wins. Methods of identical name on the
  same class with different kinds (rare; private API mostly)
  carry the kind that wins the per-class first walk.

Per-file errors silently degrade to "no contribution from this
file":

- Files Prism cannot parse.
- Files that raise during `Prism.parse_file`.
- Files outside the gem's listed `roots:`.

Gem source we cannot walk MUST NOT pollute the user-facing
diagnostic stream — the user did not author the file and cannot
fix it.

## Dispatcher tier (slice 2b-ii)

`Inference::MethodDispatcher.dispatch` consults the index after
RBS dispatch fails and before the user-class fallback:

```text
constant-folding tier
shape / kernel / iterator / block-folding precision tiers
RbsDispatch.try_dispatch                              ── RBS / RBS::Inline / stub / plugin
                                                         ↓ (no contract)
try_dependency_source(receiver_type, method_name)     ── ADR-10 (this tier)
                                                         ↓ (no entry)
try_user_class_fallback                               ── Kernel / Module intrinsics
                                                         ↓
call.undefined-method                                 ── final
```

`try_dependency_source` returns `Type::Combinator.untyped` (i.e.
`Dynamic[top]`) when the receiver carries a `Type::Nominal` /
`Type::Singleton` whose class name + method name match a catalog
entry. The tier sits **strictly below plugins**: plugin
contracts still win on conflict per ADR-10 WD6 (plugins are
authored contracts; gem-source inference is opportunistic).

Slice 2b-ii deliberately stops at `Dynamic[top]`. Per-method
return-type precision (i.e. `Dynamic[T]` with a non-`top` static
facet) is queued for a later slice and does not yet surface
through the `try_dependency_source` envelope. The current
visible payoff is the absence of `call.undefined-method` on
opt-in-gem method calls whose receivers Rigor can recognise by
`Nominal[T]` (typically because the user authored an RBS
skeleton or because RBS resolved the constructor call).

## Budget enforcement (slice 4)

Per ADR-10 § "Budget interaction", each opt-in gem gets a
**separate budget pool** so a poorly-bounded gem cannot
starve the user's own analysis.

The unit is **method-definition count** harvested into the
catalog. Default `5000` covers every realistic opt-in target
(Rack ≈ 1500, Faraday ≈ 500, Sidekiq ≈ 800) while still
surfacing a diagnostic for ActiveSupport-class libraries
(~10 000+ methods) where the user should ship RBS or de-list
the gem instead. The configured value is bounded by the
`MIN_BUDGET_PER_GEM` (`1250`, 0.25× the default) and
`MAX_BUDGET_PER_GEM` (`20000`, 4×) constants.

### Walker-side cap (semantics α)

When `Walker.walk(gem_dir:, roots:, budget:)` reaches `budget`
catalog entries for a single gem, it stops harvesting:

- The current file's remaining `def` nodes are NOT recorded.
- Subsequent files (and roots) for the same gem are NOT
  visited.
- The Walker returns `Outcome.new(catalog: ..., truncated: true)`
  to signal the cap was hit.

The accumulated catalog stays valid; it just doesn't cover
the gem completely. For methods that **were** harvested
before the cap, the dispatcher tier behaves exactly as it
does for any other catalog hit (returns `Dynamic[top]`). For
methods that **weren't** harvested — i.e. those past the cap
— the dispatcher falls through to the existing user-class
fallback path: usually a `call.undefined-method` if the
receiver class is RBS-known but the method is not.

This is the **(α) semantics** from ADR-10 WD4: the budget
caps the harvest, not the dispatch. The richer (β) semantics
("any call on a budget-exceeded gem's class returns
`Dynamic[top]` regardless of catalog hit") would require a
class-to-gem reverse index on the {Index} and a dispatcher
branch consulting it; that follow-up is queued for a later
slice if the (α) experience surfaces a concrete need.

### Diagnostic emission

`Index#budget_exceeded` is the frozen Array of gem names that
tripped the cap during {Builder.build}. The runner consumes
this list once per run via
`#dependency_source_budget_diagnostics` and emits one
`dynamic.dependency-source.budget-exceeded` `:warning` per
listed gem. The diagnostic message names the gem, the
configured cap, and points the user at the three remediations
(ship RBS, reduce `mode:` from `full` to `when_missing`,
de-list).

The dedupe is per-gem, not per-call-site. A budget-exceeded
gem with hundreds of unrecorded methods produces exactly one
warning; the user does not have to suppress dozens of
identical messages.

## Cache slice (slice 3)

[`Rigor::Cache::Descriptor`](cache.md) gains a top-level
`dependencies:` slot carrying `DependencyEntry` rows:

```ruby
Rigor::Cache::Descriptor::DependencyEntry.new(
  gem_name: "rack",
  gem_version: "3.0.0",
  mode: :when_missing
)
```

| Field | Type | Notes |
| --- | --- | --- |
| `gem_name` | String | Bundle-resolvable name as declared in the entry. |
| `gem_version` | String | The `Resolved.version` for the run (a `Gem::Version` rendered to String). |
| `mode` | `:disabled` / `:when_missing` / `:full` | Mirrors {Configuration::Dependencies::VALID_MODES}. |

Composition (`Cache::Descriptor.compose`) groups by `gem_name`
and raises `Conflict` when two contributors disagree on
`gem_version` or `mode`. In a valid deployment Bundler installs
one version per gem and the parser produces one entry per gem,
so the conflict path is exceptional.

`Index#cache_descriptor` lifts every `Resolved` row into a
`DependencyEntry` and returns a frozen `Cache::Descriptor`
populated with the `dependencies:` slot. Cache producers that
observe ADR-10 inference outputs compose this descriptor with
their own (`RbsDescriptor`, plugin descriptors, file digests)
through `Cache::Descriptor.compose` so a `bundle update` on a
listed gem invalidates exactly that gem's slice while leaving
the rest of the cache hot.

`Unresolvable` entries contribute nothing — they have no version
to key on, and the runner already surfaces them as
`dynamic.dependency-source.gem-not-found` diagnostics.
Resolved-but-disabled entries are filtered upstream by the
{Builder} and never reach the index.

`Cache::Descriptor::SCHEMA_VERSION` was bumped to 2 with this
slice because adding a top-level slot to the canonical-hash
shape is an incompatible change per the constant's documented
contract; the bump triggers `Cache::Store#ensure_schema_version!`
to wipe the cache root on first run after upgrade so stale-shape
entries don't linger as orphans.

The slice 3 envelope lands the **primitive** for per-gem-version
invalidation. Cache producers that route ADR-10 inferences
through `Store#fetch_or_compute` are queued for slice 4
alongside the per-gem budget machinery.

## Diagnostic family

Every diagnostic emitted on the dependency-source path uses the
`dynamic.dependency-source.*` prefix per
[`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
§ "Diagnostic identifier taxonomy".

| Rule | Severity (authored) | Status | Meaning |
| --- | --- | --- | --- |
| `dynamic.dependency-source.gem-not-found` | `:warning` | Live (slice 2a) | Listed gem was not resolvable through RubyGems. Run continues; gem contributes nothing. |
| `dynamic.dependency-source.budget-exceeded` | `:warning` | Live (slice 4) | Per-gem budget tripped. Walker stopped harvesting at `dependencies.budget_per_gem` method definitions; remaining sites resolve through the existing RBS-or-`Dynamic[top]` boundary. Emitted at most once per gem per run. Recommendation: ship RBS, reduce mode from `full` to `when_missing`, or delist the gem. |
| `dynamic.dependency-source.boundary-cross` | `:info` | **Pending (post-slice-4)** | Plugin contract and gem-source inference disagree on a return type. The plugin wins; the diagnostic surfaces the divergence for audit. |
| `dynamic.dependency-source.config-conflict` | `:error` | **Pending (post-slice-4)** | `.rigor.yml` parse / merge produced two incompatible entries for the same gem (e.g. across `includes:`). The configured profile re-stamps severity per the active severity profile; the authored severity is the one above.

The taxonomy row in
[`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
already covers the `dynamic.dependency-source.*` family — no
spec amendment is required as new rules in the family ship.

## Boundary contracts

### With ADR-2 (trusted-gem trust model)

Listing a gem under `source_inference` is a **read-only** trust
grant. Rigor parses the gem's Ruby files and runs them through
the analyzer; it does NOT load or execute their code.
ADR-2 § "Plugin Trust and I/O Policy"'s "plugins must not
execute application code" rule applies verbatim. Network access
stays disabled; file reads stay scoped to the gem's `roots:`.

### With ADR-5 (Robustness Principle)

[`docs/type-specification/robustness-principle.md`](../type-specification/robustness-principle.md)
asks Rigor-authored types to be strict on returns. Gem-source
inference produces narrow returns by accident — the inferred
return reflects the implementation today, not the contract the
gem author would have committed to.

The tension is resolved by **never publishing the narrow
inferred type as if it were authored**. Gem-inferred returns
are wrapped in `Dynamic[T]`. The wrapper preserves
gradual-consistency semantics across typed boundaries while
blocking silent reliance on accidental narrow inferences. RBS
erasure ([`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md))
exports `Dynamic[T]` as `untyped`; the static facet `T` does
not leak into authored signatures.

### With ADR-9 (cross-plugin API)

Plugin authors cannot today veto gem-source inference for
receivers they own. ADR-10 § "Open questions" identifies this
as a likely follow-up — `Plugin::Base#owns_receiver?` or a
`manifest` field — but defers the design until at least one
plugin needs it. The dispatcher tier ordering makes the absence
benign for now: plugins are consulted before the
dependency-source tier, so a plugin that happens to own a
receiver class still wins on conflict.

## Stability

The surfaces named in "Public-API drift surface" above are
stable as of v0.1.3 unreleased on `master` and locked by the
drift spec. ADR-10's five-slice implementation envelope is
complete; further work is tracked under "Open questions"
below.

## Open questions

Tracked on [ADR-10](../adr/10-dependency-source-inference.md)
§ "Open questions" — revisited as concrete needs surface:

- **Per-receiver plugin veto** — ADR-9 manifest field or
  `Plugin::Base#owns_receiver?` so plugins can veto
  gem-source inference for receivers they own (e.g.
  `rigor-activerecord` vetoing `ActiveRecord::Base`
  subclasses to avoid collisions with plugin-generated
  members).
- **`mode: full` retention** — the dispatcher tier in v0.1.3
  treats `full` and `when_missing` identically. The
  authoring distinction stays in the configuration surface
  to avoid churn if `full`-distinguishing dispatch lands
  later.
- **Cache size cap (`dependencies.cache_size`)** — per ADR-10
  WD5 the cache slice is per-(gem, version, mode); a global
  size cap is deferred until the cache backend shows growth
  issues during dogfooding.
- **Configurable dispatcher tier ordering** — for users who
  want plugin output to yield to gem source in narrow cases.
  Default: no, but revisit after the first concrete user
  request.
- **Richer (β) budget semantics** — class-to-gem reverse
  index + dispatcher branch so all calls on a budget-
  exceeded gem's class return `Dynamic[top]` regardless of
  catalog hit. Slice 4 ships the (α) Walker-side cap; the
  (β) extension lives behind a concrete user need.
- **`dynamic.dependency-source.boundary-cross` diagnostic** —
  surfaces RBS-vs-gem-source disagreement on the same
  receiver / method. Useful for `mode: full` audits; lands
  alongside the `full` dispatcher distinction.
- **`dynamic.dependency-source.config-conflict` diagnostic** —
  surfaces `.rigor.yml` parse / merge disagreement (two
  incompatible entries for the same gem across `includes:`).
  Lands alongside the configuration loader's `includes:`
  audit work.
