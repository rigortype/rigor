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
*(Amended by WD2.13's second-residue closure: a captured local the body
mutates in place is read at its unknown-store widening in every pass,
never at its pre-call contents. Issue #1412 extends that to the
statement pass over every repeating block, and to the loop seam.)*

### WD2 — Slice B: loop-body fixpoint

`eval_loop` (and the equivalent `until` path) replaces its single-pass
join with the same capped fixpoint over body-written locals: iterate
body evaluation from the joined scope until the join stabilizes (cap 3,
final-iteration value-pinned widening, per-local `Dynamic[top]` on
non-convergence). `d = 1; while …; d *= 2; end` → `1 | Integer`
(today's unsound `1 | 2`). Loop-carried narrowing on the predicate is
recomputed per iteration from the joined scope, so existing break /
exit-edge behaviour is preserved.
*(Amended by WD2.13's issue #1412 note: every pass, the single pass
included, enters with each local the body mutates in place at its
unknown-store widening.)*

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
   cannot mistake a declared `untyped` for the floor.)* *(Amended by
   WD2.13: a store whose evidence reads a collection the join moves is
   iterated to a fixpoint instead of typed once.)*

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
  WAS not in this set: it typed as a bare `Array` with no type args, which
  the join read as no elements, and still closed — and that turned out to be
  the bug WD2.10 fixes rather than a case this rule excludes; a
  `Hash.new(default)` seed types
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

