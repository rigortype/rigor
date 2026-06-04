# ADR-44 — Per-dispatch / per-narrow allocation churn (Scope, CallContext)

Status: **Accepted — body-scope chain collapse + allocation hygiene landed; mutable pooling rejected; field-regrouping downgraded (object-shape benchmark shows it cuts size, not allocation count).**

After the plugin-contribution path was de-churned (ADR-37 collectors:
`dynamic_returns` snapshot memo, lazy accumulation, and the
`Registry#contribution_index`), profiling `rigor check` on a plugin-heavy
real app (GitLab FOSS, `app/{controllers,mailers,workers,services}` =
2,630 files, 11 plugins, faithful `cwd=gitlab` run) shows the analysis is
still **allocation-bound**, and the two largest remaining allocation
sites are *structural*: the immutable `Scope` rebuilt on every narrowing,
and the `CallContext` `Data` built on every dispatch.

This ADR records why the tempting structural rewrite (mutable, pooled
scope / context) is **rejected** on false-positive-discipline grounds,
what incremental allocation hygiene **landed**, and the **sanctioned**
(but deferred) field-regrouping direction.

Grounding: [`docs/notes/20260604-gitlab-plugin-contribution-allocation.md`](../notes/20260604-gitlab-plugin-contribution-allocation.md)
and [`docs/notes/20260604-mastodon-allocation-profile.md`](../notes/20260604-mastodon-allocation-profile.md).

## Context

Faithful GitLab `:object` profile after the ADR-37 plugin de-churn
(~222 M objects total, `--workers 0 --no-cache`). Top allocation sites:

| alloc % | site | nature |
|--:|---|---|
| ~7.5 % | `CallContext.build` + `.new` + its `Data#initialize` | one `Data` per dispatch |
| ~4.3 % | `Scope#rebuild` | one `Scope` per narrowing |
| ~2.6 % | `StaticReturnRefinements.owners_for` | a fresh `[]` per non-refined method |
| ~2.5 % | `MethodDispatcher.discovered_method_lookup` | per dispatch |
| ~2.3 % | `RbsDispatch.receiver_descriptor` | per dispatch |

Two facts shape the decision:

