# ADR-56 — Block-captured local write-back and loop-body fixpoint (mutation-effect soundness)

Status: **Accepted, 2026-06-11.** Nothing implemented yet; sequenced as
slice A (block captured-local write-back) then slice B (loop-body
fixpoint widening). Unlike ADR-55 these are **soundness fixes, not
precision additions** — today's results are *wrong*, not merely wide —
so the corpus gate's "zero new diagnostics" reading is softened to
"every new diagnostic is adjudicated" (see WD4).

Archetype: deliberative. Stakes: high (flow-engine core; the current
behaviour violates a spec MUST; the fix moves folded constants that
other diagnostics consume).

## Context

The flow engine evaluates every block body
(`StatementEvaluator#evaluate_block_if_present`,
`lib/rigor/inference/statement_evaluator.rb` ~L1583) but **discards the
block's exit scope**. The closure-escape model
(`record_closure_escape_if_any` ~L1608) widens captured locals to
`Dynamic[top]` only for `:escaping` blocks; a `:non_escaping`
classification (each / times / upto / map …) leaves the post-call scope
**unchanged**. Consequence:

```ruby
result = 1
1.upto(6) { |i| result *= i }
result  # typed Constant[1] — runtime value is 720. UNSOUND.

e = 1
[1].each { e = 99 }
e       # typed Constant[1] — runtime value is 99. UNSOUND.
```

Every block-capture write form is dropped (`=`, `+=`, `*=`, multi-
assign; Integer and String alike). `while` is adjacent but distinct:
`eval_loop` (~L811) joins pre-scope with **one** body pass
(`d = 1; while …; d *= 2; end` → `1 | 2`, missing `4, 8, …`).

The spec already decides this:
[`control-flow-analysis.md`](../type-specification/control-flow-analysis.md)
§ "Fact stability and mutation" — *"Rigor MUST invalidate or weaken
facts when Ruby behavior can mutate, replace, or escape the observed
target"*, with **captured local facts** named as a first-class
category, and § call-timing — *"immediate non-escaping invocation,
unknown number of times"* is exactly the each/upto case. The
implementation violates the MUST; this ADR is the catch-up, not a new
policy. `MutationWidening.widen_after_block` (receiver mutation,
`arr << x`) and ivar writes inside blocks are already handled — the gap
is specifically **local rebinding** in non-escaping blocks.

## Decision

> **A captured outer local that a block body (or loop body) can rebind
> must never keep its pre-call binding unmodified in the continuation
> scope.** The continuation binding is the pre-state joined with a
> conservatively widened post-iteration state — computed by a capped
> fixpoint because the body may run 0..N times and compound — and any
> non-convergence degrades that local (and only that local) to
> `Dynamic[top]`, which is the established escaping-block floor.

### WD1 — Slice A: non-escaping block captured-local write-back

