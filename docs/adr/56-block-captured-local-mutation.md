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
   *(Superseded by WD2.9: the seed is now read from the scope BEFORE
   `widen_after_block` runs, so an empty literal contributes no element
   and nothing is dropped — the same `Array[Integer]` by a route that
   cannot mistake a declared `untyped` for the floor.)*

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

That split has one mechanical consequence worth recording, and one
false path worth recording alongside it. The straight-line floor can
reach the LOOP re-derivation through `post_loop`, whose binding already
carries the in-body join's output — re-deriving on top of it is
derivation on derived output. The shipped fix is at that source:
`loop_content_writeback` seeds each name the loop does not rebind from
the pre-body scope (`post_pred`), so the floor never enters its input;
a name the loop also rebinds keeps reading `post_loop` (the slice-B/C
composition), where a surviving floor costs precision, never
correctness. `ContentJoin.drop_dynamic` stayed a plain `grep_v` over
top-level members (until WD2.9 removed it outright). The false path:
an earlier head instead flattened `Union` members inside
`drop_dynamic`, which cleared this seam but dropped
DECLARATION-sourced gradual arms everywhere else — a declared
`Array[Integer | untyped]` parameter closed to `Array[Integer]` under
block mutation and fired on correct code. The
`keeps_declared_gradual_arm` fixture pins the survival of such arms;
distinguishing floor-Dynamic from declared-Dynamic properly is #580's
provenance mark, deliberately not built here.

### WD2.6 — A mutator whose arguments carry no evidence takes the one-store gradual arm (2026-09-02, issue #580)

WD2.5's join reads the mutator's arguments. When it can read nothing
out of them, the widening previously kept the seed's elements exactly:
`m = [1, 2]; m.concat(xs)` stayed `Array[1 | 2]`, and `m.last == 6`
constant-folded to false on code whose runtime value really is 6. The
mutation ran, so the retained constants were falsified whether or not
the analyzer could say by what — the same stale-evidence family as
#540 / #541 / #544 / #560, reached through a different door. The
surviving elements keep their pinning and gain a gradual arm.

Such a store is treated as ONE UNREADABLE STORE and runs the ordinary
one-store pipeline: no admitted evidence, plus WD2.5's `Dynamic[top]`
arm. `m` reads `Array[1 | 2 | Dynamic[top]]`. Closing it instead — to
the seed's nominal base, which a first cut did — violates WD2.5's own
rule that a seam seeing one store may never close the parameter, and
costs exactly what that rule protects: `Array[Symbol]` under haml's
hand-written `-> Array[:multi]` brings back the #561
`def.return-type-mismatch`, and a post-concat `m.last.upcase` draws
`undefined method` on code that is correct when the argument holds
strings. Both are now pinned as fixtures, since the fold assertion
alone cannot see either.

The discriminator is `arg_types` being NON-EMPTY while the extracted
evidence is empty: real arguments the extractor could not read. An
EMPTY `arg_types` means no argument machinery reached the call, and
leaves the carrier untouched. The block-capture path of WD2.5 is the
producer that matters there — it passes none because its slice-C join
re-adds the appended types afterwards, and touching the carrier would
strip seed pinning it keeps on purpose (`out = [0]; arr.each { out <<
x }` must stay `0 | …`) — but it is not the only one: a zero-arg adder
(`m.concat`) and the argument typer's own rescue land there too, and
leaving the carrier alone is right for them as well.

Known and accepted false negative: `m.concat([])` is a runtime no-op,
so `m.last == 6` after it really is always false, and the `Dynamic`
arm suppresses a CORRECT always-falsey. A false negative on a no-op
call is a better trade than the two false positives above.

This is one of the two residuals recorded on #580. The other, alias
blindness (`b = a; a.push(6); b.last == 6`), is untouched: it needs the
receiver-alias set to write through to every alias. The issue's own
subject — re-joining a widened `Nominal` so later stores accumulate —
also remains open; the evidence from the attempt, including why a
scope-side provenance mark cannot carry the signature protection across
a method return, is recorded on the issue.

### WD2.7 — A merge revoked struct fold-safety (2026-09-02, issue #589)

Reported as "a `while` loop erases a struct local's carrier even when
the body never touches it", and expected to be a loop-seam widening
problem in this ADR's territory. It was neither.

The carrier survives the merge intact — `s` still reads
`S(raw: "r")` there. What was lost is the GRANT that lets a member
read consult it: `Scope#join` omitted `struct_fold_safe_locals` from
its constructor call, so it fell back to the empty default. Every
merge in a method body silently revoked struct member folding for
everything after it, and an `if` did it exactly as a `while` did —
this was never loop-specific. The grant is now intersected across the
merge (both arms normally carry the identical set, since it is a
static scan over the method root; intersecting is the FP-safe
direction, because the grant licenses a fold).

