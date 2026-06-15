# Loop `break`-path binding propagation — FP finding + fix design

2026-06-15. **Status: IMPLEMENTED 2026-06-15** as the "Recommended approach"
below — the `BREAK_SINK_KEY` thread-local sink + the `directly_targeting_breaks`
filter + the `eval_loop` / `eval_for` continuation join. A false-positive class
surfaced while corpus-validating the ADR-48 `Struct` merge (slices 1–3) against
`rigor-survey`; this note records the finding, the diagnosis, and the design the
implementation realises. Gate met: the targeted FP clears with zero new firings
across six corpora, `make verify` green, regression specs in
`statement_evaluator_spec`. Candidate for promotion to an ADR (it is ADR-56's
non-local-exit sibling).

## Corpus context (how it was found)

The ADR-48 `Struct` merge was validated with a before/after diff (pre-Struct
`8023c337` vs `master`) over eight Struct-using `rigor-survey` corpora —
kramdown, algorithms, Algorithms-and-Data-Structures-in-Ruby, faraday,
concurrent-ruby, net-ssh, haml, jbuilder. **All eight were byte-identical**
(zero new / removed firings): the Struct precision change is corpus-neutral,
no FP regression. The diff also surfaced the pre-existing FP below in the
algorithm corpora (`ChekPairWithGivenSum.rb:18`, `PassingCars.rb:21`,
`PassingCars1.rb:14`, and likely more in the wider corpus).

## The false positive

```ruby
flag = false
for i in 0...arr.length
  if arr[i]
    flag = true
    break
  end
end
if flag            # ← `flow.always-truthy-condition`: "always falsey"  (FP)
  ...
end
```

`flag` can be `true` (set on the `break` path), so `if flag` is `false | true`
— not always falsey. The "set a flag and `break`" search idiom is extremely
common, so this is a high-frequency FP.

## Diagnosis

Probed `flag`'s inferred type across the loop forms (`dump_type`):

| form | `flag` types | verdict |
| --- | --- | --- |
| `for` + `if … break` | `false` (Constant) | **FP** (always-falsey fires) |
| `for` + `if` (no break) | `bool` | correct |
| `while` + `if … break` | `FalseClass` | **FP** (same) |
| `each { … break }` | `Dynamic[top]` | no FP (block widens) |

So it is **not** `for`-specific — it is **`break`-path bindings being lost**,
in both `while` (`eval_loop`) and `for` (`eval_for`). The `each`-block form
escapes-widens the captured local to `Dynamic[top]` (ADR-56 escaping-block
treatment), which is truthy-tolerant, so no always-X fires there.

**Mechanism.** A `break` inside `if arr[i]; flag = true; break; end` makes the
`then`-branch *diverting* — `branch_unconditionally_exits?`
([`statement_evaluator.rb:2971`](../../lib/rigor/inference/statement_evaluator.rb))
recognises `BreakNode` and the `if`-join *excludes* the diverting branch from
the normal continuation. That is correct (the `break` path does not fall
through), but the excluded branch's scope (`flag = true`) **must instead reach
the loop exit** — and nothing collects it there:

- There is **no `BreakNode` dispatch and no break-scope accumulator** in the
  evaluator (grep: no `eval_break`, no `break_scopes`). `break` is only
  recognised for reachability, never for binding propagation.
- `eval_loop`'s fixpoint reads each tracked local's *fall-through* exit —
  `loop_body_exit_bindings` returns `exit_scope.local(name)`
  ([`statement_evaluator.rb:1087`](../../lib/rigor/inference/statement_evaluator.rb)),
  where `exit_scope` is the body's normal exit (`flag = false`). The
  `break`-path value is computed during the body eval and then discarded.
- `eval_for` ([`statement_evaluator.rb:1106`](../../lib/rigor/inference/statement_evaluator.rb))
  does a single body pass joined with the pre-loop scope and has no fixpoint
  at all, so it loses the `break` path the same way (and, separately, lacks
  the ADR-56 loop-body fixpoint — a second, smaller gap).

## Fix design

**Goal.** A `break`'s scope (its local bindings, and any `break <value>`) must
be joined into the loop's continuation scope, for both `while`/`until`
(`eval_loop`) and `for` (`eval_for`).

### Why the tempting shortcut is rejected (not FP-safe)

