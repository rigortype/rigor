# ADR-129 — Remember `type_of` results per scope and node

Status: **Proposed, 2026-11-04.** A design for [#2709](https://github.com/rigortype/rigor/issues/2709), put to the
maintainer before any code lands. Nothing is implemented. A measurement prototype without the store gate lives on
branch `type-of-memo-prototype` and is not for merge.

Grounding: [`20261104-work-multiplier-census.md`](../notes/20261104-work-multiplier-census.md) (the census and the
local prototype A/B); CI runs `engine-warm` 41710749117 (Mastodon) and `engine-wall` 41710743554 (Rigor's `lib`).

## Context

Profiling-driven tuning ran out in [#1507](https://github.com/rigortype/rigor/issues/1507): the remaining cost reads
as "feature cost spread thin". A census of repeated work found that much of that cost is the engine deriving the same
type again. Two things cause it:

- The main pass records each node's entry scope, not its type (`ScopeIndexer#recording_evaluator`,
  `lib/rigor/inference/scope_indexer.rb:230`).
- `Scope#type_of` builds a fresh `ExpressionTyper` per query (`lib/rigor/scope.rb:2363`). About ten rules then check
  each call node (`lib/rigor/analysis/check_rules.rb:303`), and several re-type the receiver chain on their own.

On Mastodon, 74% of `type_of` calls repeat an identical `(scope object, node)` pair. On Rigor's `lib` it is 41%.

A prototype memo keyed on that pair, with no store gate, gave these results:

| corpus | wall (CI, 5 runs each, alternated) | allocations | diagnostics |
| --- | --- | ---: | --- |
| Mastodon, leaf / hub edit | −13.0% / −13.8%, separated | −34% (local) | identical (2,783 rows, local strict run) |
| Redmine | local only: −18% CPU | −24% (local) | identical (1,844 rows, local strict run) |
| Rigor's `lib` | −2.9%, not separated | −11% (CI) | identical (one output digest across all ten CI runs) |

The memo is not free to build soundly, because typing is less pure than its contract says.

- **The fixpoint breaks the purity rule.** [`inference-engine.md`](../internal-spec/inference-engine.md) § "The
  `Scope#type_of(node)` Contract" says the same `(scope, node)` pair gives equal results within a run. The ADR-55
  fixpoint evaluates one body scope up to three times under a changing summary
  (`ExpressionTyper#fixpoint_user_method_return`, `lib/rigor/inference/expression_typer.rb:3749`), so the rule does
  not hold today.
- **Typing has outputs besides its value.** It pushes into the return, next, break, break-value and provisional-return
  sinks (`lib/rigor/inference/statement_evaluator.rb:197`–`265`). It logs ADR-84 transient events
  (`note_transient_fallback`, `expression_typer.rb:3692`). Under `--incremental` it records ADR-46 dependency reads.
- **Typing reads ambient inputs.** These are the threaded operand table, the tracer, the key-presence guard walk with
  its isolated side tables (`scope.rb:414`), the yield-value and forwarded-argument frames (`expression_typer.rb:384`,
  `:414`), the threaded-block-body flag (`:4819`) and the reflective-ivar repeating depth
  (`reflective_ivar_write.rb:29`).

[ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5 rejected a per-call-node cache of plugin contribution
results, because those results depend on the narrowing state at consultation time. A `Scope` is immutable, and every
transition allocates a new one, so keying on the scope's identity puts the narrowing state in the key.

## Decision

Memoise `ExpressionTyper#type_of` per file, keyed by the identity of the scope and of the node. Store a result only
when computing it was silent.

**Criterion:** a typing result may be served again only for the same scope object and the same node, and only if its
computation produced nothing but its value and read no ambient input outside the key. A computation that wrote a sink,
logged a transient event, recorded a dependency, or ran under a non-default ambient input is recomputed every time.
Computations below it that were silent are still served.

## Working decisions

- **WD1 — Key and lifetime.** The key is the scope and the node, compared by identity, for Prism nodes only. Virtual
  AST nodes are minted per use and are skipped. The table is cleared when `Runner#analyze_file_body` finishes and is
  registered in `RunScopedSlots`, so neither a finished run nor a language-server thread keeps it.
- **WD2 — No lookup and no store** while any of these holds:
  - a threaded operand table is present;
  - a tracer or `FlowTracer` is active, since lens and `--explain` read its events;
  - the key-presence guard walk is running;
  - ADR-46 dependency recording is active, so recording runs behave exactly as today.
  Slice 1 adds one more: the memo is off inside user-method inference, while the recursion-guard stack is non-empty.
- **WD3 — The silent-compute store gate.** At entry, snapshot the sizes of the five sinks, the length of the transient
  event log, and the values of the frames WD2 does not bypass. Store at exit only if all of them are unchanged.
  - An enclosing computation sees the same change, so it is not stored either.
  - A hit needs no replay, because a stored result was silent by construction.
  - This is ADR-84 WD3's bracket applied per node. Every in-cycle consult of an ADR-55 summary logs a transient event
    (`expression_typer.rb:3563`), so a result built on an unconverged iterate is never stored.
- **WD4 — A fixpoint iteration gets its own scope (slice 2).** `fixpoint_user_method_return` builds a fresh body scope
  for each iteration, so no scope object sees two assumptions and the purity rule holds again for flow state. WD3
  already refuses the in-cycle results; WD4 makes the separation structural rather than a consequence of event
  bookkeeping.
- **WD5 — An ambient-input census.** A spec enumerates every `Thread.current` key read under `lib/rigor/inference` and
  `lib/rigor/scope.rb`. Each must be bypassed (WD2), snapshotted (WD3), or on an allow-list with its reason. The
  precedent is `spec/rigor/run_scoped_slots_spec.rb`. A new thread-local then fails a test instead of relying on a
  reviewer to notice it.
- **WD6 — Two slices, each with the same landing gate.**
  - Slice 1 covers the main pass and the rule walk.
  - Slice 2 covers callee bodies and brings WD4.
  - Each slice lands only when all of these hold:
    - `--format json --no-cache` is byte-identical with the memo on and off over `lib`, `plugins/*/lib`,
      `examples/*/lib`, and Mastodon, Redmine and GitLab `app/models` (strict profile, no baseline);
    - warm output equals cold;
    - `--verify-incremental` passes;
    - the `engine-warm` A/B separates;
    - a fixture whose fixpoint return arm appears only in a later iteration fails with the gate removed and passes
      with it.
- **WD7 — The contract text.** The purity rule is restated per `(scope, node, ambient inputs)`, and the spec lists the
  ambient inputs. This PR corrects the two statements that are wrong today: the fixpoint exception, and
  `optimistic_origins` being read back into typing. The WD4 rule enters the spec with slice 2.

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| Key on the node alone | The answer depends on the narrowing state (ADR-52 WD5) |
| Key on the scope's structure (`Scope#hash`) | Hashing carriers measured a net loss even as a sort key (20260713 campaign note). Identity is one probe |
| Record a computation's side effects and replay them on a hit | Needs ADR-84 WD2's read-set machinery for each of 10⁵–10⁶ entries. The silent gate gives up only the nodes that carry effects |
| Keep the table for the whole run | Scopes belong to one file, so another file never hits, and the retained heap grows (GC already rose 8% on `lib` in CI) |
| Memoise during `--incremental` recording | Each entry would need a captured read set. Deferred; recording runs stay as they are |
| Abstract the callee memo's key (widen argument types after k keys) | Changes inferred types and diagnostics; out of scope for an output-identical change |
| Seed the return memo from the main pass (#2710) | Measured under 1% of callee CPU, and 5% of matching keys disagree |

## Consequences

- **Gains.** On the Rails corpora, the prototype cut wall by 12–14% on CI and allocations by 24–34%. The rule walk
  halves, and the quadratic re-typing of receiver chains across rules goes away.
- **Costs.**
  - Each file's table holds its types until the file ends. On `lib` in CI, GC time rose 8%.
  - Every future thread-local is subject to a new invariant. WD5 turns a violation into a failing test.
  - Code shaped like Rigor's own `lib` gains little: −3% wall, not separated. Its cost is callee-body multiplicity,
    which #1228 (generalised, re-measured after slice 2) and #2711 address.
- **Unchanged.** The ADR-84 return memo, the ADR-45 run-result cache and every cache format.

## Relationship to other ADRs

- [ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5 — its objection is answered by the identity key; its
  conclusion for plugin contribution caches stands.
- [ADR-55](55-recursive-return-precision.md) — WD4 changes how its fixpoint holds the body scope, not what it
  computes.
- [ADR-84](84-cross-file-return-memo-scoping.md) — WD3 reuses its event-bracket store gate. Its WD4(b), the
  parameter-read mask, stays rejected: the census measured it at 1–3% of evaluations.
- [ADR-46](46-incremental-dependency-graph.md) — recording runs bypass the memo (WD2).
