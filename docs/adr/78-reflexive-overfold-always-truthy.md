# ADR-78 — Reflexive over-fold and the `flow.always-truthy-condition` envelope

Status: **Accepted — WD1+WD2 implemented 2026-06-25 (`REFLECTIVE_SEND_METHODS` guard in `ConstantFolding.try_dispatch`); WD3 partially landed 2026-06-26 (HashShape preservation only — Tuple deferred).** `flow.always-truthy-condition`
concludes a predicate is provably truthy when it folds to a
`Type::Constant`. That conclusion is unsound when the constant came from
an **over-fold** — a fold whose soundness holds only for a narrower form
than the actual runtime expression. The concrete case is a reflective
dispatch `receiver.public_send(method_name)` with a *runtime-variable*
method name that folds to a single `Type::Constant` once the receiver
keeps a foldable shape carrier. This ADR fixes the over-fold at its source
(decline the reflective-send fold on a non-literal method name) rather than
suppressing the rule, which both removes the false positive and **unblocks
[ADR-76](76-effect-modeling-freeze-dup-shape-preservation.md) WD2**
(shape-carrier preservation through `freeze` / `dup`).

Grounding: the [2026-06-14 precision-foldgap recon note](../notes/20260614-precision-foldgap-recon.md)
§ "The one real fold gap" — the ADR-76 WD2 shape-preservation tier was
written, verified corpus-FP-safe (zero new firings across 8 projects), and
**backed out** because on Rigor's own constant-folder it surfaced 12
reflexive `flow.always-truthy-condition`: with the receiver shape
preserved, `receiver.public_send(method_name)` folded to a `Type::Constant`,
so `constant_value_polarity` judged the predicate provably truthy. The note
records the verdict "real gap, ADR-scoped fix … not a quick win."

## Context

The rule has two evaluation points that both rest on a folded `Type::Constant`:

- the `AlwaysTruthyConditionCollector` fires on an `IfNode` / `UnlessNode`
  whose predicate folds to a `Type::Constant`, modulo a conservative skip
  envelope (`DEFENSIVE_PREDICATES`, loop / block ancestors, literal-AST
  predicates), and
- the `&&` / `||` short-circuit gate via
  `ExpressionTyper#constant_value_polarity` (`expression_typer.rb:732`),
  which returns `:truthy` / `:falsey` iff the value `is_a?(Type::Constant)`.

Both treat "this predicate is a `Type::Constant`" as "this predicate's
runtime truthiness is decided." That premise is sound only when the
`Type::Constant` is a *genuine* compile-time constant. It breaks for an
**over-fold**: a fold that is valid for a narrower form (a literal
argument) but was applied to a wider runtime expression (a variable
argument). `receiver.public_send(:foo)` ≡ `receiver.foo` and may legitimately
fold; `receiver.public_send(method_name)` with `method_name` a parameter
must not, because the dispatched method — and therefore the result — is not
statically determined. The over-fold produced a `Type::Constant` that was
then read as provably truthy.

The over-fold only became reachable when the ADR-76 WD2 tier preserved the
receiver's shape carrier across `freeze` / `dup` (without it the receiver
degraded to a nominal / `Dynamic` type and `public_send` never folded). So
the reflexive `always-truthy` firings and the ADR-76 WD2 deferral are the
same root: a reflective-dispatch fold that should never have produced a
constant.

## Decision

### WD1 — The criterion: provable truthiness rests only on a genuine constant

`flow.always-truthy-condition` (and the `constant_value_polarity` gate it
shares) may conclude provable truthiness **only** from a `Type::Constant`
that genuinely holds at runtime — never from a fold whose soundness is
conditional on a narrower form than the actual expression. An over-fold is
a typing bug; the rule reading it as truthy is a *symptom*, and the fix
belongs at the fold, not at the rule's skip envelope.

### WD2 — Fix the cause: decline the reflective-send over-fold

The dispatcher must not constant-fold a reflective send (`public_send` /
`send` / `__send__`) unless its method-name argument is itself a
value-pinned literal `Constant` (`:foo`). With a non-literal method name
the call degrades to the RBS result it should always have had (`untyped`),
exactly as it did before the shape carrier was preserved.