- **`Scope` is immutable by contract.** Control-flow analysis
  ([`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md))
  relies on a narrowed `Scope` being a *value*: a branch can hold a
  snapshot, the join can compare two scopes, and a fact established on one
  path cannot leak to another. Every `with_*` returns a frozen copy; the
  22 fields are mostly shared frozen hashes, so the cost is the wrapper
  object, not the data.
- **Dispatch is re-entrant.** `MethodDispatcher.dispatch` recurses:
  block folding redispatches per element, user-method-return inference
  evaluates a method body (which dispatches again), the user-class
  fallback redispatches `public_only`. A `CallContext` is live on the
  stack at several depths simultaneously.

## Decision

### Rejected — mutable, pooled Scope / CallContext

The obvious "fix" is to stop allocating: keep a thread-local mutable
scratch `Scope` / `CallContext`, reset it per narrow / per dispatch, and
reuse it. **Rejected.** Because dispatch and narrowing are *re-entrant*, a
single reused mutable object is live at multiple stack depths at once —
an inner redispatch would overwrite the outer frame's context, and a
branch that captured a "snapshot" scope would see it mutated out from
under it at the join. The failure mode is not a crash but a **silently
wrong narrowing** — exactly the class of bug that manufactures a false
positive on working code, which this project weighs above any worst-case
static reading (the top-tier false-positive-discipline value). A
correctly-sized pool keyed by stack depth would recover safety but
reintroduce most of the bookkeeping (and allocation) it set out to
remove. The allocation is the price of the immutable, re-entrant design,
and that design is load-bearing for soundness-of-narrowing. Not worth it.

### Accepted (landed) — incremental allocation hygiene

Reduce *avoidable* allocation around these sites without touching the
immutability contract:

- **`StaticReturnRefinements.owners_for`** returns a shared frozen
  `NO_OWNERS` constant instead of a fresh `[]` on the (overwhelmingly
  common) miss — it is consulted on every dispatch.
- **`CallContext.build`** constructs via *positional* `new` (in
  `Data.define` field order) rather than `new(receiver:, …)`, avoiding
  the keyword hash the keyword form allocates per dispatch.

Faithful A/B (cwd=gitlab, 11 plugins, `--no-cache`): 228.5 M → 222.4 M
objects (−2.7 %), wall 122.5 s → 120.5 s, diagnostics byte-identical
(2,323 / 38). `make verify` green. Small, but free and risk-free — the
same shared-empty / positional-construction hygiene applies wherever a
hot path allocates a throwaway empty collection or keyword hash.

### Accepted (landed) — collapse the body-scope `with_*` chains

The `Scope#rebuild` caller breakdown was the surprise: it is **not**
dominated by control-flow narrowing but by *body-scope construction*.
`ExpressionTyper#build_user_method_body_scope` (per user-method-call
inference) and `StatementEvaluator#build_fresh_body_scope` (per
class/method body) each built a fresh scope by **chaining ~12–13
`with_*` calls**, every one allocating an intermediate frozen `Scope` and
re-running `rebuild`'s field copy — a dozen throwaway scopes to build one.

Both now construct the scope in a **single `Scope.new`** with every field
set at once. The body scope starts from an empty fact store / narrowing
set, so the chained `with_local` invalidations were no-ops and the
project/`self_type` setters were plain field writes — so one `new` is
byte-identical to the chain. Faithful A/B: 222.4 M → 213.3 M objects
(−4 %), **GC runs 362 → 256 (−29 %)**, diagnostics byte-identical
(2,323 / 38). The wall win exceeds the allocation drop because collapsing
the chain also removes ~12 `rebuild` method calls (and their keyword
processing) per body scope.

### Investigated, low priority — regroup `Scope`'s immutable project fields

The originally-sanctioned idea was to group `Scope`'s ~15 immutable
project-wide fields (`discovered_*`, built once in
`run_project_pre_passes`) behind one shared `ProjectScope`, shrinking
`Scope` from ~22 to ~8 fields. **A micro-benchmark on the target Ruby
(4.0.5) refuted the premise that this cuts allocations:** with object
shapes / variable-width allocation, a frozen object with 3, 8, 16, 22, or
24 ivars all allocate **exactly one** object — there is no spill to a
second ivar buffer. Regrouping therefore reduces only the per-`Scope`
heap-slot *size*, not the allocation *count* that drives the lazy-sweep
cost; the `Scope#rebuild` sample share would be unchanged. The real
count-reducing win was collapsing the construction chains above. The
regrouping remains a *memory-footprint* lever (smaller slots → heap fills
slower → fewer GC cycles), but it is large (touches every
`scope.discovered_*` reader), its payoff is now known to be modest, and it
must be measured-before-invested rather than assumed.

## Consequences

- The immutable-`Scope` / re-entrant-dispatch contract is now *documented*
  as load-bearing for narrowing soundness, so future "just make it
  mutable" proposals start from the rejected-alternatives record here.
- Allocation remains the dominant cost on plugin-heavy projects; the
  remaining lever is the staged `ProjectScope` regrouping plus continued
  per-site hygiene, not an architecture change.
- No behaviour change: every slice in this ADR is verified
  diagnostics-byte-identical.

## Rejected alternatives (summary)

- **Mutable pooled Scope/CallContext** — re-entrancy makes a single
  reused object unsafe; silent narrowing corruption → false positives.
- **Skip `CallContext` for the precise-tier-only path** — the tiers share
  one `try_dispatch(CallContext)` interface; specialising the common path
  would fork that interface for a fraction of the dispatch cost. Deferred
  in favour of the `ProjectScope` regrouping, which is larger and cleaner.
