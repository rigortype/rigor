# Worker Session Protocol

`Rigor::Analysis::WorkerSession` is the per-worker analysis substrate that
makes parallel analysis possible. This page pins the **contract** the
session satisfies — its shareable inputs, its ownership boundary, and the
equivalence guarantee that keeps parallel output identical to sequential.
The concurrency *rationale*, the phase roadmap, and the fork-vs-Ractor
decision are in [ADR-15](../adr/15-ractor-concurrency.md); the
value-object shareability requirement that this protocol depends on is in
[`plugin.md`](plugin.md#concurrency-and-value-object-shareability-adr-15).

## Status

The shipped parallel backend is a **forked persistent worker** pool (the
ADR-15 amendment); the Ractor-isolated pool is the deferred target. The
`WorkerSession` substrate (ADR-15 Phase 4a) is authored so its inputs are
`Ractor.shareable?` — the fork backend uses it today, and the same session
is what a future Ractor pool would wrap in `Ractor.new`.

## Shareable inputs

The constructor accepts only inputs that cross a worker boundary safely:

- `configuration` — a `Rigor::Configuration` (`Ractor.shareable?`).
- `cache_store` — a `Rigor::Cache::Store`, or `nil` to disable caching. A
  fork/Ractor worker MAY build its own `Store` at the shared cache-root
  directory instead of being handed one.
- `plugin_blueprints` — an `Array<Rigor::Plugin::Blueprint>`
  (`Ractor.shareable?`); the per-worker plugin instances are materialised
  from these (see [`plugin.md`](plugin.md#concurrency-and-value-object-shareability-adr-15)).
- `explain` — a Boolean.
- `record_dependencies` — a Boolean (default `false`). When set,
  `#analyze` wraps each file's analysis in an ADR-46 `DependencyRecorder`
  window so the worker captures that file's cross-file reads, drained by
  `#drain_dependencies` alongside `#drain_reporters`. The recorder's own
  disabled fast path makes the unset case free.
- `synthetic_method_index` / `project_patched_methods` /
  `project_scope_seed` — optional, default `nil` / `{}`. These are **not**
  `Ractor.shareable?` (the seed tables carry Prism def nodes), so a Ractor
  pool leaves them unset; the fork backend (which builds the session
  pre-fork on the parent) threads the runner's project-scan results through
  so per-file inference matches the sequential path exactly.
  `source_files` — the analyzed-file set the session's environment is
  built against, threaded for the same equivalence reason.
  `project_scope_seed` is the runner's cross-file pre-pass table set
  (`Runner#project_scope_seed_tables` — the same tables
  `seed_project_scope` applies on the sequential path); a session
  constructed without it cannot resolve calls to methods defined in other
  project files and violates the equivalence contract with false
  `call.undefined-method` diagnostics.

## Ownership boundary

The session **owns and never shares** the mutable machinery a run
accumulates:

- the `Rigor::Plugin::Services` bound to the per-worker `Store`;
- the `Rigor::Plugin::Registry` materialised from the blueprints, including
  every plugin instance and its mutable per-run accumulators (discovery
  indexes, reachability sets);
- the `RbsExtended::Reporter` and the dependency-source
  `BoundaryCrossReporter` (both Mutex-bearing and intentionally
  per-worker — the runner merges their entries post-pool via
  `#drain_reporters`, and the recorded dependencies via
  `#drain_dependencies`);
- the `Rigor::Environment`, threaded with the per-worker reporters so
  reporter writes from inference / dispatch accumulate into the worker's
  own state — including its `RbsLoader`, whose per-class RBS
  definition-build failures ride the same drain
  ([#696](https://github.com/rigortype/rigor/issues/696)).

A whole-run condition that only a definition BUILD can observe MUST be
drained out of the workers rather than read off the coordinator's own
loader. Under the pool the coordinator never analyses a file, so its
loader never demands a definition and never reaches the failing build; a
diagnostic wired to it would appear at `--workers=0` and vanish at
`--workers=N`. The coordinator accumulates the union across workers,
deduped by class name: each worker holds its own loader and its own
per-class memo, so a class two workers touched arrives twice and a class
one worker touched arrives once, and neither worker alone is the set the
run hit. This is the drain rule; the diagnostic it carries is normative
in [diagnostic-policy.md](../type-specification/diagnostic-policy.md).

Plugin `#prepare` runs **once at construction** so each worker is warm
before its first `#analyze` call; any raise from `prepare` is captured into
`#prepare_diagnostics` for the runner to surface alongside the per-file
stream rather than aborting the worker.

## Equivalence contract

Given identical `(configuration, cache_store, plugin_blueprints)`, the
multiset of diagnostics from `paths.flat_map { |p| session.analyze(p) }`,
plus `#prepare_diagnostics`, plus the drained reporter entries, MUST equal
the corresponding subset of `Rigor::Analysis::Runner#run`'s output — modulo
severity-profile re-stamping, which the session deliberately leaves to the
caller because it is a per-run aggregate concern (see
[severity resolution](../type-specification/diagnostic-policy.md#severity-resolution)).
This is the property that lets the runner shard files across workers
without changing what `rigor check` reports; it is proven by spec.
