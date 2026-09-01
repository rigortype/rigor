# ADR-56 — Block-captured local write-back and loop-body fixpoint (mutation-effect soundness)

Status: **Accepted, 2026-06-11. Slices A + B implemented 2026-06-11;
slice C (receiver-content element-type join, WD2.5) implemented 2026-06-12.**
Sequenced as slice A (block captured-local write-back — **landed**) then
slice B (loop-body fixpoint widening — **landed**). Unlike ADR-55 these
are **soundness fixes, not
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

**Implemented 2026-06-11.** `StatementEvaluator#write_back_block_captures`
runs after `record_closure_escape_if_any` in `eval_call`, gated on a
`:non_escaping` classification. The capped fixpoint lives in the new
shared `Inference::BodyFixpoint` (cap 3, parameterized over an
`evaluate_body` callable so slice B reuses it verbatim);
`captured_local_writes` now collects all five write forms;
`Type::Combinator.widen_value_pinned` (promoted from `ExpressionTyper`,
which now delegates) gained `Refined` / `IntegerRange` → nominal-base
widening so bounded-int accumulators converge. The non-convergence
collapse counts a new `BudgetTrace::BLOCK_WRITEBACK_CAP`. Gate: `make
verify` green (no new self-check / plugin-check firings); corpus
(Mastodon `app/models`, haml `lib`, kramdown `lib`) = **one removal,
zero new diagnostics** — the removal is a genuine win
(`form/account_batch.rb`'s `error ||= e`-in-`each` then
`raise error if error.present?` no longer folds to a wrong always-falsey
constant); perf neutral (lib self-check ~17.8s vs ~17.5s baseline).

### WD2 — Slice B: loop-body fixpoint

