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
- `synthetic_method_index` / `project_patched_methods` — optional, default
  `nil`. These are **not** `Ractor.shareable?`, so a Ractor pool leaves
  them unset; the fork backend (which builds the session pre-fork on the
  parent) threads the runner's project-scan results through so per-file
  inference matches the sequential path exactly.

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
  `#drain_reporters`);
- the `Rigor::Environment`, threaded with the per-worker reporters so
  reporter writes from inference / dispatch accumulate into the worker's
  own state.

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
