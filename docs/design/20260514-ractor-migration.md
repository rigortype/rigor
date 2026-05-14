# Ractor migration — staged plan

**Status:** Draft. Phase 1 landed; later phases pending.

Rigor's analyzer is CPU-bound Ruby. The MRI GVL serialises Ruby
code execution across threads, so Thread-based parallelism gives
no wall-clock benefit for `rigor check` (prototyped + reverted;
see `docs/CURRENT_WORK.md` Open Engineering Items #7). The two
real paths to multi-core utilisation are **fork-based workers**
and **Ractors**. This document plans the Ractor path.

Ractors require every object that crosses a Ractor boundary to
be `Ractor.shareable?`. The eventual end state — a Ractor-
isolated worker pool dispatching `analyze_file` across cores —
needs the whole `(Configuration, Environment, Scope, Type,
TypeNode, FlowContribution, Plugin)` data surface to satisfy
that constraint. The work is too large for a single commit and
risky to do speculatively, so we land it in phases. Each phase
is independently useful and independently revert-able.

## Phase 1 — Value-object shareability (LANDED)

Goal: every leaf value-object the engine carries through
dispatch is `Ractor.shareable?` at construction time.

Coverage today:

- `Rigor::Type::*` — every Type carrier (16 classes). All
  shareable.
- `Rigor::TypeNode::*` — every parser-side AST node. Made
  shareable by freezing internal `String` / `Array` fields in
  the constructor (this commit).
- `Rigor::Cache::Descriptor` — already shareable.
- `Rigor::Analysis::FactStore.empty` — already shareable.
- `Rigor::FlowContribution` — already shareable.

Regression guard: `spec/rigor/ractor_readiness_spec.rb` asserts
`Ractor.shareable?` on every constructor in the covered list.
Adding a new value-object class without updating the audit spec
catches future drift.

## Phase 2 — Configuration / Scope / Environment

Goal: the run-time context Carrier objects ride through is
shareable.

Three classes block this:

### `Rigor::Configuration` (LANDED — Phase 2a)

Why was not shareable: the `@paths` Array was not frozen and
`Configuration#initialize` did not call `freeze` on `self`.
Every other ivar was already frozen (Symbol / nil / Boolean,
or explicitly frozen collection / value object).

Fix landed: append `.freeze` to the `@paths` build and add a
final `freeze` line at the end of `initialize`. Backward-
compatible — no production code mutates a Configuration post-
construction, and the audit-spec passes immediately after the
two-line change. `spec/rigor/ractor_readiness_spec.rb`'s
`Rigor::Configuration` example flips from `skip` to a passing
assertion.

### `Rigor::Scope`

Why not shareable: `Scope.empty` references the default
`Environment`, which is not shareable (see below).

Fix: once `Environment` is shareable, `Scope` follows. The
Scope value object itself is already deep-frozen.

### `Rigor::Environment`

Why not shareable: `Environment#rbs_loader` carries an
`RbsLoader` instance with mutable per-process caches
(`@class_known_cache`, `@instance_definition_cache`,
`@singleton_definition_cache`). These caches are CRITICAL for
performance — every `class_known?` / `instance_definition`
lookup goes through them.

The conflict: a frozen Environment cannot carry a mutable
cache. A per-Ractor cache defeats the cross-file sharing
benefit.

Resolution sketch (substantial refactor):

1. Split `RbsLoader` into two surfaces:
   - **Reflection** — the read-only RBS query interface
     (`class_known?`, `instance_definition`, etc.). Frozen
     after construction. The Environment carries this.
   - **CacheLayer** — the mutable memoisation layer wrapping
     Reflection. Owned by the running Ractor, NOT shared
     across Ractors.
2. `Environment` carries the frozen Reflection only. Per-
   Ractor, the Ractor instantiates its own CacheLayer pointed
   at the shared Reflection + the shared `Cache::Store` (which
   already has `Monitor`-protected `@memo`).
3. `class_known?` / `instance_definition` dispatch through the
   per-Ractor CacheLayer; cache fills propagate via the
   `Cache::Store` (Marshal-clean entries, durable across
   Ractor lifetimes).

Estimated size: large (~300-500 LoC + spec).

Trade-off check: the per-Ractor CacheLayer pays one cold-start
per Ractor (vs zero in the shared model). If the worker pool
processes N files, the warm-up cost amortises after the first
file. Profile-confirm before committing to the design.

## Phase 3 — Plugin contract

Goal: plugins can run from a Ractor worker.

### Phase 3a — `Plugin::Blueprint` + materialise factory (LANDED)

The minimal cross-Ractor handle for plugin replay landed
without changing the live coordinator path. New surface:

- **`Rigor::Plugin::Blueprint`** — frozen, `Ractor.shareable?`
  value object carrying `klass_name` (String — the constant
  path) plus a deep-copied, `Ractor.make_shareable`-treated
  `config` Hash. Construction takes a `String` or a `Module`;
  the Module form stores `klass.name`.
- **`Plugin::Blueprint#materialize(services:)`** — replays
  `Object.const_get(klass_name).new(services:, config:)` then
  `#init(services)`. Bit-for-bit equivalent to
  `Loader#instantiate` so the blueprint path is consistent
  with the configuration path.
- **`Plugin::Registry#blueprints`** — frozen
  `Array<Blueprint>` aligned 1:1 with `plugins`. The loader
  derives it from the post-topo-sort plugin list via
  `plugin.class.name + plugin.config`.
- **`Plugin::Registry.materialize(blueprints:, services:)`** —
  builds a NEW Registry by mapping each blueprint to a fresh
  plugin instance. `load_errors` is intentionally empty (load
  failures already surfaced on the coordinator registry; they
  don't repeat per worker).

Plugin INSTANCES intentionally stay non-shareable. They carry
per-run mutable accumulator state in ivars (`rigor-sorbet`'s
`@reachable_absurd_nodes` / `@reveal_type_calls` /
`@assert_type_mismatches`; the `*_index` Hashes in most Rails
plugins). The per-Ractor pattern sidesteps the constraint
without forcing every plugin author to refactor: ship
blueprints across the boundary, materialise once per worker,
each worker owns its instances for its lifetime.

Audit coverage: four `Ractor.shareable?` / `frozen?`
assertions in `spec/rigor/ractor_readiness_spec.rb` under the
new "Phase 3 — Plugin contract" describe.

### Phase 3b — cross-Ractor plugin aggregate state (DEFERRED)

The per-Ractor pattern slices each plugin's view of per-run
observations. `rigor-sorbet`-style aggregate tracking
(absurd-reachable, reveal-type, assert-type-mismatch across
ALL files) would need a coordination protocol when Phase 4
ships. Three candidate shapes documented in ADR-15 § OQ2:

1. Move state to `Plugin::FactStore` publish/consume.
2. Result-merge per-plugin at the runner.
3. Plugin opt-out of parallelism (`manifest(serial: true)`).

Phase 3b decision deferred until Phase 4 measures actual
usage. None of the bundled plugins need cross-Ractor
aggregation if the runner stays sequential (Phase 4 opt-in
default).

Estimated size: small once Phase 4 lands (~50-100 LoC for
the chosen shape).

## Phase 4 — Ractor-isolated file workers

Goal: `Analysis::Runner#analyze_files` dispatches files across
a pool of Ractors.

Prerequisites: Phases 1-3a. With those landed, the missing
pieces are:

### What CAN cross the Ractor boundary today

After Phase 3a, the cross-boundary payload is fully
`Ractor.shareable?`:

- `Rigor::Configuration` (Phase 2a — frozen + shareable)
- `cache_root` (`String`, frozen — the Cache::Store directory
  path; each worker builds its OWN Store at that root)
- `libraries`, `signature_paths` (frozen Arrays of frozen
  Strings)
- `Array<Rigor::Plugin::Blueprint>` (Phase 3a — frozen +
  shareable)
- `Array<String>` of file paths (frozen)

### What CANNOT cross the Ractor boundary

The fact-finding audit (commit subsequent to Phase 3a)
identified three blockers that the worker design has to
sidestep:

1. **`Rigor::Environment`** is NOT shareable —
   `RbsLoader` carries mutable `@class_known_cache` /
   `@instance_definition_cache` / `@singleton_definition_cache`
   plus the upstream `RBS::Environment` (mutable, C-extension
   state). Each worker MUST build its own `Environment` via
   `Environment.for_project(libraries:, signature_paths:,
   cache_store:, ...)` inside its Ractor body.
2. **`Cache::Store`** is NOT shareable — Monitor + counter
   ivars + Hash with default_proc all violate the contract.
   Phase 4a sidesteps this by having each worker construct
   its own Store pointing at the same on-disk directory.
   The in-process memo benefit is lost cross-Ractor, but
   the disk-backed cache is shared (filesystem is the
   coordination point). Future work (Phase 4b? deferred):
   either make Store shareable directly, or wrap it in a
   Ractor-shareable proxy that channels memo accesses
   through a single owner Ractor.
3. **`RbsExtended::Reporter` + `BoundaryCrossReporter`** use
   `Mutex` — thread-safe but NOT Ractor-shareable. Each
   worker MUST construct its own reporters; the runner
   merges entries at the end via the reporters' existing
   dedup logic (per-key entry append is idempotent on
   `(payload, source_location)` so post-hoc merge is safe).

### Phase 4 sub-phase decomposition

**Phase 4a (LANDED) — `WorkerSession` value carrier (no Ractor yet).**
{Rigor::Analysis::WorkerSession} takes the shareable inputs
above (`configuration`, `cache_store` / cache_root, `Array<Plugin::Blueprint>`,
`explain`) and builds a fresh `Plugin::Services` +
`Plugin::Registry` (via `Registry.materialize`) +
`DependencySourceInference::Index` + `Environment` + per-session
`RbsExtended::Reporter` + `BoundaryCrossReporter` internally.
Plugin `#prepare` runs once at construction; raises are
captured into `#prepare_diagnostics` so the caller can drain
them alongside the per-file diagnostic stream. Exposes
`#analyze(path)` returning the per-file diagnostic stream
(equivalent of `Runner#analyze_file` + `plugin_emitted_diagnostics`
+ `explain_diagnostics`) plus `#drain_reporters` returning
frozen reporter snapshots for end-of-pool merge.

Equivalence with `Runner#analyze_file` is proven by
`spec/rigor/analysis/worker_session_spec.rb`: same
configuration + cache_store + plugin_blueprints, same
per-file diagnostic stream (modulo severity-profile
re-stamping, which the session leaves to the caller as a
per-run aggregate concern). Plugin lifecycle (init, prepare,
diagnostics_for_file) replays through the blueprint path
with the same runtime-error-isolation envelope the Runner
applies today.

The substrate is intentionally additive: `Runner` still
drives per-file analysis itself for v0.1.4 and earlier
releases. Phase 4b changes `Runner` to delegate per-file
analysis to one (no-Ractor) WorkerSession; phase 4c spawns
N worker Ractors holding N sessions.

NO Ractor in the loop yet — this is the substrate.

**Phase 4b (LANDED) — Ractor pool around `WorkerSession`.**
`Analysis::Runner#initialize` gains a `workers: N` keyword
(default `0` = sequential, the documented v0.1.4-and-earlier
behaviour). When `N > 0`, `Runner#analyze_files` dispatches
to the new private `#analyze_files_in_pool(files)` which
spawns N Ractors. Each worker takes the shareable payload
(Configuration, cache_root String, Plugin::Blueprint Array,
explain Boolean), builds its own WorkerSession internally,
and writes back to the main Ractor's mailbox via
`Ractor.main.send` (Ruby 4.0 dropped `Ractor.yield`; the
mailbox model is now bidirectional). Three message kinds:
`[:prepare, diagnostics]` (coordinator keeps the FIRST
worker's snapshot), `[:file, path, diagnostics]` (one per
analysed file), `[:done, drained_reporters]` (one per worker
at exit). Diagnostic order is reconstructed by re-flowing
the per-path result Hash through the original input order.
Per-worker reporter snapshots merge into the runner-side
accumulators via the existing `record_*` APIs (dedup
naturally). `Environment::ClassRegistry.default` made
`Ractor.make_shareable` so workers can lazy-read it without
`Ractor::IsolationError`; `Runner#analyze_files_in_pool`
pre-warms it on the main Ractor first. `WorkerSession`
constructor no longer writes the
`MethodDispatcher::FileFolding.fold_platform_specific_paths`
process-global (non-main writes raise) — the Runner sets it
once on the main Ractor before pool spawn.

Equivalence + plugin replay + prepare-dedup proven by
`spec/rigor/analysis/runner_pool_spec.rb`. Audit-spec
coverage in `spec/rigor/ractor_readiness_spec.rb`
§ "Phase 4b — Ractor pool readiness".

**Phase 4c — Defaults + flag.** `RIGOR_RACTOR_WORKERS` env
var (`0` = sequential, default; `N` = N workers); honour
`.rigor.yml` `parallel: { workers: N }` (matches ADR-15
§ OQ3). Benchmark + decide default.

### Open design points for Phase 4a

- **Plugin `#prepare` timing.** `prepare_plugins` runs once
  per run BEFORE any file analysis (runner.rb:424) and
  expects each plugin to publish facts to its services'
  fact_store. Under Ractor isolation, each worker has its
  OWN plugin instance with its OWN services / fact_store —
  but the fact_store can't be Mutex-shared cross-Ractor.
  Options: (a) run `prepare` once on the coordinator, dump
  the produced facts as a shareable Hash, ship to workers
  for replay; (b) accept that `prepare` runs per-worker
  (most plugins re-read the same disk inputs — duplicate
  work but correct). 4a should pick one; (a) is the lower-
  cost option assuming fact_store contents are Marshal-able.

- **`dependency_source_index`.** Already constructed
  per-run; need to verify shareability or reconstruct
  per-worker.

- **`scope_indexer.discovered_classes` cross-file seeding.**
  Some flows pre-seed scope with discovered classes from
  prior files (ADR-14 ObservationCollector). If parallel
  workers process files concurrently, this cross-file
  seeding breaks. Pin: workers run independent per-file
  analyses; the ObservationCollector path stays sequential
  (it's a separate code path, not the default
  `analyze_file`).

Estimated size:

- Phase 4a: ~200-300 LoC (WorkerSession + spec)
- Phase 4b: ~150-250 LoC (Runner integration + spec)
- Phase 4c: ~50 LoC (flag + docs)

Expected benefit: at 4 workers + RBS cache warm, wall-clock
should drop ~3× for projects with hundreds of files (where
inference dominates). Smaller projects pay the Ractor-startup
overhead without much win.

## Trade-offs and decision points

- **CRuby Ractor maturity**: Ractors are stable but the
  shareability constraints are strict. Some Ruby idioms (class-
  level mutable state, frozen-string-literal interactions with
  dynamically built Strings) need careful audit during each
  phase.
- **YJIT compatibility**: YJIT is per-Ractor in Ruby 3.3+.
  Worker startup pays YJIT warm-up cost.
- **Plugin author burden**: Phase 3 requires plugins to be
  thread/Ractor-aware. The framework can take most of this on
  via the registry refactor, but plugin authors with stateful
  hooks will need to opt in to per-Ractor instantiation.
- **Alternative: fork-based parallelism** — simpler, works
  today, but each worker rebuilds Environment + RBS cache,
  costing ~50-200ms per fork. Net benefit only at scale.

The fork path and the Ractor path are NOT mutually exclusive.
Fork-based could land first as a quick win (CURRENT_WORK Open
Items #7) while Ractor phases progress incrementally.

## Recommended order

1. ✅ Phase 1 — value-object shareability.
2. ✅ Phase 2a — `Configuration` deep-freeze.
3. ✅ Phase 2b — `Environment::Reflection` extracted
   (frozen read-only facade; NOT Ractor-shareable due to
   the upstream `RBS::Location` C-extension constraint;
   each Phase 4 worker will build its own Reflection from
   the shared `Cache::Store`).
4. ✅ Phase 3a — `Plugin::Blueprint` + `Registry#blueprints`
   + `Registry.materialize` factory.
5. ⏭ Phase 3b — cross-Ractor plugin aggregate-state
   contract (DEFERRED until Phase 4).
6. ✅ Phase 4a — `WorkerSession` value carrier (no Ractor
   yet; substrate for the pool).
7. ✅ Phase 4b — Ractor pool around `WorkerSession` in
   `Runner#analyze_files` (programmatic `workers: N`
   opt-in; sequential remains default).
8. ⏭ Phase 4c — User-facing opt-in flag
   (`RIGOR_RACTOR_WORKERS` env + `.rigor.yml`
   `parallel.workers:`).

Each subsequent phase reads from the prior phase's audit spec
to confirm prerequisites. The audit spec is the contract
between phases.
