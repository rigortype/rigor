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

Two blockers:

1. **`Plugin::Base#init(services)`** — services contain
   non-shareable references (`Cache::Store` is monitor-safe
   but not yet Ractor-shareable). Plugins themselves
   accumulate mutable state in instance variables (the
   `rigor-sorbet` `@reachable_absurd_nodes` /
   `@reveal_type_calls` / `@assert_type_mismatches`
   `compare_by_identity` Hashes are the canonical examples).
2. **`Plugin::Registry`** — accumulates plugin instances in a
   Hash that's not frozen.

Resolution sketch:

- Per-Ractor plugin instance: each worker instantiates its
  own plugin objects from the shared `Plugin::Registry`
  metadata (manifest + class names). Plugins that need
  cross-Ractor coordination publish through `Plugin::FactStore`
  (which is already monitor-friendly).
- Refactor `Plugin::Registry` to be a frozen "factory + ID
  table" rather than a mutable instance pool.

Estimated size: medium (~150-250 LoC + spec coverage across
the worked example plugins).

## Phase 4 — Ractor-isolated file workers

Goal: `Analysis::Runner#analyze_files` dispatches files across
a pool of Ractors.

Prerequisites: Phases 1-3. With those landed, the worker
implementation is straightforward:

```ruby
def analyze_files(files, environment)
  return sequential(files, environment) if @worker_count <= 1

  pool = Array.new(@worker_count) do
    Ractor.new(environment, configuration: @configuration) do |env, configuration:|
      loop do
        path = Ractor.receive
        break if path.nil?

        result = analyze_one(path, env, configuration)
        Ractor.yield(result)
      end
    end
  end

  files.each_with_index { |path, idx| pool[idx % @worker_count].send(path) }
  @worker_count.times { |i| pool[i].send(nil) }
  Array.new(files.size) { pool.first.take } # collect in completion order
end
```

The actual implementation will need result-by-path bookkeeping
for deterministic output order; the sketch above just
demonstrates the data-flow shape.

Estimated size: small once prerequisites land (~50 LoC).

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
3. ⏭ Phase 2b — `RbsLoader` split (large, needs design
   review).
4. ⏭ Phase 3 — Plugin contract refactor.
5. ⏭ Phase 4 — Ractor worker pool.

Each subsequent phase reads from the prior phase's audit spec
to confirm prerequisites. The audit spec is the contract
between phases.
