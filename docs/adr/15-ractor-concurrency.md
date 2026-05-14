# ADR-15 — Ractor-based concurrency model for the analyzer

Status: **proposed, 2026-05-14.** Phases 1 and 2a landed
incrementally before this ADR was written; the ADR formalises
the commitment so phases 2b–4 land against a stable contract.
ADR-12 (dry-rb packaging) still holds its reserved slot;
this ADR is independent of it.

## Context

Rigor's analyzer is CPU-bound Ruby. As of v0.1.4 the warm-
cache `rigor check lib` profile (157 files, stackprof
`wall(1000)`, 1340 samples) breaks down as:

| Phase | Wall share | Notes |
| --- | --- | --- |
| Inference (`ExpressionTyper#type_of`, `MethodDispatcher.dispatch_precise_tiers`) | ~50% | The analyzer's main job |
| `Marshal.load` (cache hits at startup) | 22.5% | RBS env / instance_defs / singleton_defs deserialisation |
| GC (mark + sweep) | ~15% | Ruby standard overhead |
| Prism parse | ~3% | Already fast |
| Misc (file walk, CheckRules orchestration, plugin hooks) | ~9% | Per-file ceremony |

Two infrastructure changes already landed:

- **`Cache::Store` thread-safety** (commit `31e95c8`) — a re-
  entrant `Monitor` guards `@memo` plus the hit / miss /
  write counters, so concurrent workers can share one Store
  without races.
- **`Cache::Store` in-process memo** (commit `5c30b37`) — the
  in-memory layer collapses repeated `(producer_id, key)`
  cache hits to one `Marshal.load` per process. The
  RSpec-side win was 6× (162s → 27s with `parallel_tests`);
  for single-shot CLI the layer is dormant because each
  producer is consulted once.

Multi-core utilisation was prototyped via Thread-based file
parallelism (`Runner#analyze_files` dispatching across a
worker pool). The result was **negative**: at
`RIGOR_WORKERS=4` wall-clock grew from 1.85s to 2.15s on a
12-core machine. Ruby's GVL serialises CPU-bound work and
the analyzer is overwhelmingly CPU-bound; thread coordination
overhead exceeded the (zero) GVL-released gains. The code was
reverted; the finding is recorded in `docs/CURRENT_WORK.md`
Open Items #7.

The only viable paths to multi-core utilisation in MRI Ruby
4.x are:

1. **Fork-based workers** — independent processes coordinated
   by the parent. Bypasses the GVL entirely. Per-process
   startup cost (~50-100ms on macOS) plus the per-process
   `Environment` rebuild bound the speedup envelope; nets
   out positive only for projects with hundreds of files or
   multi-second analysis tails.
2. **Ractors** — share-nothing concurrency primitive that
   bypasses the GVL while preserving in-process memory
   semantics. Stable in Ruby 3.x+ and Ruby 4.x. The strict
   shareability constraint (every object crossing a Ractor
   boundary MUST be `Ractor.shareable?`) makes the whole-
   analyzer adoption non-trivial.

ADR-15 commits to **Ractors as the primary concurrency
direction**. Fork-based workers are not excluded — they could
land first as a quick win for large projects — but the
long-term shape this ADR pins is Ractor-based.

## Goals

- **Wall-clock parallelism** on warm-cache `rigor check`
  scaling with available CPU cores. Target: projects with
  100+ files see ≥3× speedup at 4 workers; small projects
  pay no worse than 1.05× (worker startup overhead
  amortised).
- **No correctness regressions.** Diagnostic output stays
  deterministic regardless of completion order. Plugin
  contracts continue to honour their published behaviour.
- **Incremental adoption.** Each migration phase ships
  independently and is independently revert-able. The
  audit-spec
  ([`spec/rigor/ractor_readiness_spec.rb`](../../spec/rigor/ractor_readiness_spec.rb))
  is the contract between phases.
