# ADR-129 — Remember `type_of` results during the rule walk

Status: **Proposed, 2026-11-04.** A design for [#2709](https://github.com/rigortype/rigor/issues/2709), put to the
maintainer before any code lands. Nothing is implemented. Revised after its first review, which showed that a memo
spanning the main pass serves wrong types (§ Context). A measurement prototype of this design lives on branch
`type-of-memo-prototype` (42103062f) and is not for merge.

Grounding:
- [`20261104-work-multiplier-census.md`](../notes/20261104-work-multiplier-census.md), the census;
- CI `engine-warm` 41721180857 and `engine-wall` 41721187705, which measured this design;
- CI 41710749117 and 41710743554, which measured the rejected first design.

## Context

Profiling-driven tuning ran out in [#1507](https://github.com/rigortype/rigor/issues/1507): the remaining cost reads
as "feature cost spread thin". A census of repeated work found much of it is the engine deriving the same type again.

- The main pass records each node's entry scope, not its type (`ScopeIndexer#recording_evaluator`,
  `lib/rigor/inference/scope_indexer.rb:230`).
- `Scope#type_of` builds a fresh `ExpressionTyper` per query (`lib/rigor/scope.rb:2363`).
- About ten rules then check each call node (`lib/rigor/analysis/check_rules.rb:303`), and several re-type the
  receiver chain independently.

On Mastodon, 74% of `type_of` calls repeat an identical `(scope object, node)` pair, and the rule walk makes 45% of all
the calls.

Typing is less pure than its contract said, and that decides where a memo can live.

- **Outputs besides the value.**
  - Typing pushes into the return, next, break, break-value, provisional-return and retry sinks
    (`lib/rigor/inference/statement_evaluator.rb:197`–`265`, `:2917`).
  - It logs ADR-84 transient events (`note_transient_fallback`, `expression_typer.rb:3692`) and, under
    `--incremental`, ADR-46 dependency reads.
  - It writes four node-keyed tables reached through the scope: `dynamic_origins`, `void_origins`,
    `plugin_typed_calls` and `optimistic_origins` (`scope.rb:298`, `:308`, `:320`, `:406`). Each is last-write-wins,
    and only `dynamic_origins` follows a callee body (`expression_typer.rb:4069`).
- **Ambient inputs.** These are the frames above, the yield-value and forwarded-argument frames
  (`expression_typer.rb:384`, `:414`), the threaded-block-body flag (`:4819`), the reflective-ivar repeating depth
  (`reflective_ivar_write.rb:29`), the recursion guard with its summaries and unroll fuel, the key-presence guard
  walk, the operand table and the tracer. All the frames are installed with `begin`/`ensure`. So they are back at
  their entry values by the time `type_of` returns, and comparing them before and after a computation detects
  nothing.
- **Shared identity.** `Scope#entering_opaque_block` returns `self` once the scope is opaque (`scope.rb:638`). A block
  nested in another block therefore enters with the enclosing scope object, and the value pass (flag on) and the
  statement pass (flag off) type the same `(scope, node)` pair under different frames.

The first design memoised everywhere. Its prototype cut Mastodon's re-analysis wall by 13% on CI, but it is wrong. In
the shape below it served the value pass's `[Dynamic[top], Dynamic[top]]` to the statement pass, which types
`["1", "2"]`, and the real `call.undefined-method` at 6:17 was lost:

```ruby
items.each do |a|
  items.each do
    t = [1, 2].map { |e| u = e.to_s; u }
    t.first.no_such_method_on_string
  end
end
```

That prototype also passed byte-identity on Mastodon, Redmine and `lib`, so a corpus diff cannot detect this class of
error.

By the time the rule walk runs, the main pass is over. No sink or frame is installed, the recursion guard is empty, and
no fixpoint is in flight. Every input outside the key is at its default by construction.

## Decision

Memoise `ExpressionTyper#type_of` only inside the rule walk. Key it by the identity of the scope and of the node, keep
it shut whenever any ambient input is off its default, and replay a stored computation's table writes on a hit.

**Criterion:** a typing result may be served again only for the same scope object and node, in the same ambient state,
with every table write it made replayed. A memo may open only where that state is the default by construction, never
where frames can differ for one scope object. Within the engine, that place is the rule walk.

## Working decisions

- **WD1 — The window.** The memo opens around the rule walk:
  `Runner#rule_and_plugin_diagnostics` (`lib/rigor/analysis/runner.rb:2785`) and the same span of
  `WorkerSession#analyze_body` (`lib/rigor/analysis/worker_session.rb:230`). The table is emptied when the window
  opens and when it closes, and it is registered in `RunScopedSlots`. Outside a window the memo is off. That covers
  the main pass, sig-gen, the lens, `type-of` and editor hovers.
- **WD2 — Shut inside the window** while any of these holds:
  - a sink or retry frame is installed;
  - a yield-value or forwarded-argument frame is set;
  - the threaded-block-body flag is on, or the reflective-ivar depth is non-zero;
  - the recursion-guard stack is non-empty, so a callee inference a rule starts runs unmemoised, with its summaries
    and unroll fuel;
  - the key-presence guard walk is running;
  - ADR-46 dependency recording is active;
  - a tracer or `FlowTracer` is active;
  - the typer threads an operand table;
  - the node is not a Prism node.
- **WD3 — No store across a transient event.** A computation during which any transient event was logged is not stored
  (a monotonic count, since the event log is cleared when the guard stack drains). This is stricter than ADR-84 WD3,
  which refuses only events below the entry depth.
- **WD4 — Replay the table writes.** While a computation runs, every write to the four tables, through
  `record_dynamic_origin`, `record_void_origin`, `record_plugin_typed_call` or `record_optimistic_origin`, is
  appended to each open capture. A hit replays its entry's writes in order on the scopes that received them, which
  restores last-write-wins exactly. The other output channels need no replay, because they are first-write-wins or
  deduplicated within the window: `Effects::Collector`, `SelfCallResolutionRecorder`, `LoopValueRecord` and the
  inject-accumulator record. Known residual: a stored computation that read an `optimistic_origins` mark another
  query wrote after the store. The coverage parity in WD6 watches it; no case is known.
- **WD5 — An ambient-input census.** A spec enumerates every `Thread.current` key under `lib/rigor/inference`,
  `lib/rigor/scope.rb`, `lib/rigor/analysis` and `lib/rigor/effects`, and every node-keyed table reachable from a
  `Scope`. Each must shut the memo (WD2), be counted (WD3), be replayed (WD4), or be on an allow-list with its reason.
  The precedent is `spec/rigor/run_scoped_slots_spec.rb`. A new input then fails a test instead of relying on a
  reviewer to notice it.
- **WD6 — The landing gate.**
  - `--format json --no-cache` is byte-identical with the memo on and off over `lib`, `plugins/*/lib`,
    `examples/*/lib`, `spec/integration/fixtures`, and Mastodon, Redmine and GitLab `app/models` (strict profile, no
    baseline);
  - `rigor coverage --protection --format json` is byte-identical on Mastodon and Redmine;
  - `--workers=2` gives the same output as `--workers=0`;
  - warm output equals cold, and `--verify-incremental` passes;
  - one fixture per WD2 input passes with the memo on, the example above among them, and fails if that input is
    dropped from WD2;
  - `engine-warm` separates on Mastodon.
- **WD7 — The contract text.** This PR corrects [`inference-engine.md`](../internal-spec/inference-engine.md) where it
  is wrong today:
  - the purity rule holds per `(scope, node, ambient inputs)` and lists them;
  - the ADR-55 fixpoint and the shared `optimistic_origins` table both break it;
  - § "Determinism and Caching" allows identity-keyed caches only on those terms and forbids `==`-keyed ones, because
    `Scope#==` ignores fields typing reads;
  - the advisory-table paragraph names `plugin_typed_calls`, last-write-wins and the body boundary.
  `LoopValueRecord` (#2031, #2262) and the inject-accumulator record (#1889) are the precedent identity caches.

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| Memoise everywhere, gating stores on frames being unchanged (the first design) | The comparison detects nothing (frames are restored by `ensure`), and one scope object is typed under different frames. It lost a real diagnostic, and the corpus gate missed it |
| Memoise the main pass and callee bodies with the frames and sink presence in the key | The remaining ~8% of the first design's gain. Correctness would rest entirely on the WD5 census, since a corpus diff cannot detect this class of error. Deferred to its own amendment and measurement |
| Key on the node alone | The answer depends on the narrowing state (ADR-52 WD5) |
| Key on the scope's structure (`Scope#==`) | Unsound: `==` ignores fields typing reads, among them the discovery index, the lexical nesting, the block-self marks, the declared refinements and the fold-safe locals. It is also slower: hashing carriers measured a net loss |
| Keep the table across files or the whole run | Scopes belong to one file, so a cross-file hit is impossible, and retention grows |
| Memoise during `--incremental` recording | Each entry would need a captured read set; recording runs stay as they are |
| Abstract the callee memo's key, or seed it from the main pass (#2710) | The first changes diagnostics. The second measured under 1% of callee CPU, with 5% of matching keys disagreeing |

## Consequences

- **Gains,** measured with prototype v2.
  - Mastodon re-analysis on CI: −5.9% wall (leaf edit, separated) and −4.0% (hub edit, not separated).
  - A cold Mastodon run: −10.2% from one sample.
  - Rigor's `lib`: −0.3% wall, not separated, and −2.5% allocations.
  - Output is identical on every WD6 corpus checked (`check`, `coverage --protection`, `--workers=2`, the spec
    fixtures).
  - The gain grows with the number of rules and plugins that re-type a receiver.
- **Costs.**
  - Four table writers gain a capture append.
  - The rule walk holds a per-file table.
  - Every future ambient input is subject to an invariant, which WD5 enforces.
- **Not covered.** The main pass and callee bodies carry most of the repeated work (the first design's −13% against
  this one's −4 to −6%), and so does code shaped like Rigor's `lib`. #1228 (generalised) and #2711 stay open, and so
  does a context-keyed extension.

## Relationship to other ADRs

- [ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5: answered by the identity key and the window. Its
  conclusion for plugin contribution caches stands.
- [ADR-55](55-recursive-return-precision.md): its fixpoint runs only inside callee inference, which WD2 keeps shut.
- [ADR-56](56-block-captured-local-mutation.md): `BodyFixpoint` passes run in the main pass, outside the window.
- [ADR-84](84-cross-file-return-memo-scoping.md): WD3 is a stricter form of its event bracket. Its WD4(b), the
  parameter-read mask, stays rejected; the census measured it at 1–3% of evaluations.
- [ADR-46](46-incremental-dependency-graph.md): recording runs keep the memo shut (WD2).
