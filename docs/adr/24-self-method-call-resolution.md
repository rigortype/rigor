# ADR-24 — Implicit-self method-call resolution

Status: **proposed, 2026-05-20.** Records the project's decision to
resolve implicit-self method calls (a call written with no explicit
receiver, inside a method body) against the enclosing class/module's
method set — its own definitions, its ancestors, and cross-file
project classes — so the resolved method's inferred return type and
parameter contract become visible at the call site. Today such calls
type as `Dynamic[top]`, which is a foundational precision gap.

## Context

Confirmed empirically with `rigor type-of` against
`def nr; raise "x"; end`:

| Call site | inferred type of `nr` |
| --- | --- |
| top level (`w = nr`) | `bot` ✓ |
| inside another method (`def g; v = nr; end`) | `Dynamic[top]` ✗ |

A top-level call resolves to the top-level `def`; **a call from
inside a method body does not resolve** — rigor types it
`Dynamic[top]` and never sees the callee's inferred return type or
parameter contract.

This is not a corner case. It is the root cause of the largest
false-positive cluster found in the
[`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
Mastodon survey. The pattern, from `lib/mastodon/cli/accounts.rb`:

```ruby
def modify(username)
  user = Account.find_local(username)&.user
  fail_with_message 'No user with such username' if user.nil?
  user.role_id = role.id   # 40+ `possible-nil-receiver` diagnostics here
  user.save
  ...
end
```

`fail_with_message` is a guard helper whose body is `raise
Thor::Error, message` — it always diverges, so the engine *would*
infer its return type as `bot`. A `bot`-returning call in
`helper(...) if user.nil?` is a terminating guard exactly like
`raise ... if user.nil?` — the fall-through observes `user`
non-`nil`. But `fail_with_message` is an implicit-self call inside
`#modify`, so it types `Dynamic`, not `bot`; the guard is invisible;
`user` stays `User | nil`; every subsequent `user.<x>` is a
`possible-nil-receiver` false positive. One file, 42 of them.

More broadly, *every* `self`-method call in a project loses its
return type and parameter contract — chained inference degrades to
`Dynamic`, and genuine arity / argument-type bugs on `self`-calls go
uncaught. The guard-helper cluster is simply the most visible
symptom.

The pieces to fix this mostly exist already:

- The cross-file class-discovery pre-pass populates the project
  class registry.
- The engine carries a `self_type` for module-mixin contexts.
- Method return-type inference works (the top-level `type-of`
  result above proves it).

What is missing is the wiring: an implicit-self call site does not
ask "what is `self` here, and does that class — or an ancestor —
define this method?".

## Decision

The engine resolves an implicit-self call inside a method body
against the enclosing definition's `self` type:

1. Determine `self` at the call site — an *instance* of the lexically
   enclosing `class`/`module` for an instance method (`def m`), the
   *singleton* for a singleton method (`def self.m` / `class <<
   self`).
2. Resolve the call name against that type's method set: the
   enclosing class's own definitions, then its ancestors — superclass
   chain and included modules — drawing on both project-discovered
   classes (cross-file) and RBS-known ancestors.
3. On a hit, the call site adopts the resolved method's inferred
   return type and parameter contract, exactly as a call with an
   explicit, known receiver already does.
4. On a miss, the call stays `Dynamic[top]` — today's behaviour
   preserved (WD3).

The change is **precision-additive** for v1: it only ever replaces a
`Dynamic[top]` with a more precise type. It does NOT, in v1, newly
emit `call.undefined-method` for an *unresolved* self-call (WD4) —
that is a separate, gated decision because Ruby's metaprogramming
makes "unresolved" a weak signal for "bug".

## Working decisions

### WD1 — Resolution scope: enclosing class + ancestors, cross-file

The resolution target is the full ancestor chain of `self`'s class,
not just the same file or the same class body. `fail_with_message`
lives in `Mastodon::CLI::Base`; the call is in a subclass in another
file. Resolution consults the cross-file project class registry and
RBS ancestors. A self-call that resolves only because the whole
project was analysed is the common case, not the exception.

### WD2 — `self` is instance-typed for `def m`, singleton for `def self.m`

Inside `def m` the receiver of an implicit-self call is an *instance*
of the enclosing class; inside `def self.m` / `class << self` it is
the *singleton*. The two have different method sets (instance vs
class methods). Resolution uses the matching set. This reuses the
engine's existing `self_type` rather than inventing a parallel
notion.

### WD3 — Unresolved self-calls stay `Dynamic[top]`

A self-call whose name resolves to no known method keeps today's
`Dynamic[top]` type. Ruby methods are routinely defined by
`define_method`, `method_missing`, `attr_*`, and framework DSLs
(ActiveRecord attributes / associations, `delegate`, …). Treating
"not statically found" as "does not exist" would be wrong far more
often than right. Leniency on uncertain dispatch is the
[ADR-5](5-robustness-principle.md) robustness principle applied to
`self`-dispatch.

### WD4 — `undefined-method` on a resolved-closed self-call is a SEPARATE, gated decision

Once self-calls resolve, the engine *could* emit
`call.undefined-method` / `call.wrong-arity` / argument-type
diagnostics for a self-call that resolves-but-mismatches, or for one
that does not resolve on a class with no metaprogramming escape
hatch. That is genuine bug-catching value — but on a
metaprogramming-dense codebase (every Rails model) it is also a
large new false-positive surface. v1 of this ADR does **not** open
it. It is slice 4, gated behind its own evaluation: only flag when
the receiver class is confidently *closed* (every method statically
known; no `method_missing` / `respond_to_missing?` / dynamic
definition; not an RBS-`untyped`-tainted ancestor). Until then,
self-call resolution is purely a precision uplift.

### WD5 — Project method summaries, computed with a bounded pass

To hand a caller the callee's return type, the engine needs a
per-method summary — `(class, method, kind) → return type +
parameter contract` — computed once and consulted at self-call
sites, rather than re-analysing the callee per call. Mutual
recursion (`A` calls `B` calls `A`) is bounded per
[`inference-budgets.md`](../type-specification/inference-budgets.md):
a summary still being computed resolves to `Dynamic[top]` for that
cycle rather than diverging. The existing project-scan pre-pass and
its cache (ADR-6) are the natural home; this may extend the
synthetic-method index or add a sibling project-method-summary
index.

### WD6 — `bot` branches narrow control flow

A self-call that resolves to a `bot`-returning method (a guard
helper that always `raise`s / `exit`s) only pays off if the flow
analysis then treats `helper(...) if x.nil?` as a terminating guard.
Today `eval_if` / `eval_unless` detect a terminating branch
*syntactically* — a hardcoded `EXIT_CALL_NAMES`
(`raise`/`throw`/`exit`/`abort`/`fail`) matched by call name. This
ADR generalises it: a branch whose *inferred type is `Bot`* is a
terminating branch, regardless of how it is spelled. The branch type
is already computed by `eval_if`; the change is to OR it into the
exit test. (A prototype of this generalisation was written and
reverted during the cluster-1b investigation — correct, but inert
until WD1–WD5 make the guard call resolve to `bot` in the first
place. It belongs here, as slice 3, specced alongside the rest.)

### WD7 — Budgets and caching

Resolution and summary computation add analysis work. Both stay
within the [`inference-budgets.md`](../type-specification/inference-budgets.md)
envelope; cross-file resolution rides the existing class-discovery
pre-pass and the ADR-6 cache. A self-call that would exceed the
budget falls back to `Dynamic[top]` (WD3) — never to a slower
unbounded walk.

## Consequences

### Positive

- The Mastodon nil-receiver FP cluster (≈42 in one file, and more
  elsewhere) closes once a guard helper's `bot` return is visible
  (WD1 + WD5 + WD6).
- *Every* `self`-call gains its real return type — chained inference
  on `self`-methods stops degrading to `Dynamic`. Precision uplift
  well beyond the guard-helper case.
- The `bot`-branch flow generalisation (WD6) makes guard clauses
  through *any* diverging helper narrow correctly, not just the five
  built-in exit calls.

### Negative

- New analysis cost (WD7) — bounded, cached, fail-soft.
- Mutual recursion needs the bounded-summary handling (WD5);
  done wrong it would diverge or mis-cache.
- WD4 is deliberately left closed. Users will reasonably ask "why
  doesn't rigor catch this typo'd `self`-call?" — the answer
  (metaprogramming leniency) must be documented, and slice 4 is the
  place that question gets re-opened.

### Carry-over

- Slice 4 (`undefined-method` on closed-class self-calls) is
  deferred, not rejected.

## Implementation slicing (proposed)

Demand-driven; no slice scheduled by this ADR.

### Slice 1 — same-class self-call resolution

Resolve an implicit-self call against the enclosing class's *own*
instance/singleton method definitions; adopt the resolved method's
inferred return type. Per-method summaries (WD5) for the same file.
No ancestors yet, no new diagnostics.

### Slice 2 — ancestors + cross-file

Extend resolution to the superclass chain and included modules,
across project files (the class-discovery registry) and RBS-known
ancestors.

### Slice 3 — `bot`-branch flow narrowing (WD6)

Generalise `eval_if` / `eval_unless` terminating-branch detection
from the syntactic `EXIT_CALL_NAMES` list to "branch inferred type
is `Bot`". Guard clauses through a diverging helper now narrow.

### Slice 4 (gated — separate decision) — diagnostics on closed-class self-calls

`call.undefined-method` / `call.wrong-arity` / argument-type on a
self-call when the receiver class is confidently closed (WD4). Gated
behind its own false-positive evaluation on metaprogramming-dense
codebases.

## Re-evaluation triggers

1. **Slice 1/2 measurably regress analysis wall-time** beyond the
   `inference-budgets.md` envelope → tighten WD7, push more work into
   the cache / pre-pass.
2. **Demand for slice 4** (users wanting typo detection on
   `self`-calls) outweighs the metaprogramming-FP risk on a
   representative survey → schedule slice 4 with the closed-class
   gate.
3. **A method-summary cycle is observed mis-cached** → revisit the
   WD5 bounded-pass / fixed-point handling.

## References

- [ADR-4](4-type-inference-engine.md) — the inference engine this
  resolution plugs into.
- [ADR-5](5-robustness-principle.md) — leniency on uncertain
  dispatch (WD3 / WD4).
- [ADR-6](6-cache-persistence-backend.md) — the cache the summary
  index rides on (WD5 / WD7).
- [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md)
  — the narrowing surface WD6 extends.
- [`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md)
  — the budget envelope (WD5 / WD7).
- [`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
  — the Mastodon survey whose largest FP cluster this ADR closes.