- **Daemon / watch-mode readiness.** The shape that supports
  Ractor-isolated workers also supports a long-lived
  `Analysis::Runner` instance handling repeated `run` calls
  (LSP, watch mode, future `rigor server`) without rebuilding
  RBS state per call. The `Cache::Store` in-process memo
  already implements half of this; the Environment split
  finishes it.

## Non-Goals

- **Forcing Ractor-based execution as the default.** Phase 4
  ships as opt-in (env var / config flag); the sequential
  path stays the default. Ractor execution becomes default
  when the published example plugins are all Ractor-tested
  and the worker pool's startup cost is verified low.
- **Process-pool integration.** Fork-based workers are
  tracked separately in `docs/CURRENT_WORK.md` Open Items
  #7. The two paths can coexist; this ADR does not commit
  one way or the other on the fork path.
- **Pure-Ractor refactor of the entire codebase.** Mutable
  in-process state stays where it belongs (e.g., per-Ractor
  inference caches). The split is "frozen reflection layer
  shared + per-Ractor mutable cache layer", NOT "everything
  immutable everywhere."

## Decision

Rigor adopts Ractor-based concurrency along the four-phase
migration documented in
[`docs/design/20260514-ractor-migration.md`](../design/20260514-ractor-migration.md):

1. **Phase 1 — value-object shareability (LANDED).** Every
   leaf carrier the engine sends through dispatch is
   `Ractor.shareable?` at construction time. Coverage:
   `Type::*` (16 classes), `TypeNode::*` (7 classes),
   `Cache::Descriptor`, `Analysis::FactStore`,
   `FlowContribution`. Regression guard in
   [`spec/rigor/ractor_readiness_spec.rb`](../../spec/rigor/ractor_readiness_spec.rb).
2. **Phase 2a — `Configuration` deep-freeze (LANDED).**
   `Configuration#initialize` freezes its `@paths` Array
   and calls `freeze` on `self`. Two-line change, no
   behaviour shift.
3. **Phase 2b — Environment / RbsLoader split (LANDED).**
   New `Rigor::Environment::Reflection` value object holds
   the loader's read-only RBS query surface (5 frozen
   tables + ancestor names) and answers `class_known?` /
   `instance_definition` / `singleton_definition` /
   `class_type_param_names` / `constant_type` /
   `class_ordering` from pure Hash / Set lookups.
   `RbsLoader#reflection` builds + memoises one; the new
   `Environment#reflection` delegates. Reflection is
   `frozen?` but NOT `Ractor.shareable?` (see WD6 below).
   Each Ractor worker (Phase 4) builds its own Reflection
   from the shared `Cache::Store`; Reflection itself does
   NOT cross Ractor boundaries.
4. **Phase 3 — plugin contract (Phase 3a LANDED).**
   `Plugin::Blueprint` (new) is a frozen, Ractor-shareable
   replay descriptor carrying `klass_name` + deep-frozen
   `config`. `Plugin::Registry` now exposes `blueprints` as
   an aligned, Ractor-shareable `Array<Blueprint>` and adds
   `Registry.materialize(blueprints:, services:)` that builds
   a fresh registry by replaying each blueprint via
   `Object.const_get + klass.new + #init(services)`. Plugin
   gems are required from the main Ractor BEFORE any worker
   spawns, so blueprint resolution succeeds inside workers
   without re-loading gems. Plugin INSTANCES intentionally
   stay non-shareable — they accumulate per-run state in
   ivars (`rigor-sorbet`'s `@reachable_absurd_nodes` /
   `@reveal_type_calls` / `@assert_type_mismatches` are the
   canonical examples). The Phase 4 worker pattern is:
   ship blueprints across the boundary, materialise once
   per worker, never share instances. Phase 3b (cross-
   Ractor plugin aggregate state — see § OQ2) is deferred
   until Phase 4 measures actual usage.