After `sub_eval(block, block_entry)`, capture the block's exit scope.
For every outer local the block body writes (extend
`captured_local_writes` ~L1652 — today it sees only
`LocalVariableWriteNode` — to `LocalVariableOperatorWriteNode`,
`LocalVariableOrWriteNode`, `LocalVariableAndWriteNode`,
`LocalVariableTargetNode` under `MultiWriteNode`), compute the
continuation binding as a **capped fixpoint** (cap 3, the ADR-55
shape): seed = pre-call binding; iterate "evaluate block body with the
current binding, join the written local's exit type back"; widen
value-pinned constituents to their nominal base on the final permitted
iteration; if still unstable, that local → `Dynamic[top]`. The
0-iteration case is covered because the pre-call binding stays a join
constituent throughout. Unwritten locals keep their bindings untouched
(the spec's "preserve unrelated local-binding facts"). The
`:escaping`/`:unknown` paths are unchanged (already Dynamic).

Expected observables: `result` after the `upto` block → `1 | Integer`
(or `Integer`), never `Constant[1]`; `e` after `[1].each { e = 99 }` →
`1 | 99`.

### WD2 — Slice B: loop-body fixpoint

`eval_loop` (and the equivalent `until` path) replaces its single-pass
join with the same capped fixpoint over body-written locals: iterate
body evaluation from the joined scope until the join stabilizes (cap 3,
final-iteration value-pinned widening, per-local `Dynamic[top]` on
non-convergence). `d = 1; while …; d *= 2; end` → `1 | Integer`
(today's unsound `1 | 2`). Loop-carried narrowing on the predicate is
recomputed per iteration from the joined scope, so existing break /
exit-edge behaviour is preserved.

### WD3 — One mechanism, shared

Slices A and B implement **one** fixpoint helper (body-evaluator +
written-locals set + cap + widen policy as inputs), not two copies —
the ADR-55 hand-copied-constructor lesson (two silent table-drop bugs)
applies. Budget caps are hard and non-configurable (ADR-41 WD4); a new
`BudgetTrace` counter records non-convergence collapses.

### WD4 — Gate: adjudicated, not zero-delta

`make verify` + corpus runs (Mastodon `app/models`, haml, jbuilder,
kramdown) per slice, plus hand-probed discriminating shapes (the
ADR-55 lesson: byte-identical corpora missed a `bot` soundness bug —
dump-type probes are part of the gate, not optional). Because the fix
*corrects wrong constants*, new diagnostics are possible and may be
**genuine** (code that truly can see nil / a wider type) — each new
firing is adjudicated: genuine → keep, with the firing recorded in the
slice notes; engine-artifact (a blind spot newly unmasked) → fix or
narrow before landing. Diagnostic *removals* are expected wins (they
were latent wrong-constant FPs). Perf must stay neutral: block bodies
re-evaluate up to cap× only when they write captured locals — the
overwhelming majority of blocks write none and take one evaluation as
today.

## Rejected / deferred alternatives

- **Blanket "any block invalidates captured locals to Dynamic".**
  Rejected — the spec explicitly prefers call-timing modelling over
  "yield invalidates everything", and it would destroy narrowing
  precision across every each/map in every corpus.
- **Single-pass join (no fixpoint), widen-to-nominal always.**
  Rejected as the primary mechanism — compounding shapes
  (`a = [a]`-style structural growth) escape a single pass; the capped
  fixpoint with a Dynamic floor is strictly safer and reuses the
  ADR-55 pattern. (A first implementation MAY land single-pass +
  widen as the iteration-1 body of the same helper, but the cap/floor
  must exist from the start.)
- **Treat `:non_escaping` blocks as 1-shot (adopt exit scope
  directly).** Rejected — unsound for 0-iteration paths (`[].each`)
  and N-iteration compounding.
- **Per-method iteration-count summaries (each = N, tap = 1, …).**
  Deferred — the spec's call-timing categories invite this, but the
  join-with-pre-state fixpoint is sound without them; summaries are a
  later precision refinement (e.g. `tap` exact-once adopting the exit
  scope).

## Consequences

- `fact3`-style accumulator loops stop producing wrong constants — the
  largest known class of unsound folds in the engine; downstream
  always-truthy / reachability diagnostics stop consuming them.
- Some currently-folded constants widen; any diagnostic that silently
  depended on a wrong fold surfaces and is adjudicated (WD4).
- The implementation finally satisfies the captured-local MUST in
  § "Fact stability and mutation"; the spec needs no change.

## Relationship to other ADRs

- **ADR-55** — supplies the capped-fixpoint + final-widen + collapse
  pattern and the gate discipline (corpus + discriminating probes);
  this ADR generalizes it from recursive returns to iteration state.
- **ADR-41** — the caps are hard termination guards (WD4); the new
  collapse counter joins `RIGOR_BUDGET_TRACE`.
- **ADR-5 / FP discipline** — widening wrong constants is the
  FP-discipline-correct direction; WD4's adjudication keeps the
  envelope honest where corrected types legitimately fire.