Nothing about fold SAFETY moved. The static scan already disqualifies
a local whose setter sits inside a loop or block (`deferred_setter`),
one the body rebinds, and one that escapes; the join was discarding
that scan's answer rather than contradicting it. All three still
decline, and folding now also holds across this ADR's loop fixpoint
rather than for a single pass.

Restoring the grant did expose a real gap in that scan, fixed in the
same change. The scan's counting identity is about the LOCAL and says
nothing about a member read's RESULT: `s.x << v` mutates the container
`s.x` returns while `s.x` is a textbook pure read, so the local stayed
fold-safe while its member's value changed underneath. A local whose
member-read result is itself a receiver is now disqualified outright,
with no allow-list of its own — `s.x.to_s` loses precision for
nothing, but an allow-list is what produced the bug, and being too
broad only costs a `Dynamic[top]`. That also removes a pre-existing
false positive on the straight-line form, which fired before this
branch existed. The scan header's claim that a missed case is "never
unsound" was false and is corrected there. Remaining residual: #597.

**The payoff was measured and it is NOT mail's ragel cluster**, which
the issue named as the target. Both of that file's structs are
excluded for reasons this fix does not touch:
`address` takes 131 member setters INSIDE the ragel `while`, so
`deferred_setter` disqualifies it — and that gate is load-bearing
(#525's sibling verified that removing it serves a stale `nil`);
`address_list` is returned twice as a bare read, so the escape rule
disqualifies it. Zero of the ~250 sites unlock. What DOES unlock is
every struct local a merge previously revoked: a member read after an
untouching `if` or `while`, and an ADR-48 slice-4 setter write-back
surviving one. Reaching mail needs a different lever — modelling an
in-loop setter's per-iteration effect — not this one.

### WD2.8 — Why the loop join is NOT a per-iteration summary (2026-09-02, issue #597)

WD2.7 leaves every member read of a struct local that takes a setter
inside a loop answering `Dynamic[top]`, via `StructFoldSafety`'s
all-or-nothing `deferred_setter` gate. #597 proposed replacing that
gate with a per-iteration summary. **The attempt was made, measured,
and withdrawn**; this records why, so it is not re-derived.

The tempting observation is that `eval_loop` already joins the body's
exit scope with the pre-loop scope, so a setter's effect looks like it
reaches the continuation as "the loop ran" unioned with "it did not" —
apparently the summary the gate stands in for. Two changes make that
readable: stop treating `while` / `until` as deferred boundaries, and
let a member read see through a union of same-class `StructInstance`s.
Both were implemented, and on the obvious shapes they do exactly what
the issue asks (a set member reads `1 | 9`, an unset sibling stays `2`).

**That join is a single unrolling, not a summary**, and the difference
is not cosmetic. Four probes each fold to a value the program never
holds — the worst failure class here, because a wrong precise type
feeds every downstream rule silently:

- **Loop-carried member state.** `p.x = p.y; p.y = 5` in a `while`
  reads `1 | 2`; the runtime holds 5. `loop_body_local_writes` keys
  slice-B's fixpoint on local WRITE nodes, so a setter-only body takes
  the fast path — one unrolling. This is the pre-slice-B `d *= 2`
  bug ("never reaching 4, 8") recreated one level down, in members.
- **Later setters, with no loop at all.** `p.x = 9 if cond; p.x = 5`
  reads `1 | 9`; the runtime is ALWAYS 5.
  `apply_setter_writeback` no-ops on a union binding, so the union read
  consults a carrier the writeback never updated. The "if / case merges
  fold for free" claim ships this.
- **`break` paths.** Member state on the break edge is dropped: the
  fast path returns before `join_break_scopes`, and the converged path
  joins breaks only for rebound LOCALS.
- **In-body reads.** A read before the setter sees only the pre-loop
  binding, so it folds iteration 1's value from iteration 2 onward.

So the union-read is sound only under four side conditions nothing
checks: the setter's RHS must not depend on loop-carried member state,
the member must be read only after the loop, the loop must exit through
its predicate, and no later setter may overwrite what the join
recorded. A real version needs member-setter effects INSIDE the
fixpoint (fold-safe struct locals as converged names, with member-map
widening at the cap), a writeback that maps over union arms, break-sink
scopes contributing struct carriers, and in-body reads consulting the
converged entry state. That is a slice on the scale of slice B itself,
not an adjustment.

It was not built, because the motivation does not survive contact with
the target. #597 exists for mail's ragel cluster, and WD2.7 already
measured that `address` is disqualified three times over by rules
upstream of this gate — decisively by being REBOUND 27 times where
`fold_safe_locals` requires exactly one write. A per-iteration setter
summary cannot help a local the state machine re-materialises every
iteration. The gate is a red herring for that file, and the single-write
requirement is the real bar.

What survived the withdrawal is the corrected reasoning: `for` is a
boundary for the unrolling reason above, not the block-scope reason its
comment used to give, and the block and loop cases decline for
genuinely different reasons rather than one shared "single static pass"
hand-wave.

### WD2.9 — A seed's own gradual arm survives the rederivation (2026-09-02, issue #586)

WD2.5's B2 note left one spelling of the declared-arm bug in place and
said so ("the bare `Array[untyped]` adjacency … pre-existing on
master"). A parameter declared `Array[Integer | untyped]` survived
because its `untyped` sat INSIDE a `Union` member and the non-recursive
drop left it alone. A parameter declared `Array[untyped]` did not: its
seed element IS the `Dynamic`, `join_array_content` dropped every
top-level `Dynamic` the moment the body's stores contributed a concrete
class, and

    #: (Array[untyped]) -> String
    def m(a)
      [1, 2].each { a.push(rand(9)) }
      a.first.upcase          # correct: the declaration licenses it
    end

closed `a` to `Array[Integer]` and drew `undefined method 'upcase'`.
The `while` form fired identically through `loop_content_writeback`,
and a declared `Hash[untyped, untyped]` closed on both sides the same
way. The category error is the one B2 already named for the
straight-line seam: a declared gradual arm is a statement about what
the collection ALREADY holds, the body's stores are evidence about what
the body PUT IN, and a body-complete view is not a world-complete one.

**Decision: the join drops no seed arm, ever.** `drop_dynamic` is gone;
`join_array_content` / `join_hash_content` union the seed's arms with
the added evidence and nothing else. The drop existed for exactly one
producer — `widen_after_block` spells an empty `[]` as `Array[untyped]`
before the block seam read its seed, and that manufactured `untyped`
had to be scrubbed back out to keep `out = []; xs.each { out << x*2 }`
at `Array[Integer]`. Once inside a carrier it is indistinguishable from
a declared one (the same observation B2 made about `post_loop`), so the
fix is the one B2 already applied to the loop seam: keep the floor out
at its SOURCE. `content_writeback_block_captures` now reads its seed
from the scope as it stood BEFORE `widen_after_block` ran — the
pre-widen `post_scope`, not the pre-CALL `scope`, so the slice-A rebind
write-back and every other post-call effect applied ahead of the
widening are still in it. An empty literal then contributes no element
and the body's evidence closes it, exactly as before; a declared
`Array[untyped]`, a local seeded from a call whose signature returns
the same, or a literal `[x]` slot the engine cannot type contributes
its arm and keeps it.

Two consequences follow from reading the seed earlier, one a repair and
one a deliberate trade:

- **The seams now meet a `Difference` where they met its base.** After
  `xs.any?` narrowing, `xs` is `non-empty-array[String]`; the widening
  used to convert it to `Array[String]` before the block seam looked.
  Read pre-widen, the refinement carrier reaches the join itself, so
  `collection_element_types` / `hash_shape_key_values` and the
  `arrayish?` / `hashish?` gates read a `Difference` through to its
  base. Declining it instead would hand the continuation the widened
  base ALONE with every appended arm missing — and that is what the
  LOOP seam had been doing since B2 moved it to `pre_body`: `if
  xs.any?; while …; xs << 1; end` read `Array[String] |
  non-empty-array[String]`, the `1` gone. Both seams now read
  `Array[1 | 2 | String]` / `Array[1 | String]`.
- **A `Dynamic` that may well be "no evidence" but wears a carrier is
  kept too.** An accumulator seeded from a call whose hand-written
  signature returns `Array[untyped]` now reads `Array[1 | 2 |
  Dynamic[top]]` where it read the closed `Array[1 | 2]`, and a `[x]`
  slot the engine cannot type keeps its arm, which the straight-line
  path's `gradual_seed` fixture already reads the same way. (`Array.new`
  is NOT in this set: it types as a bare `Array` with no type args, which the
  join reads as no elements, and still closes; a `Hash.new(default)` seed types
  `Hash[Dynamic, V]` and now keeps its key arm (monotone, no diagnostic moves);
  `Array(x)` is wholly `Dynamic` and never reaches the join.)
  Each is a monotone imprecision on a rare spelling — `[]` dominates
  the accumulator idiom — and the alternative, guessing which `Dynamic`
  is "really" empty, is the provenance question #580 owns. FP cost
  outranks worst-case static reading; the trade is taken.

Gate: the `mutation_join_declared_sig` fixture carries the bare
declared arm in block, loop, and Hash form (must-not-fire), the
fresh-seed siblings that still close and still fire (the exact
`call.undefined-method` line set — a seam that had gone gradual
everywhere would go quiet there too), and the `Difference` seed in
block and loop form; `block_path_stays_precise` and the
`loop_body_fixpoint` `Array[Integer]` snapshot are unchanged; the
`block_captured_writeback` fixture pins the `[x]` slot. Restoring the
drop (or reading the seed from `post_scope` again) turns the
must-not-fire examples red and nothing else.

What this does NOT touch: the straight-line seam's `Difference`
branch, where `widen_for_mutator` widens `non-empty-array[T]` to its
base without joining the mutator's argument (`if xs.any?; xs << 1` reads
`Array[String]`). That is #560's family reached through a fourth door,
and a separate change.

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