5. **Phase 4 — Ractor worker pool.**
   `Analysis::Runner#analyze_files` dispatches across a
   `Ractor.new`-allocated pool sharing the frozen
   `Environment`. Result re-assembly preserves original
   path order so the diagnostic stream stays deterministic.
   Decomposed into three sub-phases (full plan in
   [`docs/design/20260514-ractor-migration.md`](../design/20260514-ractor-migration.md)
   § Phase 4):
   - **Phase 4a (LANDED)**: `Analysis::WorkerSession` value
     carrier. Per-worker substrate that takes
     `Ractor.shareable?` inputs (`Configuration`,
     `cache_store`, `Array<Plugin::Blueprint>`) and builds
     its own plugin services + materialised registry +
     `DependencySourceInference::Index` + `Environment` +
     per-session `RbsExtended::Reporter` +
     `BoundaryCrossReporter`. `#analyze(path)` is the
     equivalent of `Runner#analyze_file`. NO Ractor in the
     loop yet — the substrate exists so the per-worker
     ownership boundary is testable in isolation.
   - **Phase 4b (LANDED)**: `Runner` gains a `workers: N`
     constructor keyword (default `0` = sequential). When
     `N > 0`, per-file analysis dispatches across N Ractors
     each running a WorkerSession. Workers write back via
     `Ractor.main.send` (Ruby 4.0+ mailbox model — yield
     was removed). Coordinator merges per-worker reporters
     and re-orders diagnostics by original path order.
     `Environment::ClassRegistry.default` made
     `Ractor.make_shareable` so workers can read it without
     `Ractor::IsolationError`. The CLI surface remains
     untouched — `workers:` is a programmatic opt-in only
     in this slice. Phase 4c wires the user-facing flag.
   - **Phase 4c (LANDED)**: `Configuration#parallel_workers`
     (default `0`) reads `.rigor.yml` `parallel.workers:`;
     the CLI's `--workers=N` flag and `RIGOR_RACTOR_WORKERS`
     env var override it. Precedence: CLI > env > config >
     `0`. Default remains sequential — pool mode stays
     opt-in until the worker-side env-build stability work
     (Phase 4b.x; see § "Known limitations" below) lands.
     Pool spec gated behind `RIGOR_INCLUDE_RACTOR_POOL=1`
     so default `make verify` is deterministic; `make
     test-ractor-pool` runs it in isolation.

The audit-spec at
[`spec/rigor/ractor_readiness_spec.rb`](../../spec/rigor/ractor_readiness_spec.rb)
is the contract between phases. Adding a new value-object
class without writing the matching `Ractor.shareable?`
assertion is a regression.

## Reference: the share boundary

Ractors require every object that crosses a Ractor boundary
to be `Ractor.shareable?` — frozen + every field shareable
recursively. The split this ADR commits to is:

- **Frozen surface** — everything callers Ractor-send must
  be in this surface. Configuration, Environment (after
  Phase 2b), Scope (after Phase 2b), and every value-
  object Carrier ride here.
- **Per-Ractor mutable surface** — caches, memoisation
  tables, plugin per-run state. Each Ractor owns its own;
  the data never crosses a Ractor boundary as state. Only
  derived shareable values (e.g. a frozen `RBS::Definition`
  loaded once and shared) cross.
- **Cross-Ractor shared mutable surface** — exactly one
  class: `Cache::Store`. The Monitor + memo layer make
  shared access safe. The Store's underlying disk is
  durable across Ractor lifetimes (and across process
  lifetimes), so the per-Ractor cache layer above warms
  from a single shared substrate.

## Working decisions

### WD1 — Why Ractors, not fork?

Both bypass the GVL. The trade-offs:

