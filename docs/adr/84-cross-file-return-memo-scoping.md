# ADR-84 — Cross-file return-memo scoping and the taint-precise store gate

Status: **Accepted — WD1 (memo profile counters + recording-soundness pin) landed in [PR #79](https://github.com/rigortype/rigor/pull/79); WD2 (run-scoped bucket + dependency cache-and-replay) and WD3 (event-taint store gate) implemented (this PR, gates below), each gated on byte-identical corpus diagnostics + the WD1 counters showing the targeted refusal mass converting to hits.** Two designs this ADR-cycle produced were killed by their own measurement and are recorded in WD4 so they are not re-chased.

Grounding: [`20260713-corpus-perf-campaign.md`](../notes/20260713-corpus-perf-campaign.md) (mail +2.05M / +10.8% attributed to per-call-site callee evaluation at PR #62) + the [PR #79](https://github.com/rigortype/rigor/pull/79) counter tables (reproduced in § Context — the decision evidence).

## Context

Repeated callee-body evaluation is the third-time-surfaced structural cold cost (ADR-57 ~+12% cold; ADR-24 WD5's deferred summary index; the PR #62 bisect step). The ADR-57 follow-up memo (`RETURN_MEMO_KEY`, `expression_typer.rb:1595-1770`) was believed to be run-scoped and sound; PR #79's counters + code trace corrected the picture on three points:

1. **The memo is effectively per-FILE.** Its bucket is keyed by the identity of `scope.discovered_def_nodes`, and `ScopeIndexer#merge_project_method_indexes` (`scope_indexer.rb:~155`) rebuilds that table per analyzed file (`.merge` → fresh identity), so hits never cross a file boundary. mail's `Mail::Part#has_content_type?` is evaluated **564×** (2 distinct keys) because every consumer file re-evaluates it. This per-file scoping is also why dependency recording is sound today: a within-file hit skips edges that are already recorded for that same consumer (same key ⇒ same deterministic evaluation ⇒ same read-set), and cross-file hits do not exist.
2. **The dominant refusal is the blanket unroll-in-flight candidacy exclusion.** On mail, 2,706 of 3,355 body evaluations (82%) happen while a constant-arg unroll frame is anywhere on the stack, which disables memo candidacy for every nested call regardless of whether the nested result was actually influenced by the transient machinery. rigor `lib`: 2,920 unroll refusals + 2,074 on-stack of 9,977 evals.
3. **Two hypothesized drivers measured dead**: `consult-tainted = 0` on all three targets (no ancestor chain is refused because a fixpoint summary was consulted), and distinct-key counts are ≤ 9 everywhere (no arg-granularity thrash).

Counter baseline (RIGOR_BUDGET_TRACE=1, `--workers 0`, cold):

| target | infer entries | hits / misses | body evals | on-stack / unroll / tainted |
|---|---:|---:|---:|---|
| rigor lib | 18,597 | 8,620 / 4,983 | 9,977 | 2,074 / 2,920 / 0 |
| mail lib | 5,836 | 2,481 / 617 | 3,355 | 32 / 2,706 / 0 |
| activestorage analyzers | 453 | 422 / 31 | 31 | 0 / 0 / 0 |

One further measurement binds the design: a naive "bypass the memo while `DependencyRecorder.active?`" was implemented and measured **>200×** slower on the analyzer-shaped subtree (0.43s → >90s) — within-file DAG dedup is exactly what the memo provides, and recording runs (ADR-46 baselines, `--verify-incremental`) cannot afford to lose it. The bypass was reverted; [PR #79](https://github.com/rigortype/rigor/pull/79) pins the current invariant with a property spec instead.

## Decision

Two-part criterion governing every change to the memo:

1. **Finality.** An entry may hold only a value that is a deterministic pure function of `(def_node, receiver, arg_types)` plus the frozen run-global index — never a value influenced by transient inference state. Transience is detected **post-hoc by event counters bracketing the compute** (the pattern the fixpoint consult counter established), never by blanket pre-gates over machinery that merely *might* have interfered.
2. **Observational equivalence for load-bearing consumers.** A memo hit must be indistinguishable from a fresh evaluation to every consumer that feeds diagnostics or incremental soundness: the returned type AND the ADR-46 recorded dependency edges. Cross-file hits therefore REQUIRE entry-attached read-set replay (WD2); a recording bypass is not an acceptable form (measured >200×). Advisory effects (provenance writes, trace counters) are explicitly non-load-bearing.

The recursion guard's key stays plain `(receiver, method)` (ADR-24 WD5); the ADR-55 transient-summary machinery is untouched.

## Working decisions

- **WD1 — counters + invariant pin (landed, [PR #79](https://github.com/rigortype/rigor/pull/79)).** `BudgetTrace` `MEMO_*` counters (entries / hits / misses / refusal split / body evals) + per-signature eval and distinct-key distributions; a property spec pinning "recorded edges are complete under recording with the memo active" for both the cross-file and within-file cases; an invariant comment at the memo naming the per-file-bucket dependency and the >200× bypass measurement. The naive bypass is the recorded rejected form.
- **WD2 — run-scoped bucket + dependency cache-and-replay.** Re-key the bucket to a run-stable identity (the runner's frozen project def-index object, or an explicit run-generation token reset in `Runner#run`) so hits cross files, and pair it — mandatorily, per criterion 2 — with read-set replay: when recording is active, the first evaluation of a key captures the recorder edges attributed during its body walk (a recorder sub-capture around `compute_user_method_return`), stores them on the entry, and a hit replays them into the current consumer's accumulator. Recording-off runs skip capture and replay entirely (recording is decided per run). Def-node identity note: a callee may carry two node identities per run (project-index parse vs the defining file's own analysis parse) — at most 2 entries per def, acceptable, verify empirically. Gate: byte-identical corpus (mail / kramdown / mastodon app-models / redmine app-models / rigor lib); counters showing the cross-file signatures collapse toward their distinct-key counts (mail `has_content_type?` 564 → ~2-4); a recording-run equivalence spec (edges identical to a memo-disabled run on a multi-file fixture); the analyzer subtree stays fast under recording.
- **WD3 — event-taint store gate replacing the blanket unroll exclusion.** Candidacy reduces to "signature not on the guard stack"; the store gate becomes: store iff, during the bracketed compute, (a) no unfinalized fixpoint summary was consulted (existing counter) AND (b) no transient-machinery event fired — recursion-guard hit, unroll-fuel exhaustion fallback, ADR-55 WD1 clamp, fixpoint-cap collapse. Mechanism: a thread-local transient-event counter incremented at the existing `BudgetTrace.hit` sites for those events (independent of `RIGOR_BUDGET_TRACE` enablement — the counter is load-bearing, the trace is not), bracket-compared like the consult counter. Soundness argument: any influence of transient state on a nested result manifests through one of those event paths; a compute whose bracket saw zero events ran to completion as if standalone, so its result is final (criterion 1). The implementer MUST audit every early-return / fallback in the recursion machinery (`compute_user_method_return` → `evaluate_guarded_user_method_body` → `fixpoint_user_method_return` and the unroll helpers) and place the counter at each — the audit list is spec-pinned so a future fallback cannot silently join untainted. Expected recovery: the mail 2,706-class and much of rigor-lib's 2,920-class convert to stores/hits (parser-shaped corpora are the beneficiaries). Gate: byte-identical corpus + counters (unroll-in-flight refusals → ~0, body evals on mail 3,355 → well under 1,500) + cold A/B wall/allocs on mail + rigor lib.
- **WD4 — measured-dead designs (do not re-chase without new counter evidence).** (a) A finalization-aware *summary*-taint gate (distinguish "consulted a summary that later finalized" from "embedded an unconverged iterate"): `consult-tainted = 0` on all three baseline targets — there is nothing to recover; WD3's event counter subsumes the sound part. (b) Param-read-mask key normalization (elide unread params' descriptors): distinct-key counts ≤ 9 corpus-wide — no thrash to collapse.
- **WD5 — fork scoping stands.** Per-worker memos under the fork pool (Thread.current, populated post-fork) remain; cross-fork sharing would serialize `Type` carriers for a boundary-only dedup (the ADR-67 ForkMap residual's adjudication). Re-open only on a profile showing worker-duplicated evaluation dominating a parallel run.

## Rejected alternatives

- **Recording bypass** (disable memo under `DependencyRecorder.active?`): implemented, measured >200× on analyzer-shaped files, reverted — recorded in WD1; criterion 2 forbids the form.
- **Key coarsening / eval-cap-then-widen** for hot signatures: changes returned types (folds disappear) → not byte-identical; precision-for-speed trades belong to the ADR-41 budget surface, not a silent memo policy.
- **Per-call-node result caching**: re-affirmed rejected (ADR-52 WD5 — scope-sensitive); this memo keys inputs, never nodes.

## Consequences

- Positive: the memo becomes what ADR-57 queued — actually run-scoped — with the incremental-soundness story strengthened rather than traded (replay is stronger than today's accidental per-file safety); the 82%-of-mail refusal mass gets a criterion-governed unlock; the counters make every future memo claim measurable; two dead designs are pinned against re-litigation.
- Negative: entries grow by a read-set under recording (bounded by the callee's transitive read surface; recording runs are opt-in); WD3's event counter adds one integer bump to four already-cold fallback paths; the WD2 replay machinery is new soundness-critical surface — its equivalence spec is the insurance.
- Carry-over: per-worker scoping (WD5); ADR-24 WD5 arity follow-up untouched.

## Relationship to other ADRs

[ADR-57](57-self-call-return-adoption.md) queued the sound result memo; this ADR delivers its cross-file form. [ADR-24](24-self-method-call-resolution.md) WD5's guard-key constraint is preserved verbatim. [ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5's rejection is reaffirmed and generalized into criterion 1's "inputs, never nodes". [ADR-55](55-recursive-return-precision.md)'s machinery is unchanged; WD3 counts its existing fallback events. [ADR-46](46-incremental-dependency-graph.md)'s deep edge is criterion 2's load-bearing consumer; WD2's replay is designed against it. [ADR-41](41-inference-budget-design.md) owns any future precision-for-speed trade this ADR refuses to smuggle in.
