# ADR-10 — Opt-in dependency-source inference

Status: **proposed, 2026-05-09.** Design fixed here so v0.1.x core
work can refer to it; implementation queued behind ADR-9 Track 2
in `docs/MILESTONES.md` (target: v0.1.3 or later — not committed
to a specific release yet).

## Context

The current default treats RBS as Rigor's outer inference
boundary. Per
[`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md)
§ "Boundary contracts" and
[ADR-2 § "Plugin Trust and I/O Policy"](2-extension-api.md), the
analyzer:

- accepts a method's signature (inline `#:`, `# @rbs`, generated
  stub, or external `.rbs`) as a **cutoff**: callers reuse the
  declared return and recursive return inference stops at the
  method boundary;
- otherwise falls back through the budget machinery and
  ultimately to `Dynamic[top]`.

For project source (the files under `paths:` in `.rigor.yml`)
the analyzer walks every method body. For everything outside
that — third-party gems, vendored sources — there is no walk.
Methods on a gem class without RBS resolve to `Dynamic[top]`
and the user is expected to either (a) ship RBS, (b) author a
plugin, or (c) accept the dynamic envelope.

This boundary is the right default for soundness, performance,
and stability of the third-party contract surface. But it has
two concrete pain points the user surfaced:

1. **The "no-RBS gem" cliff.** A small utility gem with no RBS
   could often be inferred as well as the user's own code if
   the analyzer were allowed to read its source. Today it
   degrades straight to `Dynamic[top]`, even though the source
   is sitting in the bundle.
2. **The handcrafted-RBS overhead is asymmetric.** For a
   metaprogramming-light gem, writing RBS by hand (or generating
   it through `rbs prototype`) duplicates information that
   Rigor's own engine could extract directly.

The user's proposal: **for gems that ship no RBS or RBS::Inline
sources, allow Rigor to walk their Ruby implementation as a
type source — same engine, same rules — instead of degrading
to `Dynamic[top]` at the dependency boundary.**

This ADR records the design decision: **adopt the proposal as
opt-in per gem, not as a default behaviour change.** The
remainder of the document fixes the contract, the budget /
cache / provenance interactions, and the boundary with ADR-2's
trusted-gem policy.

## Decision

Add a new `dependencies:` configuration axis to `.rigor.yml`
that names gems whose source Rigor MAY walk during inference.
The axis is **opt-in per gem** and orthogonal to `paths:` (what
the user wrote) and `signature_paths:` / `libraries:` (the RBS
boundary). Gems not listed under `dependencies:` keep the
existing behaviour: RBS or nothing.

```yaml
# .rigor.yml
paths:
  - lib

dependencies:
  source_inference:
    - gem: rack
      mode: full         # walk every Ruby file in the gem
    - gem: faraday
      mode: when_missing # walk only when no RBS exists for the call site
```

Three named modes are accepted; further modes require an ADR
amendment:

| Mode | Behaviour |
| --- | --- |
| `disabled` (default for unlisted gems) | Existing RBS-or-`Dynamic[top]` behaviour. Gems not in the list are this mode. |
| `when_missing` | Walk gem source ONLY when no signature contract is available for the receiver class / method pair. RBS / RBS::Inline / generated stubs / plugin contracts always win. |
| `full` | Always walk gem source even if RBS is also present. The inferred type and the RBS contract are reconciled with the contribution-merging rules in ADR-2 § "Plugin Contribution Merging" — RBS remains authoritative on conflict. |

`when_missing` is the recommended default for ordinary opt-ins.
`full` exists for cases where the user has decided gem source
is more accurate than its bundled RBS (rare, intentional, with
acknowledged churn risk).

### Inference contract

When a call site resolves to a method on a gem listed under
`dependencies:` and the mode permits walking the gem's source:

- The analyzer walks the gem's `.rb` files using the same
  engine that walks `paths:`. Method dispatch, narrowing, fact
  store, and budget enforcement run unchanged.
- Inferred return types crossing the gem boundary are **wrapped
  in `Dynamic[T]`** per
  [`docs/type-specification/special-types.md`](../type-specification/special-types.md)
  § "Dynamic-origin and unchecked information". The static
  facet `T` is the inferred type; the dynamic-origin marker
  preserves the fact that the proof came from third-party
  source rather than from a contract the gem author committed
  to.