| Aspect | Ractors | Fork |
| --- | --- | --- |
| Setup cost | Per-Ractor (~10ms) | Per-fork (~50-100ms on macOS, lower on Linux) |
| Memory | Shared frozen surface, per-Ractor mutable | Copy-on-write (Linux) / full copy (macOS) |
| Coordination | `Ractor.yield` / `Ractor.send` / `Ractor.take` | Pipes + serialisation |
| Plugin shape change | One-time refactor (Phase 3) | Plugins survive intact (separate process) |
| Daemon / watch-mode reuse | Direct (Ractor pool persists) | Each request forks fresh |
| Determinism | Strong (shareable contract enforces it) | Strong (serialised IPC) |
| MRI maturity in 4.x | Stable, with caveats on shareability | Stable, with macOS overhead |

For Rigor's specific shape — a single Environment shared
across all files, per-file dispatch that's stateless given
that Environment — Ractors are a closer fit: the share-
nothing boundary is exactly where rigor's data already wants
to be split. Fork would force per-process Environment
rebuild every run, eliminating the cache-warmed-once benefit
the in-process memo provides.

If the Phase 3 plugin refactor turns out to be more invasive
than expected, the fork path becomes a viable fallback —
fork doesn't require plugins to be shareable. We are not
committing AGAINST fork; we are committing to Ractor as the
primary direction.

### WD2 — Why split `RbsLoader` rather than make it shareable?

`RbsLoader` carries three mutable Hashes
(`@class_known_cache`, `@instance_definition_cache`,
`@singleton_definition_cache`) plus an internal
`RBS::Environment` (upstream, also mutable). Making the
whole loader shareable would require either:

- Replacing the mutable Hashes with `Ractor.make_shareable`
  immutable snapshots — defeats the cache, every per-call
  miss path becomes a full env walk.
- Replacing the Hashes with `Ractor::TVar` or similar —
  doesn't exist in MRI 4.x.
- A coarse Monitor across every access — works in principle
  but Ractor's share-nothing model explicitly rejects this
  pattern; a Monitor-guarded shared cache violates the
  Ractor contract.

Splitting the loader so the Environment carries only the
frozen reflection facade preserves the cache (per-Ractor
mutable, populated from the cross-Ractor `Cache::Store`)
AND satisfies the Ractor contract. The cost is a
refactor; the alternative is no Phase 4 worker pool.

### WD3 — Why per-Ractor caches rather than shared?

The `Cache::Store` provides a process-shared, monitor-safe
in-memory layer. Why not point all Ractors at it directly?

`Cache::Store` IS the cross-Ractor sharing point — but
between the Store and the call site sits the per-loader
memoisation layer (`@class_known_cache` et al.). The
memoisation layer skips the Cache::Store lookup AND the
deserialise step on warm calls. Making it cross-Ractor
shared would require either:

- Monitor-locking every memo access from every Ractor —
  Ractor contract violation.
- Replacing the Hash with a per-Ractor view onto a shared
  immutable snapshot — defeats the warm-up benefit on the
  miss path.

Per-Ractor cache layers pay one cold-start per Ractor on
first miss. Cache::Store covers the cross-Ractor warm-up
(both serialised disk entries AND in-process memo for
repeated within-process Runner calls). The combined
behaviour:

- First Runner.run, first Ractor, first `class_known?` call
  for class X: Cache::Store memo miss → disk hit (or build)
  → memo write. The PER-RACTOR memo on the loader caches
  the result for subsequent calls in that Ractor.
- Second Ractor, first `class_known?` call for class X:
  Cache::Store memo HIT (cross-Ractor warm) → no disk, no
  Marshal.load. Per-Ractor memo caches for the worker's
  remaining files.

This composes the two layers correctly. The per-Ractor
memo is small (one Hash entry per touched class); the
Cache::Store memo amortises across the pool.

### WD4 — Why opt-in, not default?

Phase 4 ships Ractor workers as opt-in (env var / config
flag) until the example plugin ecosystem has been validated
under Ractor isolation. Specifically:

- The plugin contract change in Phase 3 is invasive.
  Plugins authored before Phase 3 lands MAY accidentally
  rely on shared mutable state. Defaulting workers to
  enabled would surface those bugs in user code.
- Worker startup cost has to be measured against typical
  project shapes before defaulting. A 50-file project
  shouldn't slow down for the worker pool overhead.
