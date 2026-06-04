# ADR-44 — Per-dispatch / per-narrow allocation churn (Scope, CallContext)

Status: **Accepted — incremental slice landed; mutable pooling rejected; field-regrouping sanctioned but staged.**

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

### Sanctioned, staged — regroup `Scope`'s immutable project fields

`Scope` carries 22 ivars, of which ~15 (`discovered_classes`,
`discovered_methods`, `discovered_def_nodes`, `discovered_superclasses`,
`discovered_includes`, … — the project-wide indexes built once in
`run_project_pre_passes`) are **identical across every `Scope` in a
run**. Grouping them behind one shared frozen `ProjectScope` value object
shrinks `Scope` from ~22 to ~8 fields, so each per-narrow rebuild copies
8 references and allocates a smaller object. This is **precision-neutral**
(pure field regrouping — same data, same immutability) and the right
structural lever for the `Scope#rebuild` 4.3 %.

It is **deferred**, not done: it touches every `scope.discovered_*`
reader (~dozens of call sites) and warrants its own focused change with a
byte-identical-diagnostics gate on Mastodon + GitLab, not a tail-end edit
to this ADR's slice. This ADR sanctions the direction so the next
implementer does not re-litigate it.

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