A *syntactic over-approximation* — "for each loop-body-written local, join the
union of all its assigned RHS types into the post-loop binding when the body
contains a `break`" — is simpler (no break-scope plumbing) and sound for the
always-X class (joining possibilities only *reduces* constant-folding). **But
it is not FP-safe for `possible-nil`:** it would join writes from paths that
never reach an exit (`x = nil; …; x = 5; break` — the `x = nil` is always
overwritten before the `break`), over-widening `x` to include a `nil` it can
never actually carry out of the loop, and so manufacturing a false
`possible-nil-receiver` on a later `x.foo`. Over-widening is sound for *types*
but not for the *nil-provenance* the possible-nil rule reasons about. So the
fix must collect the **actual** scope at each `break`, not approximate it.

### Recommended approach — break-scope collection + join (precise)

1. **A break-sink stack on the evaluator.** Entering a loop body pushes a
   fresh sink (an accumulator of `(scope, value_type)` at each `break`);
   exiting pops it. A stack handles nested loops — a `break` targets the
   innermost enclosing loop (top of stack). A `break` inside a *block* that is
   inside a loop also targets the loop (Ruby semantics), so block evaluation
   must not shadow the loop's sink — but a block passed to a method (a
   non-loop `each`) is the escaping-block case already handled separately;
   scope the sink to lexical loop bodies.
2. **`BreakNode` evaluation** appends `(current_scope, break_value_type)` to
   the active sink and returns the diverting/`bot` continuation (as today).
   `break` with no value contributes `nil` to the loop value; `break x`
   contributes `x`'s type.
3. **Loop exit join.** `eval_loop` / `eval_for` join every collected break
   scope's local bindings into the continuation scope (alongside the existing
   normal-exit scope and the ADR-56 fixpoint result), and the loop's *value*
   becomes `nil` (normal completion) joined with each `break <value>` type
   (today a `while`/`for` value is always `Constant[nil]`; a `break x` makes
   it `nil | typeof(x)`).
4. **Exit-edge narrowing already disabled on break.** `narrow_loop_exit_edge`
   ([`statement_evaluator.rb:951`](../../lib/rigor/inference/statement_evaluator.rb))
   already bails when the body contains a `break` (the predicate-exit proof
   does not hold), so the new break-join does not fight it.

The architectural choice is *how* to thread the sink: an evaluator-instance
stack (mutable, simplest, must be push/pop-balanced and re-entrancy-safe) vs.
extending `sub_eval`'s return to carry break scopes functionally (cleaner but
ripples through every `eval_*`). The instance-stack is the lighter change and
matches the engine's existing `on_enter` / recording side-channels; resolve at
implementation time.

### Edge cases to cover

- **Nested loops** — `break` targets the innermost; the stack handles it.
- **`break` inside an `if`/`case`/`begin`** within the loop — the sink
  collects the scope at the `break` regardless of nesting depth.
- **`break <value>`** — contributes to the loop value type, not just bindings.
- **`next` / `redo`** — RELATED but separate: a `next`-path write may also be
  dropped from the fixpoint's fall-through read. Scope this note to `break`;
  evaluate `next` as a follow-up (its scope rejoins the *next iteration*, so
  the fixpoint should ideally fold it — a different fix).
- **`each`-block `break`** — already widens to `Dynamic[top]`; leave as-is (no
  FP), or unify later.

## Relationship to ADR-56

ADR-56 (block-captured local mutation + loop-body fixpoint) propagates the
*fall-through* compounding of loop-body writes (`d *= 2` → `1 | 2 | …`). This
is its missing sibling: the *non-local-exit* (`break`) path's bindings. The
fix layers onto the same `eval_loop` continuation construction; consider
recording it as an ADR-56 addendum or a new ADR if the break-sink mechanism
warrants standalone rationale.

## Gate

- **Corpus before/after diff** over the eight validated corpora (+ a few more
  with search-loops): the always-X FPs (`ChekPairWithGivenSum`, `PassingCars`
  ×2, …) must clear, and **any new `possible-nil` firing must be adjudicated**
  (a genuinely reachable break-path nil is a correct firing; an over-widened
  one is a regression the precise collection must not produce).
- `make verify` green (self-check + plugins; the engine has many flag-and-break
  loops, a live regression guard).
- Hand-probed discriminating shapes: the four loop forms above, nested loops,
  `break <value>`, `break` inside `if`/`case`, and a `x = nil; …; x = 5; break`
  shape (must NOT surface a false possible-nil — the over-approximation trap).

## Reproduction

```ruby
# /tmp/probe.rb — `rigor check --no-cache` reports "always falsey" at `if flag`
def check(arr)
  flag = false
  for i in 0...arr.length
    if arr[i] then flag = true; break end
  end
  if flag then "yes" else "no" end
end
```