- Determinism behaviour (especially around plugin
  contribution timing) needs spec coverage that doesn't
  exist yet.

Opt-in means the early adopters pay attention to the
trade-offs; default-on means everyone pays. We default-on
when the validation data justifies it.

### WD6 — Why isn't `Environment::Reflection` `Ractor.shareable?`?

Discovered during Phase 2b implementation: the cached
`instance_definitions` / `singleton_definitions` tables hold
upstream `RBS::Definition` objects that transitively reference
`RBS::Location`. `RBS::Location` is C-extension state that
`Ractor.make_shareable` rejects (the same constraint that
forced the `RBS::Environment` Marshal patch in
`lib/rigor/cache/rbs_environment_marshal_patch.rb`).

Resolution: Reflection IS frozen + read-only — the
immutability win — but NOT `Ractor.shareable?`. The Ractor
worker pool (Phase 4) sidesteps the constraint by having
each worker build its OWN Reflection from the shared
`Cache::Store`. The cross-Ractor sharing point is the
Store's disk + in-process-memo layer (already
Monitor-safe); each Ractor's Reflection is a per-Ractor
immutable read-side view of the same underlying data.

If a future RBS release makes `RBS::Location` Ractor-
shareable, the one-line addition of
`Ractor.make_shareable(self)` to Reflection's `initialize`
makes the whole carrier cross-Ractor-shareable. Until
then, the per-worker-Reflection pattern is the contract.

The audit-spec
([`spec/rigor/ractor_readiness_spec.rb`](../../spec/rigor/ractor_readiness_spec.rb))
documents both properties explicitly: a `be_frozen`
assertion and a `not_to be(Ractor.shareable?)` assertion
that fails the day RBS lifts the constraint, prompting the
one-line upgrade.

### WD5 — Should we deprecate Thread-based concurrency entirely?

No. `Cache::Store` keeps its Monitor + in-process memo
because:

- `parallel_tests` benefits (the spec suite's 6× speedup)
  use Thread-like process isolation but share a Cache::Store
  directory on disk; the in-process memo and Monitor are
  both still useful at the per-process level.
- Future I/O-bound work (e.g. plugin `IoBoundary` fetches
  from network) could use Threads productively — those
  release the GVL during C-level I/O.
- The Monitor cost is zero on the contended-zero path
  (single-threaded sequential analysis).

Thread-based parallelism is not deprecated; it's just not
the path to multi-core CPU utilisation.

## Implementation slicing

Phases land in the order numbered above. Each phase has its
own commit cluster + spec coverage. The audit-spec
(`spec/rigor/ractor_readiness_spec.rb`) is the gate: a phase
advances when its target class flips from `skip` to a
passing `Ractor.shareable?` assertion (Phases 1-2) or when
its end-to-end behaviour test passes (Phases 3-4).

### Phase 2b deliverables

The next phase splits `RbsLoader` into:

```ruby
# Frozen, shareable
class Environment::Reflection
  # Read-only RBS query surface
  def class_known?(name) end
  def instance_definition(name) end
  def singleton_definition(name) end
  def class_ordering(lhs, rhs) end
  # ...
end

# Per-Ractor, mutable
class Environment::CacheLayer
  def initialize(reflection:, cache_store:)
    @reflection = reflection
    @cache_store = cache_store
    @class_known_cache = {}
    @instance_definition_cache = {}
    @singleton_definition_cache = {}
  end

  def class_known?(name)
    @class_known_cache[name.to_s] ||= reflection.class_known?(name)
  end
  # ...
end
```

`Environment#rbs_loader` (today) becomes the cache layer;
the new `Environment#reflection` carries the shareable
facade. The existing public read API (`class_known?`,
`instance_definition`, etc.) stays unchanged — the dispatch
goes through the cache layer, which lazily routes through
the reflection facade.

`Cache::Store`-backed producers
(`RbsConstantTable`, `RbsKnownClassNames`,
`RbsInstanceDefinitions`, `RbsSingletonDefinitions`,
`RbsClassAncestorTable`, `RbsClassTypeParamNames`) keep
their existing single-blob layout. The reflection facade
sits behind them; the cache layer above them is the per-
Ractor warm-up.

### Phases 3 / 4 deliverables

Detailed sketches in
[`docs/design/20260514-ractor-migration.md`](../design/20260514-ractor-migration.md)
§ Phase 3 / Phase 4. Skipping repetition here; the
sketches will be ratified in their own ADR-15 amendment
once the Phase 2b refactor is in place and the actual
plugin / runner shape constraints are visible.

## Boundary with ADR-4 (Type Inference Engine)

ADR-4 describes `Scope#type_of` and the `Scope` value
object. Scope already carries a frozen `Environment`
reference. The Phase 2b refactor changes what an
Environment IS — splitting reflection from cache — but does
NOT change the Scope contract or `Scope#type_of`'s
behaviour. Per ADR-4's "Implementation Expectations,"
Scope's public API stays stable across this refactor;
plugins reading `scope.environment.{class_known?,
instance_definition, ...}` see the same return values.

ADR-4 gains a non-normative note documenting that
`Environment` is split into `Reflection` + `CacheLayer`
after Phase 2b; the Scope and dispatcher contracts are
unchanged.

## Boundary with ADR-6 (Cache Persistence Backend)

ADR-6 describes `Cache::Store` as a process-local
filesystem cache with `flock`-guarded atomic writes. The
v0.1.4 Monitor + in-process memo additions (commits
`31e95c8`, `5c30b37`) extend that backend with thread-safe
in-process layering. ADR-15 designates `Cache::Store` as
the **cross-Ractor sharing point** for cached values.

The contract additions:

- `Cache::Store` MUST be `Ractor.shareable?`. The current
  implementation isn't (Monitor + Hash + counter ivars not
  shareable). Phase 4 design will decide whether to:
  (a) make Store shareable directly, or
  (b) wrap it in a thin Ractor-shareable proxy.

ADR-6 gains an Open Question entry recording this
constraint so future Cache::Store work doesn't accidentally
move the design AWAY from shareability.

## Boundary with ADR-2 (Extension API)

ADR-2 defines the plugin contract. Phase 3 changes:

- Plugin INSTANCES become per-Ractor. Plugin REGISTRY
  (the singleton table of plugin classes + manifests)
  stays cross-Ractor through the frozen-factory refactor.
- Plugin per-run state SHOULD route through
  `Plugin::FactStore` (already Monitor-safe) when cross-
  Ractor coordination is required. Per-instance ivar state
  stays per-Ractor.

ADR-2 gains a normative note (in the Phase 3 amendment)
clarifying that plugin authors who maintain mutable state
in `flow_contribution_for` or `diagnostics_for_file` MUST
either be safe under per-Ractor instantiation or document
their non-Ractor-compatibility.

## Open Questions

### OQ1 — Should `Cache::Store` be sharded by Ractor for write throughput?

The current Store synchronises every write through one
Monitor. Under heavy concurrent writes (many Ractors all
hitting cold paths), the Monitor becomes a contention
point. Sharding the Store (per-producer or per-key-prefix
sub-Stores, each with its own Monitor) would relieve that.

Defer: measure first. The expected workload is read-heavy
(most cache hits) and Monitor contention should be
negligible.

### OQ2 — How should plugin per-Ractor instances coordinate aggregate state?

`rigor-sorbet`'s absurd-reachable / reveal-type / assert-
type-mismatch tracking accumulates across files. Under
per-Ractor plugins, each Ractor's plugin instance sees only
its slice. The current shape relies on `compare_by_identity`
Hashes keyed on AST nodes; AST nodes are per-Ractor too.

Three options when this lands in Phase 3:

1. **Move to `Plugin::FactStore` publish/consume.** Plugins
   publish per-call observations; the main Ractor
   aggregates after all workers finish.
2. **Result-merge per-plugin.** Each worker returns its
   plugin state alongside its diagnostics; the runner
   merges per plugin.
3. **Plugin opt-out of parallelism.** Plugins declare
   `manifest(serial: true)` and the runner serialises calls
   to them.

Decision deferred to Phase 3.

### OQ3 — Should the Ractor pool size be CPU-count-derived or configurable?

Both. Default to `[CPU_count - 1, 4].min` (leave one core
for the parent + OS); honour `RIGOR_RACTOR_WORKERS` and
`.rigor.yml`'s `parallel: { workers: N }`. Identical to
the `parallel_tests` knob shape that already worked for the
spec suite.

## Rejected alternatives

- **Status quo (single-threaded analyzer)**: rejected because
  the wall-clock impact is significant for medium and large
  projects, and the audit data (157 files, 1.8s warm) shows
  the headroom IS available — we're just leaving it on the
  floor.
- **Pure fork-based workers**: not rejected outright but
  considered secondary. Fork has higher setup cost, no
  daemon path, and forces per-fork Environment rebuild. The
  Ractor path solves more downstream cases (LSP, watch
  mode, future `rigor server`).
- **External worker pool via gem (e.g. `concurrent-ruby`)**:
  rejected. Adds a dependency without solving the GVL
  issue; under MRI 4.x `concurrent-ruby` Threads are still
  GVL-bound for CPU work.
- **Wait for Ruby M:N scheduler maturity**: rejected as
  blocking. The M:N scheduler exists but its CPU-parallelism
  story under MRI is still evolving. Ractors are committed
  and stable today.

## Recommended order

1. ✅ Phase 1 — value-object shareability.
2. ✅ Phase 2a — `Configuration` deep-freeze.
3. ✅ Phase 2b — `Environment::Reflection` extracted (frozen,
   NOT yet Ractor-shareable; see WD6 for the
   `RBS::Location` constraint).
4. ✅ Phase 3a — `Plugin::Blueprint` + `Registry#blueprints`
   + `Registry.materialize` factory. Live plugin instances
   are intentionally NOT shareable; the blueprint set is
   the cross-Ractor handle.
5. ⏭ Phase 3b — cross-Ractor plugin aggregate-state contract
   (see § OQ2). Deferred until Phase 4 measures the actual
   shape of per-worker plugin state.
6. ✅ Phase 4a — `Analysis::WorkerSession` value carrier;
   per-worker substrate with no Ractor in the loop yet.
   See § Phase 4 design + design doc § Phase 4a.
7. ✅ Phase 4b — Runner Ractor pool around `WorkerSession`
   (programmatic `workers:` keyword; sequential remains
   default; CLI / `.rigor.yml` opt-in deferred to 4c).
8. ✅ Phase 4c — `RIGOR_RACTOR_WORKERS` opt-in flag +
   `.rigor.yml` `parallel.workers:` entry +
   `Configuration#parallel_workers` accessor + CLI
   `--workers=N` flag (precedence: CLI > env > config >
   `0`). Default remains sequential. Pool spec excluded
   from default suite (see § "Known limitations").
9. ⏭ Phase 4b.x — worker-side env-build stability so
   pool mode handles real-world (non-trivial) source
   files. Currently the worker `RBS::EnvironmentLoader.new`
   path trips `Ractor::IsolationError` on a chain of
   RubyGems / RBS module constants
   (`DEFAULT_CORE_ROOT`, `DEFAULT_STDLIB_ROOT`,
   `Gem::Requirement::DefaultRequirement`). Until then,
   pool mode is correctness-bound by file content
   triviality; default sequential mode is the
   documented production path.
10. ⏭ Phase 4c+ — per-worker `Cache::Store`-shared facade
    per § OQ1; benchmark sequential vs pool wall-clock
    and revisit the default once Phase 4b.x stabilises
    worker env builds.
