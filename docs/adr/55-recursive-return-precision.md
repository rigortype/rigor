# ADR-55 — Recursive-method return-type precision (constant-arg bounded unroll + fixpoint return summaries)

Status: **Accepted, 2026-06-11. Slice 1 (constant-arg bounded unroll)
and slice 2 (fixpoint return summaries) both implemented 2026-06-11.**
Both are precision-additive — no new diagnostic, no false-positive
surface; every exhaustion path degrades to today's behaviour. Slice 1
ships the fuel-bounded value-keyed guard (`RECURSION_UNROLL_FUEL = 32`,
64-node value-size cap), the `BudgetTrace::RECURSION_UNROLL_FUEL`
counter, and the value-pinned self-call adoption that lets a folded
constant frame surface inside a method body (`factorial(5) →
Constant[120]`). Slice 2 ships the Kleene fixpoint return summary
(`RECURSION_FIXPOINT_CAP = 3`, value-pinned widening on the final
iteration, the `BudgetTrace::RECURSION_FIXPOINT_CAP` counter): the
in-cycle re-entry returns the assumed summary (seeded `bot`) instead of
`Dynamic[top]`, so a recursive String builder called with a
non-constant arg returns `String` and `factorial(x : Integer)` returns
`1 | Integer` — neither carries a `Dynamic[top]` contribution. Both
Mastodon `app/models` and haml `lib` are byte-identical to the
pre-slice-2 baseline.

Archetype: deliberative. Stakes: mid (engine return-inference core; the
mechanisms are FP-neutral by construction but touch the recursion
termination machinery, which is non-negotiable per ADR-41 WD4).

## Context

The recursion re-entry guard
(`ExpressionTyper#infer_user_method_return`, `lib/rigor/inference/expression_typer.rb`
~L1508) is keyed on `(receiver, method)` only and fires at effective
depth 1, returning `Type::Combinator.untyped` for the in-cycle call.
ADR-24 WD5 chose that key deliberately — keying on argument *types* let
mutual recursion through a `module_function` module recurse unboundedly
(`SystemStackError`). The consequence for return precision:

```ruby
def factorial(n)
  n <= 1 ? 1 : n * factorial(n - 1)
end
factorial(5)  # Integer       (the in-cycle factorial(4) is Dynamic[top];
              #                Integer#* happens to absorb it here)
factorial(0)  # Constant[1]   (constant-folded condition skips the cycle)
```

`Integer` survives only because `Integer#*`'s RBS is total over the
`Dynamic` operand. A recursive method that *builds* its result (a
renderer returning `String`, a tree walk returning `Array[T]`) gets a
return joined with `Dynamic[top]` — the recursive contribution is
unanalyzed, and callers see `untyped` contamination with no signature
present.

ADR-41 WD5 already split `recursion_depth` into a hard **termination
floor** (wired, depth 1) and an optional **precision-unroll depth**
(deferred, demand-driven). This ADR is that demand arriving, plus a
second mechanism WD5 did not envision: a fixpoint over the recursive
return itself, which is where the real precision lives. The
constant-arg outcome (`factorial(5) → Constant[120]`) is explicitly
**low-value** per the requester; slice 1 earns its place as the safe
generalization of the guard key and the `BudgetTrace` wiring that
slice 2 reuses, not as a constant-folding feature.

## Decision

Adopt both mechanisms, in order, under one criterion:

> **A recursive-return precision mechanism is admissible only if its
> exhaustion path is byte-identical to today's widening** — fuel out,
> iteration cap hit, value blow-up, non-convergence: every exit returns
> what the depth-1 guard returns now (`untyped`). Precision is gained
> strictly inside a hard, non-configurable termination envelope
> (ADR-41 WD4); no knob may opt into non-termination.

### WD1 — Slice 1: fueled constant-arg unroll

When **every** bound argument of the re-entered call is value-pinned
(`Constant[…]`, or a `Tuple` of such), the guard key extends to
`(receiver, method, argument values)` so distinct constant frames may
recurse. Two hard caps, both counting guards in the ADR-41 WD4 sense:

- **fuel** — total unrolled frames per outermost entry, default 32;
- **value-size cap** — any frame whose pinned values exceed a small
  structural size (e.g. 64 nodes) disqualifies the extension.

Exhaustion or disqualification falls back to the plain
`(receiver, method)` guard — i.e. today's result. Non-constant args
never take this path. New `BudgetTrace` counter
(`RECURSION_UNROLL_FUEL`). Default-on: the caps are termination guards,
not measurement-gated precision budgets (ADR-41 WD3 does not apply).

**Governing clamp rule (necessary, not optional).** The constant-arg
unroll may only ever surface a *fully value-pinned* result; any other
outcome MUST be byte-identical to the plain guard's `untyped`. Two
clamps enforce this, both confining precision to the unroll's own
envelope:

1. A frame that took the extended (value-keyed) path but whose plain
   `(receiver, method)` signature is already on the guard stack — in
   plain form or as the plain part of an extended frame — *would have
   been guarded before slice 1*. After its body evaluates, if the
   result is not fully value-pinned it is clamped back to `untyped`
   (counting a `RECURSION_GUARD` hit). Frames that would not have been
   guarded keep their exact pre-slice-1 result paths.
2. The value-pinned self-call *adoption* (a folded constant surfacing
   inside a method body) is admissible ONLY while an unroll is in
   progress — i.e. the guard stack already carries an extended frame.
   In the main check walk the stack is empty, so adoption returns to
   exactly `self_type.nil? || Bot`.

> **Corpus-FAIL note (2026-06-11).** WD3's corpus gate caught three new
> diagnostics the first slice-1 landing leaked: a mastodon
> `account.rb:496` `undefined method 'in?' for :denied` (a self-call
> return, previously `Dynamic[top]`, resolving to a concrete Symbol
> union an ActiveSupport gap then mis-dispatched), a mastodon
> `base_action.rb:32` always-truthy, and a haml
> `children_compiler.rb:112` always-falsey (`find_else_index` mis-folded
> to always-nil — the body evaluator does not model a non-local
> `return` inside an iteration block, and the blanket adoption surfaced
> that wrong pinned value). Root cause: the blanket
> `adoptable_self_call_result?` broadening adopted *any* fully
> value-pinned result project-wide, exposing the body evaluator's known
> blind spots that the `Dynamic[top]` gate had masked. The two clamps
> above are the fix; both corpora are byte-identical to the pre-slice-1
> baseline after it.

### WD2 — Slice 2: fixpoint return summaries

Replace the cycle result `untyped` with a **Kleene iteration from
`bot`**, per `(receiver, method)` signature, alongside the existing
guard stack:

1. Outermost entry seeds an assumed summary `bot` in a thread-local
   table keyed like `INFERENCE_GUARD_KEY`.
2. In-cycle re-entries return the current assumed summary (instead of
   `untyped`).
3. After the body evaluates, **only if the guard/summary was consulted**
   during it: if the computed return is consistent with (subsumed by)
   the assumption, the fixpoint is reached. Otherwise update the
   assumption to `join(assumption, computed)` and re-evaluate the body.
4. Iteration cap 3. On the final permitted iteration the join **widens
   value-pinned constituents to their nominal base** (`Constant[1]` →
   `Integer`) to force convergence; if still unstable, the summary
   collapses to `untyped` — today's behaviour.

For `factorial(x : Integer)`: round 1 assumes `bot` → body yields
`1 | (x * bot) = Constant[1]`; round 2 yields `1 | Integer = Integer`;
round 3 confirms. Result `Integer` with no `Dynamic` contribution —
and a `String`-building renderer now returns `String`, not
`String | Dynamic[top]`.

`bot` is the correct seed, not a soundness risk: a method that *only*
recurses genuinely never returns (its summary stays `bot`, the
always-diverging shape `adoptable_self_call_result?` already treats as
safe). Mutual recursion remains depth-bounded by the unchanged guard
stack; summaries make the in-cycle result *more* precise, never deeper.

**Implementation notes (2026-06-11).** Two design points settled during
the slice-2 landing:

- *The summary table is keyed by the plain `(receiver, method)`
  signature*, not the slice-1 value-extended one, so a constant-arg
  unroll and the plain recursion share one summary. The outermost frame
  for a plain signature owns the table entry and runs the iteration;
  nested extended frames evaluate the body once and let the owner
  iterate. The entry is dropped when the guard stack drains to empty
  (mirroring the per-entry fuel reset). A per-signature *consulted* flag
  gates the fixpoint: a non-recursive body that merely shares
  `infer_user_method_return` never consults the summary, so it returns
  its computed type directly with no extra iteration.
- *WD4 composition was narrowed.* WD4 step 5 envisioned slice 1's
  fuel-exhaustion **and** clamp fallbacks both routing to the summary.
  The in-cycle guard hit and the fuel-exhausted plain re-entry do route
  to the summary (via `consult_summary`). The slice-1 **clamp**
  (`clamp_unroll_result`), however, keeps returning bare `untyped`: it
  is a soundness backstop for an *untrustworthy unrolled value*, while
  the in-progress summary is a Kleene *lower* bound mid-iteration —
  routing the clamp to it dropped a real base-case constituent in the
  `recursive_unroll_clamp` fixture (`1 | "s"` collapsing to `"s"`). The
  clamp therefore stays the conservative `untyped` upper bound; only the
  guard/fuel paths consult the summary.
- Mutual recursion across two distinct signatures terminates but does
  not generally fold to a precise summary (each signature owns its own
  Kleene iterate), so it degrades soundly to `Dynamic[top]` — today's
  behaviour, the load-bearing property being termination.

**Soundness fix — `bot`-collapse (2026-06-11).** The slice-2 landing
(commit `36c0cfaa`) had a soundness bug: a pass-through recursion with a
reachable non-recursive exit could be typed `bot` ("never returns")
instead of its real return type. Two mechanisms combined:

1. *In-cycle summary not adopted.* Once the Kleene assumption grew past
   the `bot` seed to a value-pinned type (e.g. `Constant[:done]`), the
   in-cycle self-call result returning that assumption failed
   `adoptable_self_call_result?` (which only adopts `Bot` or
   inside-unroll pinned values) and leaked back to `Dynamic[top]`, so the
   iteration never converged on the precise type — it drifted to
   `untyped`. Fix: `adoptable_self_call_result?` now also adopts a type
   that is the live assumption object of an active fixpoint summary
   (`active_fixpoint_summary?`), letting the assumption propagate back
   into the body across iterations.

2. *Trivial convergence at the `bot` seed.* When the call-site argument
   carried a narrow value-set (`some_int : 1 | 2 | 3`), a base-case guard
   like `n <= 0 ? :done : passthrough(n - 1)` constant-folded to
   always-false and the `:done` branch was pruned, so the body computed
   `bot` (recursive branch returns the `bot` seed, base case gone). The
   convergence check `joined == assumption` then held trivially at the
   seed (`bot == bot`) and returned `bot` — unsound, and feeds ADR-47
   reachability / always-falsey diagnostics as a false-positive source.
   Fix (`resolve_bot_collapse`): when an iteration computes `bot` for a
   consulted body, re-run the fixpoint **once** over a parameter-widened
   body scope (`1 | 2 | 3` → `Integer`), which un-prunes the tail base
   case (`passthrough → :done`). If the widened body *still* computes
   `bot` but the body contains a reachable explicit `return` — whose
   value the tail-only body evaluator never folds into the result
   (`pick`'s `return nil`) — floor to the conservative `Dynamic[top]`
   (the pre-slice-2 observable) rather than `bot`. A body that genuinely
   has no non-recursive exit (`spin`) keeps `bot`.

Both Mastodon `app/models` and haml `lib` stay byte-identical to the
pre-slice-2 (`2ba608a0`) baseline after the fix. New regression asserts
(`passthrough → :done`, `pick → Dynamic[top]`) land in
`recursive_fixpoint_summary.rb`; the fixture's Factorial / Builder
asserts are corrected to note they are RBS-absorption anchors (the
recursive branch is an `Integer#*` / `String#+` expression whose return
is fixed by RBS regardless of the in-cycle type), not fixpoint
discriminators — only a *bare* self-call branch discriminates.

### WD3 — Cost envelope and gate

Bodies re-evaluate at most 3× and only for methods that actually
participate in a cycle. The stress corpus is known: haml fired the
guard 421×, jbuilder 126× (ADR-41 survey). Gate per slice:
`make verify` + `make bench-perf` neutral-or-better + a corpus
diagnostics comparison (Mastodon `app/models` and/or Redmine) where the
diagnostic delta must be **zero or strictly removals** — any new
diagnostic is a blocker, not a judgement call.

### WD4 — Ordering and interaction

Slice 1 lands first (smaller, independently testable). Once slice 2
lands, slice 1's fuel-exhaustion path falls back to the fixpoint
summary rather than straight to `untyped` — the two compose, with the
summary as the better floor.

## Rejected / deferred alternatives

- **Key the guard on argument *types* for all calls.** Rejected —
  re-litigates ADR-24 WD5's `SystemStackError`; slice 1 keys on
  argument *values* only, which fuel bounds.
- **Error / diagnose on exhaustion now.** Deferred to ADR-41 WD2's
  `static.*` surface; these slices emit no diagnostic (FP discipline:
  precision-additive only).
- **Make fuel / iteration cap user-configurable now.** Deferred —
  ADR-41 WD4 keeps termination guards hard until a project shows they
  bind; `RIGOR_BUDGET_TRACE` counters provide the evidence channel.
- **Memoized cross-call summaries (per arg-type signature cache).**
  Deferred — a performance refinement, only worth its invalidation
  complexity if WD3's bench gate shows re-evaluation cost on a real
  corpus.

## Consequences

- Recursive methods get signature-free return types with no `Dynamic`
  contamination — the camp-(b) "works on unannotated Ruby" promise
  (ADR-41 WD1) extended to recursion, which no surveyed camp-(b) tool
  does for precision (TypeProf widens to `untyped` at depth 5).
- The wired-guards table in
  `docs/type-specification/inference-budgets.md` § "Implementation
  status" must be updated by each slice (the depth-1 row gains the
  unroll and summary qualifiers); ADR-41 WD5's "precision-unroll:
  deferred" status flips to "instantiated (ADR-55)".
- New maintenance surface: the fixpoint loop becomes part of the
  termination story; its iteration cap is load-bearing and must stay
  hard.

## Relationship to other ADRs

- **ADR-41** — this is WD5's precision-unroll demand arriving; WD4's
  hard-termination rule is this ADR's admissibility criterion; the
  `BudgetTrace` channel is reused.
- **ADR-24** — WD5's guard-key decision is preserved; slice 1 narrows
  it only for value-pinned frames under fuel.
- **ADR-5 / ADR-48** — the precision-additive, zero-FP envelope these
  slices must stay inside.