This is precision-neutral everywhere else: `x.public_send(:literal)` still
folds (the dispatched method is statically known), and
`x.public_send(name)` was never legitimately a constant. It is therefore
**strictly false-positive-reducing** — declining an unsound fold can only
remove a spurious `Type::Constant`, never add a firing, and it loses no
genuine `always-truthy` firing (a runtime-variable reflective call should
never have folded). The fix lives at the dispatch tier (the reflective-send
handling reachable from `MethodDispatcher#resolve`), so the unsound constant
never enters the type stream where other consumers (further folds,
narrowing) could also be misled.

### WD3 — Re-apply ADR-76 WD2

Once the reflective over-fold no longer yields a constant, the ADR-76 WD2
shape-carrier preservation tier (`freeze` / `dup` / `clone` / `itself`
returning the receiver type unchanged) can be re-applied. Landing WD3 is
what makes this ADR pay off beyond the bare FP fix — it closes the
`MESSAGES = {…}.freeze; MESSAGES[reason]` fold gap the recon note found.

**As implemented (2026-06-26, partial):** the tier is re-applied to
`HashShape` only (the recon note's actual target), via `shape_self` in
`ShapeDispatch`'s `HASH_SHAPE_HANDLERS` — self-check clean, zero
always-truthy. The **`Tuple`** half is **deferred**: applying the same
preservation to `Tuple` re-surfaces 6 reflexive
`flow.always-truthy-condition` firings in Rigor's own reduce / range
folding code (`reduce_folding.rb`, `statement_evaluator.rb`,
`expression_typer.rb`, the always-truthy collector itself). WD2's
reflective-send guard was therefore **necessary but not sufficient** — it
covers the `public_send` subset, but the Tuple preservation exposes a
*wider* over-fold class (a fold sound only for a narrower form, reached
through paths other than a reflective send). That wider class is the WD1
carry-over below; Tuple preservation re-applies once it is fixed at the
root.

## Rejected / deferred alternatives

- **Suppress the rule for reflective-derived predicates** (add a
  reflective-send skip to `AlwaysTruthyConditionCollector`'s envelope).
  Patches one rule's symptom while leaving the unsound `Type::Constant` in
  the type stream for every other consumer (other folds, equality
  narrowing, `unreachable-clause`). The recon note's discipline is fix the
  cause, not suppress; WD2 does.
- **Tag the folded constant with reflective / over-fold provenance**
  ([ADR-75](75-dynamic-provenance.md) kinship) and decline it in
  `constant_value_polarity`. More machinery than WD2 for the same effect,
  and the over-fold still exists as a typed value other consumers can
  trust. Provenance is the right tool for *explaining* a `Dynamic`, not for
  laundering a constant the engine should not have produced.
- **`# rigor:disable` the 12 self-check firings.** Forbidden by the project
  discipline (fix the cause). It is the reason the WD2 tier was backed out
  rather than shipped with disables.

## Consequences

- **Positive:** removes the 12 reflexive self-check false positives at the
  root, unblocks ADR-76 WD2 (and through it the `freeze`d-literal fold
  gap), and tightens an unsound reflective-dispatch fold that could mislead
  other consumers.
- **Negative:** a small loss of precision on `x.public_send(:literal)` is
  *not* incurred (literal method names still fold); the only behavioural
  change is that runtime-variable reflective calls type `untyped` instead
  of a spurious constant — which is correct.
- **Carry-over:** the same "over-fold ⇏ provable constant" criterion (WD1)
  may apply to other folds that are sound only for a literal form; this ADR
  fixes the one reachable instance (reflective send), and the criterion is
  the guard for the next.

## Relationship to other ADRs

- [ADR-76](76-effect-modeling-freeze-dup-shape-preservation.md) — WD2
  (shape-carrier preservation) is gated on this fix; WD3 re-applies it.
- [ADR-47](47-narrowing-driven-clause-reachability.md) — `flow.unreachable-clause`
  shares the constant-folded-predicate envelope; the same over-fold
  criterion protects it.
- [ADR-75](75-dynamic-provenance.md) — the rejected provenance-tag
  alternative; provenance explains `Dynamic`, it does not justify a
  constant.
