# ADR-101 — The branch elision may not rest on an optimistically nil-free carrier

Status: **Accepted — implemented 2026-08-06.** `Inference::OptimisticOrigin` marks a value whose
nil-freeness rests on the `%a{implicitly-returns-nil}` that `RbsDispatch` deliberately reads past, and
the `if`/`unless` branch elision declines a certainty verdict carried by such a value. Measured over
eleven projects: 47 of 2,060 verdicts are affected, diagnostics are byte-identical on every target in
both directions, and a reproducible false positive on correct code is removed.

Grounding: the [shape census](../notes/20260805-issue-286-if-unless-truthiness-elision-census.md) that
found the third consumer, and the [provenance census](../notes/20260806-issue-286-optimistic-carrier-provenance-census.md)
that measured it and retired the carrier-shape option. Both for
[issue #286](https://github.com/rigortype/rigor/issues/286).

## Context

`docs/internal-spec/inference-engine.md` records a deliberate bet: core RBS spells `Hash#[]`'s miss as
an `%a{implicitly-returns-nil}` annotation rather than a `?` return, and `RbsDispatch` reads the return
type only. Honouring the annotation was rejected on false-positive grounds — a `Hash.new(0)` receiver
never returns nil, and a projected `V?` fires `possible nil receiver` on correct code (25 measured
firings on Rigor's own `lib`). The spec draws the consequence itself: such a value is **optimistic, not
proof**, and `MAP[key]` reading as `"x" | "y"` asserts nothing about whether the key was present.

The passage then forbids two consumers from concluding truthiness from it: `flow.always-truthy-condition`
and the `&&`/`||` `constant_value_polarity` gate. **There is a third, and it was never named.**
`Narrowing.predicate_certainty` also drives the `if`/`unless` branch elision, and that consumer is not
`Constant`-gated — it answers `:truthy` for any carrier whose falsey fragment is `Bot`. So the engine
forbids itself a bet in the `&&`/`||` position while making it freely one line away:

```ruby
MAP = { a: "x", b: "y" }.freeze
v = MAP[key]
n = if v then 1 else "none" end   # else arm dropped; n types as 1
n.upcase                          # error: undefined method `upcase' for 1 — the program is correct
```

The asymmetry matters more than it first reads, because the two consumers differ in *what they do with
the verdict*. The gate above only withholds a diagnostic. The elision **deletes a branch the program
really takes when the lookup misses**, and the deletion is silent until the narrowed type meets a method
call — at which point it surfaces as a false positive on working code. That is the wrong side of this
project's top-tier value, so the question is not stylistic: may this consumer make the bet at all?

## Decision

**A certainty judgment may rest on a value's nil-freeness only when that nil-freeness is a property of
the value — its class, its inhabitance, its literal — never when it is a property of our own modelling
choice.** Where the engine deliberately reads past a signature's own statement that a result may be
absent, the value it produces carries that choice, and every consumer that would convert it into a claim
about runtime behaviour must decline.

This is the criterion, and it generalises past today's single case: any future place where Rigor
knowingly types optimistically inherits the same obligation, without the spec having to enumerate
consumers again. It also states the boundary in the other direction — the value stays fully usable for
dispatch, because "we chose this" is a fact about the *judgment*, not a defect in the *type*.

### WD1 — Mark the value where the choice is made

`Inference::OptimisticOrigin` records the cause at `RbsDispatch.translate_return_type`
(`rbs_dispatch.rb` ~L346-372, immediately after the existing `record_void_recovery` call), which is the
one place that still knows the selected overload spelled its miss as an annotation before
`RbsTypeTranslator` erases the distinction.

Three properties are load-bearing. The judgment is **per selected overload** —
`RBS::Definition::Method::TypeDef#overload_annotations` exposes the annotation per overload and
`OverloadSelector.select` returns one of `method_definition.method_types` verbatim, so identity resolves
it exactly: `Array#first` is marked, `Array#first(3)` is not, and a signature that already spells the
miss as `?` (`String#[]`, `Enumerable#find`) is never marked. It is a **side channel** in the
[ADR-75](75-dynamic-provenance.md) / [ADR-82](82-dynamic-provenance-wiring.md) sense: recorded on the
call node, propagated onto local and instance-variable bindings at assignment, resolved back from a bare
read, excluded from `Scope#==` / `#hash`, and never participating in subtyping, consistency,
normalization or erasure. And it is **not applied to a read the shape tier resolved**, because
`ShapeDispatch` answers from a receiver that proves the read cannot miss — a static key on a declared
shape, `first` on a non-empty `Tuple`.

### WD2 — Decline at the consumers, never by widening the falsey fragment

The decline lives in `StatementEvaluator#live_branch_for_if` / `#live_branch_for_unless` and
`ExpressionTyper#constant_predicate_polarity`. It MUST NOT be implemented by teaching
`Narrowing.falsey_nominal?` / `.narrow_falsey` that these carriers might be falsey: `&&=` / `||=` and the
and/or surviving-left edge (`statement_evaluator.rb` ~L382/L384, `expression_typer.rb` ~L661) read the
same functions, and widening the falsey fragment there re-admits `nil` into a bound local and buys
`possible nil receiver` firings. A soundness fix paid for in false positives is precisely the trade this
project does not make, so the placement is a constraint, not an implementation detail.

### WD3 — Carrier shape is not a proxy for this judgment

The obvious cheap gate — decline for non-`Constant` carriers — was implemented, measured, and rejected.
It is wrong in both directions at once. It **over-declines**: of the 134 non-`Constant` verdicts in the
corpus only 35 are actually optimistic, the rest being nominals whose class genuinely excludes `nil` and
`Tuple`/`HashShape` carriers sound by inhabitance. And it **under-declines**: a `Hash` whose values share
one type yields a lone `Constant` that is exactly as optimistic as the union case, so 12 optimistic
verdicts survive it — eight of them one redmine cluster where the verdict is `:falsey` and the elision
drops the arm that actually runs.

## Rejected / deferred alternatives

| Alternative | Verdict | Reason |
| --- | --- | --- |
| Extend the spec's exclusion to name this consumer and keep the behaviour | Rejected | It blesses a reproducible false positive on correct code, and the measurement shows the fix costs nothing to take instead. |
| Decline for all non-`Constant` carriers | Rejected | Over- and under-declines simultaneously (WD3); the shape a carrier happens to have is not the property the judgment turns on. |
| Tighten `falsey_nominal?` so `Object` / `BasicObject` / `Kernel` read as undecidable (#286 as originally filed) | Rejected | Measured zero firings in 41,836 predicates — Rigor's unknown carrier is `Dynamic`, not `Nominal[Object]`. An untested guard defending an empty set, whose acceptance criterion would be met vacuously. |
| Honour `%a{implicitly-returns-nil}` at the source, typing the read `V?` | Rejected | The original 25-FP measurement stands; this ADR deliberately keeps the optimistic *type* and constrains only what a certainty judgment may conclude from it. |
| Propagate the mark through method returns and further chains | Deferred | Demand-gated. The corpus's optimistic predicates are all direct reads or one binding hop; no evidence yet that a deeper channel pays for its complexity. |

## Consequences

- **Positive.** Removes a false-positive class on correct code that reaches ordinary Ruby without any
  dishonest annotation. Closes the asymmetry that let one judgment be read three ways under two rules.
  The criterion is reusable for any future deliberate optimism.
- **Negative.** 47 verdicts across eleven projects stop eliding, so those expressions type as the union
  of both arms. Measured cost: diagnostics byte-identical on all eleven targets in both directions;
  Rigor's own `lib` *gains* 3 `constant` nodes and loses 3 `bot (unreachable)` ones because the
  previously-skipped arm now gets typed; redmine's precision ratio moves 50.93% → 50.92%.
- **Guardrail for future work.** The gate is provenance, so anything that stops recording the mark
  silently restores the old bet. `spec/rigor/inference/optimistic_origin_spec.rb` pairs every decline
  example with a proof-side control that must still elide; both mutants ("always decline", "never
  decline") kill six examples each, so a regression in either direction fails loudly.
- **Acceptance.** `make verify` green, and the corpus A/B reproducible with `--no-cache --no-baseline`
  per the note's method.

## Relationship to other ADRs

- [ADR-78](78-reflexive-overfold-always-truthy.md) — states the WD1 criterion this extends: provable
  truthiness rests only on a genuine constant. Its rejection of a provenance tag does **not** cover this
  case: ADR-78 refused to launder a constant the engine should not have produced, whereas the optimistic
  union is deliberately produced, correct for dispatch, and backed by the 25-FP measurement. The
  question here is not whether the engine may produce the value but whether a judgment may read it as
  proof.
- [ADR-75](75-dynamic-provenance.md) / [ADR-82](82-dynamic-provenance-wiring.md) — the side-channel
  shape this reuses. The difference is what it attaches to: `DynamicOrigin` explains a `Dynamic`, while
  this mark rides ordinary `Union` / `Constant` / `Nominal` carriers.
- [ADR-5](5-robustness-principle.md) — the value that decides the direction: a working program's
  invariant is assumed, so the conservative move is to keep both arms rather than to reason from a bet.
- Issue #152 — the `&&`/`||` widening declined for this same reason; the exclusion this ADR extends is
  what forbids it.