What this did NOT touch: the straight-line seam's `Difference`
branch, where `widen_for_mutator` widened `non-empty-array[T]` to its
base without joining the mutator's argument (`if xs.any?; xs << 1` read
`Array[String]`). That was #560's family reached through a fourth door,
and it landed as that separate change (issue #936): the arm now joins the
added content over the refinement's base and retracts the empty witness
only for the mutators that can empty the receiver, so an append reads
`non-empty-array[String | Integer]` and `xs.clear` still reads `Array[String]`.

### WD2.10 — The per-element fold sees a rebound capture at its converged binding (2026-09-02, issue #587)

Slice A's fixpoint answers the CONTINUATION: what a captured local is
once the block has run zero or more times. It runs in
`StatementEvaluator#eval_call` after the call itself is typed, so the
block-RETURN pass — `ExpressionTyper`, dispatched from inside that call
typing — never sees its result. For a single-yield method that is
harmless: `m.synchronize do total += 1; total end` is `1` in its only
iteration. For the per-element Tuple fold it is a wrong-precise answer
at every position: the fold re-types the body once per element from
the same entry scope, so `total = 0; [1, 2].map do total += 1; total
end` folded to `[1, 1]` (runtime `[1, 2]`), and `r.first == 1` then
folded to `Constant[true]` — a live always-truthy on correct code (PR
#584's review, probe 2).

Two fix directions were open. Feeding the continuation bindings back
into a second call typing from `eval_call` would fix the generic
`Array[U]` path too, but it re-types the receiver and arguments under
the widened binding, doubles the call typing for every block that
rebinds a capture (`sum = 0; xs.each { |x| sum += x }` is the
archetype), and misses a fold that is not a statement of its own
(`… .map do … end.first == 1` inside a predicate). Declining the fold
outright loses folds the pin never touched: `[1, 2].select do seen +=
1; e > 1 end` decides on the element alone and stays `[2]`, and a tail
reading an unrebound capture keeps its literal.

The decision is the narrow one: the fold itself runs the WD3 fixpoint
over the same captured-rebind name set (now `Inference::CapturedLocals`,
shared with slice A and the sub-phase 3c drop so the four cannot
drift) before typing any position, and binds each rebound local to the
converged type in every position's entry scope. The answer is what the
local can be in ANY iteration — `[Integer, Integer]` — and a
structurally compounding rebind (`x = [x]`) takes the floor the
fixpoint already defines. Cost is bounded to the shape that had the
defect: a Tuple receiver under the fold family whose body rebinds a
capture, at most CAP + 1 extra body evaluations with the parameter
bound to the element union, independent of arity. Under the block-body
threading suppression of #584 (the fold nested in a threaded body) the
fixpoint is not run and the names take the escaping-block floor.

Two residues are recorded rather than fixed here. The generic
`Array[U]` path (`xs.map do total += 1; total end` on a nominal
receiver) still pins `U` to the first iteration — `Array[1]`, with the
same always-falsey hazard on `r.last == 2` — because the block-return
pass cannot tell a single-yield method from an iterator and the
single-yield answer is exact; the fix needs a yield-count signal or the
`eval_call` reordering above, and belongs to its own issue. And `[1,
2].map { total += 1 }` still folds to `[1, 1]` even with `total:
Integer` at entry, because `ExpressionTyper#type_of_assignment_write`
types every compound write as its RHS — `total += 1` as `1` — a defect
of the expression typer, not of the fold, and one whose fix reaches
every `||=` / `&&=` / `op=` expression.

### WD2.11 — The rederived carrier replaces only the members it stands for (2026-09-02, issue #631)

WD2.9 settled the ELEMENT arm. The whole-VARIABLE arm was still being
dropped, and dropping it fired:

    def f(flag, u)
      out = flag ? u : [2]     # Dynamic[top] | [2]
      [1].each { out << 2 }    # -> Array[2]; the Dynamic arm is gone
      out.first.upcase         # undefined method `upcase' for 2
    end

`g`, the same seed read through `out.first == 3`, drew the
always-falsey twin. Both are correct programs whenever `u` is an array
of strings, and both were byte-identical on master back to slice C.

The mechanism is one line of the seam's contract nobody had written
down: `join_array_content` builds ONE fresh `Nominal[Array]` and the
caller writes it over the whole binding. That is the right answer only
for the pre-state members the mutation applied to AS an Array of that
class. `collection_element_types` answers `[]` for every other member —
a whole-variable `Dynamic`, a foreign `Nominal`, a `Constant` — so they
contributed nothing and were then overwritten out of existence. The
straight-line seam never had the bug because `widen_for_mutator`
declines a `Union` outright and reads it through untouched; the block
and loop seams were the outliers, not the reference.

**Decision: the join partitions the pre-state.** Members it can read as
a carrier of the target class are absorbed into the rederived one;
every other member survives whole, unexamined, beside it. `Dynamic[top]
| Array[2]` here. Neither half is examined twice, so nothing is
double-widened, and the partition is spelled by mirroring
`collection_element_types` / `hash_shape_key_values` recursion for
recursion (`ContentJoin#array_residue` / `#hash_residue`) so the
absorbed set and the residue cannot drift apart.

Four things the partition had to settle:

- **A carrier is a carrier whether or not it carries evidence.** A bare
  `Nominal[Array]` with no type args — `Array.new`, WD2.9's own
  exception — yields no element and is still absorbed. Treating "no
  evidence" as "not a carrier" would have grown #615's seed a second
  arm (`Array | Array[2]`) instead of letting it close.
- **Two Array carriers still join to ONE Array.** Both are absorbed;
  `flag ? [1] : [2]` under `out << 3` stays `Array[1 | 2 | 3]`. This is
  the must-still-succeed half, and the one a residue rule that kept
  carriers would break loudly rather than imprecisely.
- **The loop seam gets the rule for free**, because it shares the join.
  The `while` twin of `f` fired identically and goes quiet with it.
- **`nil` does NOT survive.** It is the one member the mutation itself
  refutes: `NilClass` defines no content mutator, so on every path where
  the body ran the binding was not nil. Only the zero-iteration path
  keeps the arm, and that path is modelled UPSTREAM — the `while` base
  scope's nil-injection, slice A's `Constant[nil]` fixpoint seed — not
  here. Keeping it measured out as pure cost: `r = nil; while …; r ||=
  []; r << x; end; r.each` gained a `call.possible-nil-receiver` on an
  idiom Rubyists write deliberately, while the genuinely live nil arm is
  already reported once, at the mutation, where `r << x` draws the same
  diagnostic. The general form of that reasoning — drop any member the
  mutator is undefined on — needs a method lookup this seam has no
  environment for and would buy only rarer shapes; `nil` is the case it
  can decide for free. If the zero-iteration nil ever wants revisiting,
  the place is the injection, not the join.

The residue is a strictly gradual direction for `Dynamic`, which
absorbs folds and method checks: those sites can only lose diagnostics.
A foreign `Nominal` or `Constant` member is the one place a NEW firing
can appear (`flag ? 5 : [2]` under `out << 2`, then `out.first`), and it
is the honest one — the arm is real, the straight-line twin already
reads it that way, and inventing an Array in its place was the bug.

Gate: the `union_seed_residue` fixture carries both issue shapes plus
the loop and Hash twins and the foreign-`Nominal` member
(must-not-fire), the plain-seed / two-carriers / bare-carrier siblings
that must still close (exact `assert_type`s — a rule that kept carriers
would read `Array[1 | 3] | Array[2 | 3]` there), and the refuted nil arm
with its `call.possible-nil-receiver` line set. Restoring the drop turns
the must-not-fire half red and nothing else.

### WD2.12 — A constructor that fills slots is never an elementless seed (2026-09-02, issue #615)

WD2.9's own parenthetical named `Array.new` as a carrier the rule does
not reach, and reading it as an exclusion was the mistake. A bare
`Array` is not "a seed with a gradual arm the join must keep"; it is a
carrier with **no element arm at all**, which is the exact shape the
seams read as an ELEMENTLESS seed — a fresh accumulator whose every
store they saw — so they close it over the block's own stores. The
constructor that produced it, though, fills `n` slots the block never
touched:

    acc = Array.new(n, "x")
    [1].each { acc.push(1) }
    acc.first.upcase          # correct Ruby

read `Array[1]` and drew `undefined method 'upcase' for 1`, and the
no-fill form folded `acc.first == 1` always-truthy over an array of
nils. Both are wrong-precise, not imprecise, and both are the #586 rule
meeting the constructor fold's dynamic-size answer (#531).

The seam is not what changes. The **constructor** is: `Array.new` with a
non-literal size now seeds a real element parameter — the fill value's
or block result's type for `Array.new(n, v)` / `Array.new(n) { … }`, a
gradual element for the no-fill form — so it reaches the seams as a
declared-like `Nominal[Array, [E]]` and WD2.9 keeps that arm through the
join unchanged. A small literal size keeps its per-position `Tuple`
fold; the zero-argument `Array.new` really does build an empty array, so
it keeps the elementless carrier and closes exactly as the `[]` literal
does.

Three element choices are load-bearing, and all three are FP judgments
rather than precision ones:

- **The element is value-pin widened**, `hash_new_lift`'s reason: the
  slots are rewritten over the array's lifetime, so `Array["x"]` would
  let a later `acc[i] == "x"` constant-fold. A literal *container*
  result widens as well — `Array.new(n) { [] }` builds `n` INDEPENDENT
  arrays that the program then appends to, and `Array[Tuple[]]` claims
  every one of them stays empty, which reads `adj[i].first` as `nil` on
  the adjacency-list idiom. It widens **recursively**, through a
  container's own elements and a hash shape's own values: every nested
  position is a fresh object per constructed slot too, so stopping at
  the outermost level merely moved the wrong-precise answer one level in
  (`Array.new(n) { [[1]] }` stayed `Array[Array[[1]]]` and folded
  `a[0][0].last == 5` always-falsey after `a[0][0] << 5`). The walk is
  bounded by the source literal's own nesting — a `Type` carrier is
  assembled bottom-up and cannot contain itself — with a defensive
  depth cap behind that.
- **A `Union` fill widens MEMBERWISE.** Judged wholesale,
  `Array.new(n) { flag ? [1] : [2] }` stayed `Array[[1] | [2]]` and every
  arm was still a fixed-arity tuple, so `a[0] << 5` then
  `a[0].last == 5` folded always-falsey on correct code. Each container
  member takes the same recursive widening; non-container members pass
  through, so `Array.new(n, flag ? [] : "s")` reads
  `Array[Array[untyped] | String]`.
- **The no-fill form seeds the GRADUAL element, NOT `nil`** — even when
  the size argument is provably an `Integer`, and even for the
  oversize-literal fallback. `Array.new(n)` really does put a `nil` in
  every slot, so `nil` is the honest reading of the value; it is not the
  honest reading of the *carrier*. A `Nominal` seed gets DECLARED-carrier
  semantics downstream: WD2.9's join keeps a seed arm forever, and
  `MutationWidening#widen_for_mutator` declines a `Nominal` outright, so
  no whole-array rewrite — `[]=`, `fill`, `map!`, `replace`, `concat` —
  can ever retract the placeholder. `nil` therefore stops being "what is
  in the array before you fill it" and becomes a permanent nil
  possibility over the allocate-then-fill idiom that is the whole point
  of the constructor:

        dp = Array.new(xs.size); dp[0] = 1
        (1...n).each { |i| dp[i] = dp[i - 1] + xs[i] }   # `undefined method '+' for nil`

        buf = Array.new(256); 256.times { |i| buf[i] = i.to_s }
        buf.each { |c| c.upcase }                        # possible nil receiver

  Both are correct Ruby, both went from quiet to an ERROR on the `nil`
  seed, and the prefix-sum and sieve shapes go the same way. The true
  positive `nil` would buy — `Array.new(n).first.upcase` on an array
  nothing ever wrote — does not pay for the dominant idiom. Gradual is
  still an ARM, which is all the seams need, and it absorbs Ruby's
  array-convertible COPY overload for free (`Array.new([1, 2])` is
  `[1, 2]`, not two nils). Seeding `nil` becomes admissible only once a
  rewrite can retract a `Nominal` carrier's element — a `widen_for_mutator`
  change, not a constructor one.

The same reasoning covers the EXPLICIT placeholder: `Array.new(n, nil)`
is the allocate-then-fill idiom with the `nil` spelled out (concurrent-
ruby writes `@Resolutions = ::Array.new(count, nil)` and fills it by
index), so a nil-ONLY element seeds the gradual arm too — it would
otherwise be permanent for exactly the same reason, and every read of a
filled slot would draw `undefined method '…' for nil` on correct code.
A fill that is only partly nil (`flag ? nil : "s"`) keeps both arms:
the guard reads a nil-only element, not a nil-bearing one.

One consequence of the declared-carrier semantics is recorded rather
than fixed: the FILL form's class survives a later differently-typed
store, so `acc = Array.new(n, true); acc[0] = false` stays
`Array[TrueClass]`. It is silent — the read does not fold `acc[0]` to a
constant, so no always-truthy verdict follows — and repairing it is the
same `widen_for_mutator` change the bullet above names.

Gate: the `array_new_dynamic_seed` fixture pins what every constructor
form seeds and carries it through both seams (must-not-fire), carries
the DP recurrence and the `256.times { buf[i] = … }` buffer as the
allocate-then-fill idiom, and holds the union-fill and nested-container
shapes — against the
fresh-seed siblings (the `[]` literal and the zero-argument `Array.new`)
that must still close and still fire the exact `call.undefined-method`
line set. Restoring the bare-`Array` answer turns the seam examples red;
restoring the `nil` seed turns the idiom examples red; judging a union
fill wholesale, or stopping the container walk at the outermost level,
turns the container examples red. The literal-size tuple fold is
untouched by all four.

### WD2.13 — A store that reads its own collection is iterated, not typed once (2026-09-23)

WD2.5 specified the block join "under the same `BodyFixpoint`
cap/widen/floor discipline" as slices A and B, but the seam shipped as
a single pass: it typed every store's evidence once, in the
block-entry scope. There each content-mutated collection still holds
its pre-call contents, so a store computed FROM that collection
recorded the first iteration's value and the join closed over it:

    h = { a: 0 }
    [:a, :a, :a].each { |k| h[k] = h[k] + 1 }
    puts "three" if h[:a] == 3   # always-falsey: h read Hash[:a | Symbol, 0 | 1]

`a << a.last + x`, `a.push(a.size)`, `a[0] += 1`, `h.store(k,
h.fetch(k) + 1)` and an `each_with_object` memo read back through its
alias (`m[k] = m[k] + 1`) are the same defect. Each is wrong-precise,
and the block path is where it costs most, because that join adds no
gradual arm on purpose: WD2.5's "how much the joining path saw" rests
on the body scan's evidence being complete, and it was complete in the
set of stores while stale in their values.

Two repairs were open. Giving every store whose evidence reads the
mutated collection the one-store gradual floor is sound and cheap, but
its `Dynamic` arm quiets every later read of the collection —
`h[:a].upcase` goes silent — for a store whose value the engine can in
fact bound. **Decision: iterate the evidence.** The block seam and
`each_with_object` share one join
(`StatementEvaluator#join_content_to_fixpoint`), which binds each name
it joins to what that collection holds at ANY iteration's entry. The
joined names are the block's captured content-mutated locals, and for
`each_with_object` the memo as well; that seam keeps only the memo's
carrier, so a memo store reading a captured collection the same block
appends to (`buf << w; m << buf.length`) reads `String` and not the
pre-call value. A name none of whose stores reads a mutated Array or
Hash is FIXED: its evidence is the same on every iteration, so it is
typed once and the name is bound to its own join plus the seed members
that join refutes (its `nil`). A String is always fixed at `String`,
since its join ignores what it stored. The remaining names MOVE, and
`BodyFixpoint` iterates their evidence slots (an Array's element
union, a Hash's key union and value union), each seeded `bot`. Each
pass re-types the moving stores with every moving collection bound,
like a fixed one, to its join over the evidence so far plus the seed
members that join refutes, since a `nil` seed can still be `nil` on an
iteration where another moving collection has already grown. The final
pass value-pin widens the moving evidence, and a slot that still grows
takes the one-unknown-store floor beside the seed's own arms. `h`
reads `Hash[Symbol, 0 | Integer]`, and `nested << [nested.last]`
floors to `Array[Dynamic[top] | []]`. The seed is never widened,
because it is the zero-iteration contents. Neither is a fixed name's
evidence, so `acc << 1` beside a self-reading store keeps `Array[1]`
and the genuine fold it supports. This keeps to WD3 rather than adding
a second mechanism: the moving evidence slots are simply the
fixpoint's names.

The fixed/moving split and the memo seam's captured names are the
review's corrections of a first cut that iterated every name and gave
the memo seam the memo alone. A String has no evidence slot, so it
never counted as having moved and stayed at its seed on every pass:
`buf << w; lens << buf.length` read `Array[0]` and folded `lens.last
== 4` always-falsey. `BodyFixpoint` also widens every name on its
final pass, so a store that read nothing lost its constants whenever
it shared a block with one that needed the widening. Binding names in
the evidence scope then exposed two routes that a continuation-only
join never had to get right. First, the captured-mutation walk counts
any receiver read at depth >= 1, so a block parameter mutated inside a
nested block passed for the outer local it shadows, and binding it
overwrote the parameter. Second, the join drops a seed's `nil`, so a
fixed name bound to its join alone read `out << a.nil?; a ||= []; a <<
v` as `Array[false]`. Both were new false positives against master,
and both are why a fixed name keeps its seed and why the walk that
finds captured names now compares a read's `depth` with the blocks and
lambdas it is nested in, instead of testing `depth >= 1`, which is
right only directly in the body. The same comparison exposed one more
route, present on master too: a store nested in an inner block that
binds its own parameter had its evidence typed in the seam's entry
scope, where that name is the outer local it shadows, so `|inner|
picks << inner.first` read an outer `inner = [0]`. Such a store's
evidence is now typed with its inner blocks' names bound to
`Dynamic[top]`. A moving name then kept its seed only on the first
pass, which missed a `nil` that outlives another collection's growth;
it now keeps it on every pass. Only the refuted members come back, not
the whole seed: re-adding a seed's literal shape widened dispatch
enough that `a = []; [1].each { a[0, 1] ||= [2] }` stopped converging
and lost its `Array[2]`.

A block with no moving name takes a single pass, so `acc = [];
xs.each { |x| acc.push(x) }` still reads `Array[Integer]` (WD2.9) and
the common block pays one walk over its mutators' arguments. The loop
seam needed nothing: it types its evidence against `post_loop`, where
the in-body straight-line join has already given the binding its
gradual arm.

Three residues are recorded rather than fixed here. All are the same
first-iteration pin reached through a binding this join does not own.
The evidence read a captured local the body REBINDS at its pre-call
binding (`total = 0; out = []; [1, 2].each { |x| total += x; out <<
total }` read `Array[0]`; closed below), and slice A's rebind fixpoint reads
a content-mutated capture at its pre-call contents (`last = nil; [1,
2].each { |x| last = a.last; a << x }` leaves `last` at `0?` over `a =
[0]`). And a collection the block changes only through a remover
(`a.shift; b << a.first`) or only through an alias is not a joined
name at all, so a store reading it sees its pre-call contents; both
routes predate this fixpoint. The final-pass widening is also trusted
without a further pass, which is `BodyFixpoint`'s own shape and so
slice A's too. A store whose value only changes class after the
widened bound (`h[k] = h[k] == 10 ? :done : h[k] + 1` over eleven
iterations) still reads `0 | Integer` without its `:done`. Re-checking
the widened assumption belongs to `BodyFixpoint`, for every slice at
once, and is #1220. Separately, the join still drops a seed's `nil`
after a guarded mutation (`maybe << v if maybe` leaves `Array[…]`
though `maybe` can stay nil), WD2.11's rule meeting a case its
reasoning did not cover; that is #1219, and the fixture's golden
carries the flip comment.

*(The first residue is closed, 2026-09-23.)* The closure is
conservative. A store that reads a local the body writes now types that
local as `Dynamic[top]`
(`StatementEvaluator#shadow_rebound_reads`), so `out` reads
`Array[Dynamic[top]]` and `out.last == 3` no longer folds. The locals
covered are an outer local the body rebinds, and a block parameter or
`;`-local it reassigns. A write in a parameter's default counts. A write
inside an inner block to a name that block introduces does not count,
because it is a different variable, and neither does a write in a
method body the block defines. A joined collection the body also
rebinds counts too, because the join's seed carries slice A's
continuation. A local the body introduces already read `Dynamic[top]`.

The binding joins the per-store `shadows` overlay, where an inner
block's own names were already bound to `Dynamic[top]`. An Array index
write is the exception: its index arguments, and every name they read,
keep the block-entry binding. The join classifies such a store as an
element or a splice from the index's type. A `Dynamic` index reads as
both, so `grid[i] = [x, x]` would join `x` itself beside the pair and
draw `def.return-type-mismatch` against a declared
`Array[Array[Integer]]`. A Hash key is not an index, so it is covered.
A store that reads only locals the body does not write keeps its
precise binding, so a block that rebinds `tally` still stores `limit`
as `5`. No extra evaluation pass runs, and the evidence no longer reads
slice A's continuation.

Three precise readings were built first. Adversarial review rejected
each one for reporting on correct code (ADR-5):

1. **Slice A's continuation**, the pre-call value joined with every
   iteration's exit value. It misses a value written between two
   rebinds. A call on the union then drops the member it is undefined
   on: `state = s; out << state.length; state = :done` typed the store
   `4`, and `lengths.last == 2` folded.
2. **That continuation joined with the block-entry typing.** This
   stopped the fold, but it still stored exit values no store reads. A
   reset to `nil` after the store became `call.possible-nil-receiver`
   on an element, and a reset to `5` became `def.return-type-mismatch`
   against a declared `Array[String]`.
3. **One more walk of the body with an `on_enter` recorder at each
   store.** The walk entered with rebound locals at the continuation and
   with every outer collection floored. It was precise, with guards
   narrowing, but it inherited every gap in the single-pass, in-body
   flow, and so did every gate put around it. The gaps included:
   - an `if` branch that exits beside an `else` still joins its writes
     (#1230);
   - a `rescue` arm reads the `begin`'s entry scope (#1231);
   - an `inject` accumulator is treated as fresh on every iteration
     (#1232);
   - slice A dropped the scope at `next` (#1214, since joined by #1215);
   - a local written inside an argument reaches no later scope (#1223,
     since threaded by #1250);
   - ivars can be written through setters.

   Each gap surfaced as a new false positive the moment a store read
   through it.

The cost is precision: such a collection gains a `Dynamic[top]`
member, which quiets later reads of it. #1233 records how to return to
reading (3) once those gaps close. These shapes stay open:

- A store that reads an instance variable the body writes
  (`out << @total`) is not covered (#1235).
- The index of an Array index write keeps its first-iteration reading,
  as on master. So does a stored value that reads the same name:
  `ids[n] = n; n += 1` still stores `0`, and `ids.last == 1` still
  folds. An index the body rebinds to a Range is still classified as an
  element store.
- A local written through a proc defined outside the block is not seen
  as written, as everywhere in the engine.
- The rebound local itself keeps whatever slice A gives it.

Gate: the `block_content_self_read` fixture carries the six
self-reading shapes, the String read and the two `each_with_object`
captured reads, a parameter shadowing a mutated outer local, a nested
block's own parameter read one level deeper, a lazily initialised
capture, and a `nil` seed read by another moving store (must-not-fire,
each pinned by `assert_type`), the structural floor, and the #586
accumulator. It also has two controls whose always-falsey must still
fire: the same counter storing a receiver-independent value, and `acc
<< 1` sharing a block with a self-reading store. The spec asserts the
exact `flow.*` line set, so a seam that went gradual everywhere fails
as loudly as the old pin did.
The `block_content_rebound_capture` fixture gates the first residue's
closure. Its must-not-fire cases each store a local the body writes:

- the Array, Hash and `each_with_object` stores of a running total;
- a write that is the store's own argument;
- a read between two rebinds;
- an exit value no store reads;
- a declared return type;
- a reassigned parameter;
- an `inject` accumulator;
- a `next`;
- a store inside an inner block;
- a collection the body both rebinds and grows;
- an index the body increments, under a declared return in the
  fixture's `sig/`;
- a Hash key the body rebinds;
- a local a parameter's default rebinds.

A precision case keeps an index store's value exact. Its four controls
read a local the body does not write, a parameter it does not reassign,
a name only an inner block's own parameter writes, and a name only a
method body the block defines writes. Their
always-falsey must still fire, so the seam has not gone gradual on
every store. The spec asserts every rule, not
only `flow.*`, because the rejected readings failed as nil receivers
and return-type mismatches as well as folds.

*(The second residue is closed, 2026-09-23.)* Slice A's passes now
read every captured local the body mutates in place at its call-site
binding widened for a store of UNKNOWN values at each mutation site
— `Inference::UnknownStoreWidening`, the binding the per-element fold
already lays under every position. A name the body both rebinds and
mutates takes the same widening over the pass's running assumption,
as the fold widens it (#587 (b)): the assumption carries the exits of
the body's straight-line seam, which can close the collection without
a gradual arm. `last = a.last; a << x` over `a = [0]` reads `0 |
Dynamic[top] | nil`, and `last == 1` no longer folds.

Two repairs were open, and the corpus decided between them. Iterating
slice A jointly with this join, so each reads the other's running
binding, would type the rebind precisely (`0 | 1 | 2 | nil`) and reach
the first residue as well. The price is re-typing the evidence on
every pass and merging two seams that `eval_call` runs apart.
**Decision: the unknown-store binding.** It evaluates no body and only
widens, and a block that mutates nothing captured is untouched: `sum =
0; xs.each { |x| sum += x }` keeps its three passes. Its cost is the
gradual arm on a rebind read from an Array or a Hash; a String capture
widens to `String` and needs none. No corpus code uses the precision
the joint iteration would buy. Across 32 survey targets (8,725
diagnostics), an instrumented first cut engaged at 40 block sites
without changing any rebound binding, and the final change moves no
diagnostic. It costs +3,775 allocated objects out of 33.7M on the
`lib` self-check.

Adversarial review found four routes the first cut still pinned, all
closed here. A lone remover or a remover written before an adder (`p =
s.pop; s.push(x)`) closed a literal to a nominal with no gradual arm.
The adder then declined that nominal, and `{ a: 0 }` under
`h.delete(:a)` read `h[:b]` as `0` where Ruby answers `nil`.
`UnknownStoreWidening` now gives the gradual arm to the site that
closes a `Tuple` or `HashShape`, whatever kind of site it is, so for a
`Tuple` or `HashShape` seed the answer no longer depends on the order
the sites are written in. A rebound-and-mutated name was the second
route, covered above. The third was a nested block's own parameter
sharing the outer name (`[[9]].each { |a| a << x }`), which
`CapturedLocals.content_mutations` counted as a mutation of the outer
local. It now counts a read only when it resolves past every nested
block. The fourth was a seed closed before the call: `s = [0, 9];
s.pop` leaves the value-pinned `Array[0 | 9]`, which the widening
declines like a declared nominal, so every pass read its pins. A
widening whose result is still a value-pinned collection now takes the
gradual arm instead, a refinement's base included (under `if s.any?`
the `pop` drops `non-empty-array[0 | 9]` to the same pinned nominal).

What stays open is the same pin through a binding slice A does not
own. An instance variable read before an in-place mutation
(`last = @a.last; @a << x`) is not collected (#1208). A block-local
alias (`b = a; b << x`) hides the mutation from the scan. A block that
rebinds nothing and returns the read (`xs.map { v = a.last; a << x;
v }` on a nominal receiver) goes through the block-return pass, which
is WD2.10's generic `Array[U]` residue.

Gate: the `block_rebind_reads_mutated_capture` fixture carries ten
must-not-fire shapes: tail, Hash slot, emptiness, String size,
remover-before-adder, slot rewriter, lone remover,
rebound-and-mutated, and a seed closed before the call, bare and under
a guard. The first five are pinned by `assert_type`. Two controls must
still fire: a collection the body does not mutate, and an inner block
parameter sharing the outer name. The spec asserts the exact `flow.*`
line set, that no error fires on a value the body stored, and the
accumulator's pass count.

*(The statement pass and the loop seam, issue #1412, 2026-09-26.)* The
closure above reached only the write-back's passes, and the write-back
runs only for an explicit receiver classified `:non_escaping` whose
body also REBINDS a capture. Every other repeating body kept the
single statement pass from the call's entry scope, and a body that only
mutates a capture read its pre-call contents on every pass:

    depth = []
    lines.each { |tl| puts depth.last.length if depth.last; depth << tl }
    # error: undefined method `length' for nil

That pass now enters from a write-back pass's entry
(`StatementEvaluator#repeating_block_entry` → `#block_pass_entry`)
whenever the call may run its block more than once. The gate is the
#587 (b) pass's own (`Inference::BlockRepetition.may_repeat?`, moved
out of `ExpressionTyper` so both passes share it), so #1234's iterator
name on a `Dynamic` receiver counts, and `then`, a one-element receiver
and an uncatalogued name do not. Where the write-back will not run its
passes (an `:unknown` class, or no explicit receiver), a name the body
rebinds enters at its call-site binding joined with `Dynamic[top]`,
the rebind counterpart of the unknown-store widening: an earlier pass
wrote something no pass typed, and the continuation already drops the
name to `Dynamic[top]`. The loop seam takes the same widening
(`#loop_pass_entry`, so the single pass and every fixpoint pass, and a
`for` body's only pass) over `CapturedLocals.loop_content_mutations`.
A widened name the body does not rebind keeps its #1287 marks
(`Scope#with_mutated_local`), on the write-back's passes too.

The rule is the one this section already chose: a body's entry must
describe every pass it records, and where no pass types what a later
pass reads, the gradual arm is the answer. Two alternatives were
rejected. Running the write-back for a body that only mutates (dropping
its `names.empty?` fast path) costs a second body pass for every such
block, where the widening needs none. Running its fixpoint for an
`:unknown` call costs passes on the most common untyped receiver, and
it keeps the `nil` seed beside what the body stores, so the line
readers below would still read a possible `nil`. The price is the
false negative the write-back already pays: a read only the first pass
makes goes gradual (`last = nil; items.each { |x| last.length; last =
x }` on an untyped `items` no longer reports).

A body that can neither rebind nor mutate a captured binding skips the
gate (`CapturedLocals.may_touch_capture?`, an allocation-free scan),
and the block's receiver is typed once per call
(`StatementEvaluator#explicit_receiver_type`) instead of at each of
the four sites that asked. On textbringer (`--workers=0`) that is
6,371,968 → 6,058,445 allocated objects; the gate alone, before the
memo, cost +35k (+0.55%).

Gate: the `repeating_body_content_mutation` fixture's must-not-fire
shapes (the repro, `each_with_index`, `push`, an index write, a Hash
slot, a typed receiver, `while`, `until`, `for`, an untyped-receiver
rebind and a line reader's state machine) and its three controls (a
body that never appends, `5.then`, `Mutex#synchronize`), which still
report. Corpus (redmine, textbringer, mail, mastodon): the three redmine
errors the issue names are gone, with the same fix removing four
more state-machine reads under `io.each_line` (`cvs_adapter.rb:196`
and `:214`, `git_adapter.rb:262` and `:308`), and nothing is added.
One error keeps its line and changes its type: `diff.rb:78` calls a
method Redmine patches onto `Array` and now reads the receiver as
`Array[Dynamic[top]]`, not `[]`.
What stays open: `Kernel#loop` is not a catalogued iterator, so a
`loop do … end` body keeps its entry; an instance variable mutated in
place is still not collected (#1208).

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
