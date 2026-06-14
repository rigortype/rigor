# ADR-64 — Non-nil argument-type-mismatch and the coerce barrier

Status: **Proposed — the non-nil argument channel is designed here and
demand-gated.** The `nil` channel shipped FP-safely this cycle (`a2775c7b`
multi-overload, `0afc65ea` interface-alias; [ADR-62](62-mutation-testing-teeth-measurement.md)
teeth sweep over CRuby `lib/`). The non-nil (`type_swap`) channel is the
single largest remaining false-negative cluster but is deferred behind
Ruby's `coerce` protocol until a corpus or user demonstrates real teeth
past the nil channel.

Grounding: [`docs/notes/20260613-mutation-teeth-harness.md`](../notes/20260613-mutation-teeth-harness.md)
(the sweep + the nil-channel landings), [ADR-62](62-mutation-testing-teeth-measurement.md).

## Context

`call.argument-type-mismatch` fires when a call argument's type is
incompatible with the parameter's. This cycle extended it to the **nil
channel** — a pure-`nil` argument rejected by every overload's matching
positional param, deciding nil-admittance on the RBS parameter type so it
sees through multi-overload methods and interface-alias params
(`check_rules.rb` `param_admits_nil?`). It landed FP-safely: zero new
firings across 12 `rigor-survey` projects.

The ADR-62 mutation sweep leaves the **non-nil channel** — a wrong-*typed*
argument (`type_swap`: an `Integer` where a `String` is expected, …) — as
the largest surviving false-negative cluster (~900 mutants, vs the nil
channel's ~520 now killed). Whether to extend the rule to non-nil arguments
is the decision.

The blocker, which `nil` sidestepped, is **Ruby's `coerce` protocol**.
`5 + Money.new` is valid at runtime — `Integer#+` calls `Money#coerce(5)`
when the argument is not a `Numeric` — even though no RBS `Integer#+`
overload lists `Money`. A naive "fire when no overload accepts the argument"
rule (sound for `nil`, which never coerces) would **false-positive on every
coercible user type**. That is exactly why `nil` was the FP-safe core.

## Decision

Record the FP-safe shape; **demand-gate the implementation**.

**Criterion (the reusable rule).** A non-nil argument may be reported only
where **runtime acceptance is decidable from types alone** — where neither
`coerce` nor a conversion protocol can rescue it:

- **Exclude the coerce-dispatch operators.** The binary arithmetic /
  ordering operators (`+ - * / % ** & | ^ << >> < > <= >=` and the
  `Comparable`-mixin `<=>`-derived forms) dispatch through `coerce` /
  `<=>`; a non-`Numeric` argument to them is *never* statically refutable,
  because a user type may define `coerce`. Non-nil arg-checking does not
  apply to them. (`nil` stays covered there — it cannot coerce.)
- **For the remaining (non-operator) methods, generalize
  `param_admits_nil?` to `param_accepts_arg_class?`** — does the argument's
  concrete class satisfy the parameter, resolving the RBS interface the
  translator degrades? (Does `Integer` implement `_ToStr`? No → `"a".sub(0,
  …)` is a genuine mismatch.) This reuses the nil work's alias / interface
  resolution (`RbsLoader#expand_type_alias`, `interface_method_names`),
  asking "does the arg class respond to the interface's methods" instead of
  "does NilClass."
- **Conservative by construction**, as the nil channel: an undecidable
  param (type variable, unresolved interface, `untyped`) admits; the rule
  fires only on a positively-refuted concrete arg class.

**Gate (when to build).** Ship only when the marginal teeth justify the
added FP surface: a `rigor-survey` corpus pass (or a user report) showing
the non-operator non-nil channel produces **real teeth with zero new corpus
false positives** — the bar the nil channel cleared. Until then it stays
designed-but-unbuilt, because the high-confidence portion (nil) already
landed and the residual is dominated by `coerce`-operator survivors
(excluded) and correct silence.

## Working decisions

- **WD1 — the coerce-operator exclusion is a fixed allow-list, not a
  heuristic.** The operators are an enumerable set; model them like the
  existing `UNIVERSAL_EQUALITY_METHODS` exemption (the `==` / `<=>` family
  is already exempt) with a `COERCE_DISPATCH_METHODS` set, rather than
  detecting `coerce` definitions. The widening applies to the *non-nil*
  case only.
- **WD2 — `param_accepts_arg_class?` is the nil predicate generalized, not
  a new `Acceptance` path.** Keep it at the check-rules layer on the RBS
  param type (not `Inference::Acceptance`, which deliberately degrades
  interfaces to gradual). The arg side becomes "class `C` implements
  interface `I`" — look up `C`'s method set as `nil_class_has_method?` does
  for `NilClass`.
- **WD3 — restrict to a single concrete arg class.** Like the nil channel's
  pure-nil restriction, fire only when the argument types to one concrete
  class (not a union, not gradual); a union arg mirrors the union-receiver
  story and stays deferred.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Naive "no overload accepts the arg" for all non-nil args | **Rejected** — false-positives on every coercible user type (`5 + Money.new`). The coerce barrier is the whole reason `nil` was the safe core. |
| Model `coerce` (track which types define it) to keep operator checking | **Rejected** — unbounded (any user type may define `coerce`); the operator exclusion is the cheap sound approximation. |
| Detect coerce by checking the arg class for a `coerce` method | **Deferred** — could narrow the exclusion (fire when the arg class provably lacks `coerce`), but adds surface for an already-gated channel; revisit only if operator-arg teeth are demanded. |
| Build the non-operator channel now | **Deferred** — no demonstrated corpus teeth past the nil channel; ship on the trigger above. |

## Consequences

- **Positive** — records the coerce criterion (the reusable
  "decidable-from-types" rule) so the next implementer does not re-derive
  the FP trap; the nil channel's `param_admits_nil?` is the proven
  substrate to generalize.
- **Negative** — the largest teeth cluster stays open; accepted because its
  high-confidence portion (`nil`) already landed and the remainder is
  coerce-bound or low-yield.
- **Carry-over** — namespaced type-alias resolution in `expand_type_alias`
  (the `MatchData#[]` / `::MatchData::capture` gap the nil channel surfaced,
  where the alias is not top-level) rides along with WD2's interface work
  if/when the channel is built.

## Relationship to other ADRs

- **ADR-62** — productizes the teeth-sweep backlog this records; the harness
  re-measures the kill on build.
- **ADR-58** — the declaration-sourced-`nil` excusal carries to the non-nil
  channel unchanged.
- **ADR-5** (robustness principle) — the asymmetry holds: strict on a
  refuted argument value, lenient exactly where `coerce` could rescue.