`eval_loop` (and the equivalent `until` path) replaces its single-pass
join with the same capped fixpoint over body-written locals: iterate
body evaluation from the joined scope until the join stabilizes (cap 3,
final-iteration value-pinned widening, per-local `Dynamic[top]` on
non-convergence). `d = 1; while …; d *= 2; end` → `1 | Integer`
(today's unsound `1 | 2`). Loop-carried narrowing on the predicate is
recomputed per iteration from the joined scope, so existing break /
exit-edge behaviour is preserved.

**Implemented 2026-06-11.** `StatementEvaluator#eval_loop` keeps the
historical single-pass join as the base (it still carries
receiver-mutation widening of non-rebound locals, body-introduced
nil-injection, and the loop value) and OVERLAYS a `BodyFixpoint.converge`
result for the locals the body rebinds. `loop_body_local_writes`
partitions body-written locals into pre-existing (seed = post-predicate
binding) and body-first (seed = `nil` for the 0-iteration path);
`loop_body_exit_bindings` re-applies the predicate's loop-entry edge
(`while`→truthy, `until`→falsey) per iteration so loop-carried narrowing
stays sound. A loop whose body rebinds no local stays byte-identical to
the single-pass join (fast path). Non-convergence (`g = [g]`) floors that
local to `Dynamic[top]` and counts a `BudgetTrace::BLOCK_WRITEBACK_CAP`
hit (shared with slice A). **One blind spot surfaced and was fixed
in-slice**: a body-first local seeded `nil` must NOT be overlaid into the
body re-evaluation — when the body runs it assigns the local before use,
and feeding the `nil` back leaks it past a condition-form assignment the
engine does not thread into the branch (`while …; if x > (count = 3);
(count + 1)…`), false-firing `+`/nil-receiver; the `nil` is kept only as
a join constituent for the 0-iteration result. Gate: `make verify` green
(no new self-check / plugin-check firings — the inherited
`expression_typer.rb:461-462` self-check firings the per-iteration
predicate-narrowing already resolves); probes confirm `d = 1; while …; d
*= 2; end` → `Integer` (was unsound `1 | 2`), `until` parity, body-first
→ `T?`, no-write loop byte-identical, compounding → `Dynamic[top]`;
corpus (Mastodon `app/models` 5/5, haml `lib` 13/13 byte-identical;
kramdown `lib` **two removals** — `converter/html.rb:455`'s
`item = stack.pop` inside `until stack.empty?` no longer wrongly folds to
a nil receiver — and five message-rewordings at identical sites
(`undefined method 'value' for nil` → `possible nil receiver` as the
receiver types `T | nil` not pure `nil`), zero new genuine firings).

### WD2.5 — Slice C: receiver-content element-type join (added 2026-06-12)

The 2026-06-12 Dynamic-fall survey
([`docs/notes/20260612-dynamic-fall-pattern-survey.md`](../notes/20260612-dynamic-fall-pattern-survey.md),
buckets B1/B3/B4) found the slice-A/B write-back covers local
**rebinding** but not receiver **content** mutation: `out = [0];
[1, 2, 3].each { |x| out << x }` types `Array[0]` (runtime
`[0, 1, 2, 3]`) — **unsound**, and it propagates
(`out.first.zero? → true`). The existing `MutationWidening` path widens
the variable but never joins the appended element type into the
collection's element parameter; a non-empty seed keeps only the seed's
elements. Slice C: when a non-escaping block body (or loop body)
invokes a content-mutating method (`<<`, `push`, `unshift`, `[]=`,
`concat`, `merge!`, String `<<`, …) on a captured outer local, the
continuation element/key/value/content type is the **join of the
pre-state content type and the mutated-in types**, computed under the
same `BodyFixpoint` cap/widen/floor discipline (the floor for content
is `Array[Dynamic[top]]` / the bare collection — already the sound
empty-seed behaviour). `each_with_object`'s return adopts the same
joined memo type (B3). The decision criterion above already covers
this — "rebind" reads as "rebind or content-mutate"; slice C is the
content half arriving.

**Implemented 2026-06-12.** Three composing seams, all reusing the
slice-A/B `MutationWidening` carrier-widening helpers:

1. **Blocks** — `StatementEvaluator#content_writeback_block_captures`
   runs in `eval_call` after `MutationWidening.widen_after_block` (which
   already forgets the literal arity but kept only the seed's elements).
   It walks the block body for content-mutator calls on captured outer
   locals (`MutationWidening::CONTENT_ADDERS` = Array `<< push append
   prepend unshift concat insert []= fill replace`, Hash `[]= store`,
   String `<< concat prepend insert replace`) plus index-write forms
   (`h[k] ||= v`), types each mutator's arguments in the block-entry
   scope, and JOINs the appended / stored element / key / value types
   into the continuation collection parameter via
   `MutationWidening.join_array_content` / `join_hash_content`. Pre-state
   is read from `post_scope`, so a local both rebound (slice A) and
   content-mutated composes. The empty-seed `Dynamic[top]` floor is
   dropped once real evidence exists (`out = []; arr.each { |x| out <<
   x*2 }` → `Array[Integer]`, not `Array[Integer | Dynamic[top]]`).

2. **Loops** — `eval_loop` overlays `loop_content_writeback` on both the
   fast-path single-pass join and the slice-B fixpoint result; arguments
   are typed against the fixpoint-widened `post_loop` so an appended loop
   counter reads `Integer`, not its entry constant.

3. **`each_with_object` return (B3)** — `each_with_object_return`
   computes the joined memo type from the memo block-param's content
   mutations and adopts it as the call's return, replacing the
   `Dynamic[top]` the dispatcher otherwise produces.

A String accumulator widens to the `String` nominal base (no element
parameter; the constant value is no longer sound). An index-write that
content-mutates a Hash through a nested collection (`h[k] ||= []; h[k] <<
v`) floors the value to `Dynamic[top]` but no longer leaves `h` an empty
`{}` (which folded `h.empty?` to a wrong `true`). Gate: `make verify`
green (no new self-check / plugin-check firings); a probe table confirms
all four survey repro shapes (`Array[0]` → `Array[0 | 1 | 2 | 3]`,
`out.first.zero?` no longer a wrong `true`, empty-seed → `Array[Integer]`,
`each_with_object` → the joined memo, Hash build → `Hash[K, V]`); corpus
(Mastodon `app/models` byte-identical; haml `lib` **one removal** —
`parser.rb:746`'s `dynamic_attributes << …`-in-`each` then
`dynamic_attributes == "{}"` no longer folds to a wrong always-falsey;
kramdown `lib` one message-rewording at an identical site
(`undefined method 'strip!' for nil` → `possible nil receiver` as the
receiver types `T | nil`), zero new genuine firings); perf neutral (lib
self-check ~19.9s). The `loop_body_fixpoint` fixture's `acc.push(m)` case
tightened from the imprecise-but-sound `Array[Dynamic[top]] | []` to
`Array[Integer]` (a slice-C precision win, fixture + spec updated).

**Generalized to straight-line code (2026-09-01, issue #560).** The
same under-coverage exists without a block: `u = [1, 2]; u.push(6)`
kept `Array[1 | 2]`, so `u.last == 6` folded to a constant and drew a
false always-falsey. The join is therefore no longer a block-path
mechanism, and its algebra moved out of `MutationWidening` into
`Rigor::Inference::ContentJoin` — `CONTENT_ADDERS`,
`array_added_elements`, `join_array_content`, `join_hash_content` — so
`widen_after_call` / `IndexWriteWidening.widen` and the block seams
above share one implementation rather than the second copy WD3 warns
about. The straight-line caller types the mutator's arguments in the
scope they are evaluated in and threads them as `arg_types:`; an
index-write node (`h[k] ||= v` and siblings) synthesizes the `[]=`
argument shape `[key, stored_value]`.

Three gates that the block path does not need bind the straight-line
one, and the third is the load-bearing one:

- **Seed admissibility.** Growing a carrier's element union can break
  a hand-written signature, because there the join's result reaches a
  `def`'s return check. haml's `temple = [:multi]; temple << [:static,
  s]` against `-> Array[:multi]` draws eight false
  `def.return-type-mismatch` if the appended tuple joins as itself,
  and PR #561 hit the same wall from the other direction. A member
  whose class the seed does not already carry therefore contributes
  `Dynamic[top]` instead. A gradual member does not rescue this on its
  own — `Array[:multi | [:static, String] | Dynamic[top]]` is still
  rejected, since every non-`Dynamic` member is judged separately — so
  the gate and the floor below are independent, and neither substitutes
  for the other.
- **Shape erasure on the added value.** A stored literal collection
  stays aliased and is mutated through the slot (`params[:f] ||= [];
  params[:f] << :status`), so its literal shape is erased along with
  its value pinning — `[]` joins as `Array[Dynamic[top]]`. Joining the
  literal `[]` would pin `Hash[Symbol, []]` on a hash whose slot holds
  `[:status]`, and `params[:f].empty?` would fold to a wrong `true`:
  the same class of stale fold the change exists to remove.
- **The straight-line join never CLOSES the parameter it feeds.** The
  widening is a one-way door — it leaves a `Nominal`, which
  `widen_for_mutator` declines — so this seam sees exactly ONE store
  and the next one is invisible. Closing over one sample of a growing
  population is a wrong type, not an imprecise one:

      a = []
      a.push(1)       # joins -> Array[Integer]
      a.push("s")     # DECLINED -- pre-state is a Nominal now
      a.last.upcase   # correct Ruby, prints "S"

  drew `undefined method 'upcase' for Integer`, and mail's
  `Message#to_yaml` is the same defect one carrier over. Every
  straight-line join therefore contributes `Dynamic[top]` alongside its
  evidence. That costs issue #560 nothing: a union carrying `Dynamic`
  cannot constant-fold, so the stale always-falsey folds the join
  exists to remove stay removed.

**The correction that matters for future readers.** A first attempt at
the rule above blamed the CARRIER: an Array's element union is over
positions and survives a missed store, a Hash's value union is over
keys and does not. The `a.last.upcase` probe refutes it — `a.last`
selects a position exactly as `hash[k]` selects a key, and a dropped
arm is a wrong answer either way. The real line is **how much the
joining path saw**, and it puts slice C on the other side of the same
rule rather than in tension with it: `content_writeback_block_captures`
and `loop_content_writeback` scan the WHOLE body and join every mutator
call in it before writing back, so their evidence is complete for that
body and their precise join stays justified. `acc = []; xs.each { |x|
acc.push(x) }` keeps reading `Array[Integer]`.

That split has one mechanical consequence worth recording:
`ContentJoin.drop_dynamic` now flattens `Union` members before
filtering. The straight-line floor reaches the slice-C re-derivation
nested inside a union (`Array[Dynamic[top] | Integer]`), where a
`grep_v` could not see it, and this ADR's own `acc.push(m)` loop result
silently became `Array[Dynamic[top] | Integer]`. Discarding it at that
seam is exactly right — the re-derivation saw every store, so the
straight-line path's admission of incompleteness does not apply to it.

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