- Diagnostics emitted on this path use the
  `dynamic.dependency-source.*` prefix family
  ([`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
  § "Diagnostic identifier taxonomy" gains a new entry — see
  "Public-API drift surface" below).
- Budget exhaustion in gem walks falls back to `Dynamic[top]`
  exactly like project-source walks. Gem walks do **not**
  silently emit a fabricated precise type when their budget
  trips.

This wrapping is what makes the design safe: a consumer that
reads `Dynamic[Integer]` from a gem method does not get to
treat it as ground-truth `Integer`. They get a value with the
gradual-consistency rules from
[`docs/type-specification/value-lattice.md`](../type-specification/value-lattice.md)
§ "Dynamic-origin algebra" — usable across typed boundaries
but with provenance retained for diagnostics. If the gem's
implementation later returns a wider value than today's
inference admits, the wrapper absorbs the divergence rather
than the user's call site silently breaking.

### Hard exclusions

Even with `dependencies.source_inference` listing a gem,
Rigor MUST skip:

- **C extensions and other non-Ruby sources.** No source = no
  walk. The gem's RBS (if any) remains the only contract.
- **Files that are themselves loaded only through DSL
  metaprogramming** that a registered plugin claims ownership
  of (e.g. ActiveRecord-generated attribute methods owned by
  `rigor-activerecord`). Plugins keep their existing precedence
  per ADR-2 § "Plugin Contribution Merging".
- **Files outside the gem's `lib/` directory** by default
  (`spec/`, `test/`, `bin/`, top-level scripts). Gems that need
  another root listed can supply `roots:` per entry, but the
  default is `lib/` only.

The exclusions are baked into the loader; the user cannot
override them via configuration.

### Cache and invalidation

Gem-source inference results are cached using ADR-6's existing
sharded persistence backend, with a per-(gem-name,
gem-version, mode) descriptor entry:

- Cache key includes `(gem_name, gem_version, source_inference_mode)`
  plus the existing analyzer / RBS environment fingerprints.
- A `bundle update` that changes a listed gem's pinned version
  invalidates exactly that gem's slice of the cache. Other
  gems' slices and the user's project slice remain valid.
- A change to `dependencies.source_inference` itself
  invalidates the union of currently-listed and previously-listed
  gems (the comparison is part of the
  `Cache::Descriptor::ConfigEntry` already in use).

`Cache::Descriptor::PluginEntry` does not need to grow a new
field; gem-source inference is core, not a plugin
contribution. A new `Cache::Descriptor::DependencyEntry` value
object carries `(gem_name, gem_version, mode)` and slots into
the descriptor next to the existing `gems:` slot
([ADR-2 § "Cache dependencies should be explicit
descriptors"](2-extension-api.md)).

### Budget interaction

Gem-source walks consume a **separate budget pool per gem**, not
the project-wide pool. A poorly-bounded gem cannot starve the
user's own analysis:

- New `.rigor.yml` budget key `dependencies.budget_per_gem`
  (default 100% of the existing
  `Configuration::DEFAULTS.budgets.call_graph_width`-equivalent;
  range 0.25× – 4×). Each opt-in gem gets one allotment.
- When a gem's budget trips, that gem's remaining call sites
  fall back to `Dynamic[top]` and a single
  `dynamic.dependency-source.budget-exceeded` diagnostic
  reports the gem name and the recommendation: ship RBS, or
  reduce the gem's mode from `full` to `when_missing`, or
  delist the gem.

The exact budget table additions are left to the implementing
slice; the constraint is that gem walks MUST be bounded
independently of the user's call graph.

### Boundary with ADR-2 (trusted-gem model)

ADR-2 § "Plugin Trust and I/O Policy" already establishes that
**plugins** are trusted Ruby gems selected by the user's
`Gemfile` and `.rigor.yml`. This ADR extends the same trust
model to non-plugin gems listed under
`dependencies.source_inference`:

- Listing a gem under `source_inference` is a **read-only**
  trust grant. Rigor parses the gem's Ruby files and runs them
  through the analyzer; it does NOT load or execute their
  code. The "Plugins must not execute application code" rule
  applies verbatim to gem-source inference.
- Network access stays disabled per ADR-2.
- File reads stay scoped to the gem's `roots:` (default `lib/`).
  Read attempts outside that scope are loader errors, not
  silent successes.

### Boundary with the Robustness Principle (ADR-5)

[`docs/type-specification/robustness-principle.md`](../type-specification/robustness-principle.md)
asks Rigor-authored types to be **strict on returns, lenient on
parameters**. Gem-source inference on someone else's
implementation produces **narrow** returns by accident — the
inferred return reflects the implementation today, not the
contract the gem author would have committed to.

This ADR resolves that tension by **never publishing the
narrow inferred type as if it were authored**:

- Gem-inferred return types are wrapped in `Dynamic[T]`. The
  `T` carries today's narrow shape; the wrapper is what the
  consumer's call site actually sees.
- RBS erasure on Rigor-authored signatures continues to honour
  the Robustness Principle. Gem-inferred shapes never round
  trip out as authored RBS — they remain analysis-time
  inferences only.

The Robustness Principle still binds Rigor's own outputs. It
does not retroactively bind shapes inferred from gem source
the user opted into.

## Public-API drift surface

This ADR adds:

- `Rigor::Configuration#dependencies` (new attr_reader; new
  `Configuration::Dependencies` value object carrying
  `source_inference: [Configuration::Dependencies::Entry]`).
- `Rigor::Configuration::Dependencies::Entry` (new frozen
  Data: `gem:`, `mode:`, optional `roots:`).
- `Rigor::Cache::Descriptor::DependencyEntry` (new frozen
  Data: `gem_name:`, `gem_version:`, `mode:`).
- `Rigor::Analysis::DependencySourceInference` (new
  namespace; module-level walker that re-uses
  `Rigor::Analysis::Runner` machinery against a gem's
  `roots:`).
- New diagnostic prefix family
  `dynamic.dependency-source.*`. Initial entries:
  `dynamic.dependency-source.budget-exceeded`,
  `dynamic.dependency-source.boundary-cross`,
  `dynamic.dependency-source.config-conflict`. The taxonomy
  table in
  [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
  gains a row for the family.
- New configuration schema entry under `.rigor.yml` (and the
  bundled JSON schema): `dependencies.source_inference[]`
  with `gem`, `mode` (enum: `disabled` / `when_missing` /
  `full`), and optional `roots`.

All updates land in `spec/rigor/public_api_drift_spec.rb` in
the same commit as the implementation slice that introduces
each surface.

## Implementation slicing

Recommended order; each slice independently shippable. Slices
1 – 3 deliver a usable feature; slices 4 – 5 are polish and
can defer.

1. **Configuration plumbing.**
   `Configuration::Dependencies::Entry`, parser, drift
   snapshot, JSON schema entry. No analyzer wiring yet —
   loading a config with `dependencies.source_inference`
   succeeds, but inference still treats listed gems as the
   default RBS-or-`Dynamic[top]` boundary.
2. **Walker + dispatch tier.**
   `Analysis::DependencySourceInference` walks listed gems'
   `lib/` and contributes inferred return types as
   `Dynamic[T]` through the same `flow_contribution_for`
   substrate plugins use today (ADR-9 Track 2 slice 7 wired
   the dispatcher tier). New tier ordering: core RBS >
   `RBS::Extended` > plugins > **dependency-source inference**
   > engine fallback. Lower than plugins because plugins are
   authored contracts; gem-source inference is opportunistic.
3. **Cache descriptor + invalidation.**
   `Cache::Descriptor::DependencyEntry` lands in the
   descriptor. `bundle update` on a listed gem invalidates
   exactly that gem's slice.
4. **Per-gem budget + budget-exceeded diagnostic.**
   `dependencies.budget_per_gem` config entry, separate budget
   pool per gem, `dynamic.dependency-source.budget-exceeded`
   emission.
5. **Documentation update.**
   New `docs/internal-spec/dependency-source-inference.md`
   normative document. Cross-links from
   `inference-budgets.md`, `special-types.md`,
   `diagnostic-policy.md`. End-user handbook chapter optional
   (defer until at least one Tier-2 user gem ships an
   opt-in recommendation).

## Working decisions

### WD1 — Why opt-in, not opt-out?

Opt-out (default = walk every gem unless excluded) was
considered and rejected:

- **Surface area.** A typical Rails app's bundle is hundreds
  of gems. Walking them all explodes the analysis budget and
  the cache footprint, even with per-gem budget caps.
- **Stability.** Inferred types from gem source change with
  every patch release. An opt-out default would hand users
  a long tail of false-positive churn on `bundle update`.
- **Consent.** ADR-2's trust model is explicit: the user
  selects which gems Rigor reads. Opt-out would invert that
  for source inference but not for plugins, which is
  inconsistent.

Opt-in keeps the default behaviour identical (RBS-or-nothing)
and lets the user grow into the feature gem by gem, paying
budget cost only where they want it.

### WD2 — Why `Dynamic[T]` rather than ground-truth `T`?

The wrapper preserves provenance. A consumer that needs to
treat the value as `Integer` for narrowing already has
gradual-consistency rules that admit `Dynamic[Integer]`
across the boundary. The wrapper does not block normal use;
it only blocks **silent reliance on accidental narrow
inferences** that may not survive a gem patch release. See
the boundary discussion with ADR-5 above.

If users want ground-truth precision from a gem they trust,
they can ship RBS for it (the existing path). The
gem-source-inference path is for gems where ground-truth
RBS doesn't exist and the user is willing to accept
provenance-tagged dynamic returns.

### WD3 — Why exclude `spec/`, `test/`, `bin/` by default?

Most Ruby gems' `lib/` is the public surface. Test code
references `RSpec`, `Minitest`, `Test::Unit`-style globals
that the analyzer does not recognise without test-framework
plugins, and walking it would produce a flood of
`call.undefined-method` noise. Top-level scripts often
require runtime context (`bundle/setup`, `ARGV`, ENV) that
makes their inferences brittle.

Users who genuinely want a non-`lib/` root inferred can list
`roots:` per entry. The default stays narrow.

### WD4 — Why a separate budget pool per gem?

A shared pool would let one badly-shaped gem starve the
user's own analysis. Per-gem pools cap the worst-case
contribution of any single opt-in: when a gem trips its
budget, the user gets `Dynamic[top]` for that gem only and
a single diagnostic naming it. The user's own `paths:` walk
proceeds unaffected.

### WD5 — Cache descriptor scope: per-gem-version

A cache slice keyed on `(gem_name, gem_version, mode)` lets
`bundle update` invalidate exactly the affected gems. A
broader key (e.g. `Gemfile.lock` digest) would invalidate
every gem's slice on any single gem upgrade — fine for
correctness, wasteful for incremental rebuilds in a Rails
monorepo. The narrow key matches ADR-2 § "Cache invalidation
needs a declarative API".

### WD6 — Gem walks land at a tier strictly below plugins

Plugins are authored contracts: a plugin author commits to a
shape. Gem-source inference is opportunistic: the gem author
made no such commitment. The dispatcher tier order (core RBS
> `RBS::Extended` > plugins > dependency-source inference >
engine fallback) reflects that. A plugin that contradicts
the gem's inferred return wins; the analyzer reports the
divergence as `dynamic.dependency-source.boundary-cross` so
the user can audit it.

### WD7 — Gem-inferred shapes never round-trip out as RBS

[`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md)
governs Rigor → RBS export. Gem-inferred shapes are
**internal** facts. They are never erased to authored RBS,
because the gem's author has not committed to that shape.
The `Dynamic[T]` wrapper exports as `untyped` per the
existing erasure contract; the static facet `T` does not
leak into authored signatures.

This is the same rule that protects plugin-derived dynamic
members from being exported as authored RBS without the
plugin author's intent.

## Alternatives considered

- **Walk every gem in the bundle by default** (opt-out). See
  WD1.
- **Walk only when no RBS exists, project-wide, no
  per-gem opt-in.** Rejected: the user loses control over
  which gems pay budget cost. Patch-release churn surfaces
  silently. The Robustness-Principle violation surfaces
  silently.
- **Treat gem source as a plugin-style contribution.**
  Rejected: it is core engine work, not framework-shaped.
  Forcing it through the plugin contract would either bloat
  the plugin surface or duplicate the engine.
- **Cache `Gemfile.lock` digest as the granularity.**
  Rejected per WD5.
- **Round-trip gem-inferred shapes back out as authored
  RBS.** Rejected per WD7 — would cement accidental
  inferences as if the gem author wrote them, then break on
  patch updates.

## Open questions

- Should the dispatcher tier ordering be configurable
  per-project, e.g. for users who want plugin output to
  yield to gem source in narrow cases? Default: no, but
  revisit after the first concrete user request.
- Should `mode: full` be allowed at all, or should we ship
  with only `disabled` and `when_missing` and add `full`
  later? Decision deferred to slice 2 — start with both,
  retract `full` if no concrete use case lands.
- Should the budget table grow a `dependencies.cache_size`
  cap so an opt-in monorepo doesn't blow the cache backend?
  Decision deferred to slice 3 — only add if the cache
  shows growth issues during slice 2 dogfooding.
- Should plugin authors get a hook to **veto** gem-source
  inference for receivers they own (e.g. `rigor-activerecord`
  vetoing inference of `ActiveRecord::Base` subclasses to
  avoid colliding with plugin-generated members)? Likely yes,
  via a new `Plugin::Base#owns_receiver?` or a `manifest`
  field. Decision deferred to slice 2 — wire after the
  walker exists; specify as a follow-up ADR amendment if the
  need is concrete.

## Revision history

- 2026-05-09 — initial proposal. Triggered by user request
  to relax the RBS-only outer boundary for gems without
  signature sources.
