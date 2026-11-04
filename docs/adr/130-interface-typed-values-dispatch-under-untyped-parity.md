# ADR-130 — Interface-typed values: member dispatch, and `untyped` everywhere else

Status: **Proposed, 2026-11-04.** Nothing is implemented. The value half of #929 is proposed. The
assignability half is deferred (§ "Deferred: structural assignability").

The prototype with the parity rule added no diagnostic row on `lib`, on 48 plugin and example trees, or on
fourteen survey targets. All seven false positives the review reproduced in the first draft are silent
under it. The decision awaits the
maintainer's ruling before slice 1 lands.

Grounding: [`docs/notes/20261104-interface-types-prototype-measurement.md`](../notes/20261104-interface-types-prototype-measurement.md)
(per-target deltas with and without the parity rule, the review's repros as fixtures, parity-site reach,
allocation cost).

## Context

RBS interface types (`_ToStr`, `_Each[T]`, `_Reader`, `Rigor::Plugin::_Scope`) carry no information in Rigor
today. `RbsTypeTranslator::TRANSLATORS` maps `RBS::Types::Interface` to `:translate_untyped`
(`lib/rigor/inference/rbs_type_translator.rb` ~L81), so a value typed `_Foo` is `Dynamic[top]`. Two things
wait on that:

- **ADR-128's plugin interfaces are inert.**
  - `base.rbs` types each hook's scope as `Rigor::Plugin::_Scope`, and #2681 carries those types into
    plugin code.
  - Even so, `scope.type_of(node)` reads `Dynamic[top]`.
  - #2686's `plugin.api-surface` rule therefore has nothing to read.
- **ADR-1's capability roles are inert.** An interface-typed parameter checks nothing. That is the
  assignability half, which this ADR defers.

`Dynamic[top]` is more than a value in the engine: it is a signal that 20 sites in `lib/` key on. Each
one either tests a `Dynamic`'s static facet for `Type::Top`, or compares a type with the
`Combinator.untyped` value. The sites are:

- the imprecise-argument passes of overload selection (`ImpreciseArgument`, `FacetDistribution`);
- the #1840 rejoin (`UntypedRejoin`);
- ADR-67 WD3's inferred-parameter override (`StatementEvaluator#untyped_binding?`);
- the unknown-store widening, `SelfSubstitute`, `MultiTargetBinder`, `BlockAutoSplat`, `ClauseWidening` and
  narrowing's `match_dynamic_kind`;
- the ADR-84 memo exemption, the `for` element fallback and the `$_` check;
- the dynamic-origin and boundary-cross records (`MethodDispatcher` ~L198, ~L829);
- the precision lens.

The first draft of this ADR carried an interface value as `Dynamic[_Foo]` and claimed the wrapper kept
those leniencies. It did not.

- Every site above tests for `top`, not for `Dynamic`, so an interface value fell out of all of them.
- The independent review reproduced seven false positives the base does not report, each with `x` typed
  by an interface:
  - with `x : _ToInt`, `(arr * x).first` reports undefined `first` for `String`;
  - with `x : _ToInt`, `(1 + x).nan?` reports undefined `nan?`, and so do the `-`, `*` and `**` forms;
  - with `x : _ToStr`, `x.to_str` after `if x.nil? … elsif x.is_a?(String) … end` reports
    `possible-nil-receiver`, and so does the `case` form.

Terminology ([`CONTEXT.md`](../../CONTEXT.md)): *interface* is the RBS structural type; *protocol* is ADR-28's.

## Decision

An interface-typed value is `untyped` to every site in the engine, with one exception: a call on it to a
member the interface declares resolves through that member's RBS.

**Criterion (parity).** With interface dispatch switched off, `rigor check --format json` must be
byte-identical to erasure on every corpus.

- The one allowed exception is where a type is rendered: `dump_type`, and diagnostic messages that print
  an interface value's type.
- Any other difference is a parity bug.
- Dispatch is the only behaviour the facet may change.

## Working decisions

**WD1 — Representation.** An interface-typed value is `Dynamic[Type::Interface(name, type_args)]`.

- *The carrier.* `Type::Interface` is a plain-lattice carrier.
  - In this ADR it appears only as a `Dynamic` facet.
  - `name` is the RBS type name, spelled as `Nominal` spells class names.
- *Generics.*
  - Type arguments translate in the caller's context.
  - Dispatch binds the interface's own type parameters from
    `RbsLoader#interface_definition(name).type_params`.
  - A defaulted parameter left unbound reads `Dynamic[top]`; for example `R` in `_Each[T, R = void]`
    written `_Each[Integer]`.
- *`self`, `instance` and `class`.* Inside an interface member, `self` is the receiver.
  - `instance` and `class` have no class to name there, so they read `Dynamic[top]`.
  - The prototype passed `Nominal[_Foo]` for `instance`; the implementation corrects that.
- *Aliases.* A user alias that expands to an interface carries the facet. rbs core's conversion aliases
  do not (WD4).
- *Intersections.* An intersection keeps #529's first-informative-member rule: `Node & _Node` reads
  `Prism::Node`, and `_A & _B` stays `Dynamic[top]`.
- *Erasure.* `Dynamic#erase_to_rbs` prints `untyped`, so `sig-gen` output does not change.

**WD2 — Parity through one predicate.**

- The predicate is `Type::Combinator.untyped?(type)`. It is true for `Dynamic[top]` and for
  `Dynamic[Interface]`.
- Every `untyped`-keyed site calls it, instead of testing the facet or comparing with the value.

The site family has a mechanical definition: every expression in `lib/` that does one of these:

- tests a `Dynamic`'s `static_facet` for `Type::Top`;
- compares a type with `Combinator.untyped` by `==` or `equal?`.

The family and its gate:

- Today the family is 20 sites, listed in the measurement note.
- All of them except `Combinator.dynamic`'s own constructor check move to the predicate.
- A spec gates the family: it greps `lib/` for both raw forms outside `Combinator`, and fails on any hit.
  A new site cannot opt out silently.

A second group of sites reads a `Dynamic`'s facet for its content:

- `receiver_descriptor`, `ReceiverBlindBlock`, `BlockAutoSplat#opaque_array_carrier?`;
- `MatchRebinding`'s Regexp test, the effects collector and the census widening.

None of them has an arm for `Interface`, so for an `Interface` facet each answers what it answers for `top`.
The exception is `receiver_descriptor`, which is where dispatch happens (WD3).

Parity settles the two precision losses the review named, by keeping today's behaviour:

- **ADR-67 WD3.** An interface-declared parameter is overridden the same way an undeclared one is.
  - The type inferred from call sites replaces the facet in the method body.
  - The facet survives only where nothing inferred the parameter.
- **An RBS `-> _Foo` result.** It is treated as an `untyped` result wherever one is treated specially:
  - the `EXPLICIT_UNTYPED` origin;
  - the boundary-cross report;
  - the ADR-84 memo exemption;
  - the `for` element fallback.

  It loses the facet exactly where an `untyped` result would defer to another answer.

The alternative choke point, making `Type::Interface` a subclass of `Type::Top`, was rejected
(§ "Rejected alternatives").

**WD3 — Member dispatch, the exception to parity.**

- *How a call resolves.*
  - `RbsDispatch#receiver_descriptor` (`rbs_dispatch.rb` ~L431) maps an `Interface` facet to
    `[name, :interface, type_args]`.
  - `lookup_method` (~L517) answers from the interface definition.
  - Overload selection, block-parameter binding and `self` substitution then run on the member's method
    types.
  - The arguments still go through the parity predicate, so a declared member's overloads are selected as
    they would be for any receiver.
- *A member the interface does not declare reports nothing.*
  - The call falls through the later tiers as a call on an `untyped` receiver does.
    `UniversalObjectDispatch` still answers `is_a?` and `nil?`, and anything else reads `Dynamic[top]`.
  - `call.undefined-method` would be a false positive, because the argument's class is wider than the
    contract its callee wrote. The first-draft prototype recorded 192 such calls, and every one inspected
    exists at runtime.
  - Reporting such calls is an opt-in discipline: #2686's `plugin.api-surface`, scoped to plugin source.
- *Calls on an interface receiver are not argument-checked.* The argument, arity and nil rules skip
  `Dynamic` receivers today, and parity keeps that.

**WD4 — rbs core's conversion aliases stay erased.** The eight aliases in rbs core's `builtin.rbs` that
have the form `C | _ToC` are `int`, `float`, `range`, `string`, `array`, `hash`, `io` and `path`. An
interface reached through one of them translates to `Dynamic[top]`. The reasons:

- They sit on most core method signatures. Carrying them would turn a large share of every program's
  core-call values into interface values.
- Under parity that costs no behaviour, but it changes the rendered type in diagnostic messages, for
  example `got Dynamic[_ToInt] | Integer` where master prints `got Dynamic[top] | Integer`. Carrying the aliases changed 2 Mastodon rows this way; erasing them changed none.
- It gains almost nothing. The class member of the union answers every call the interface member could,
  so the facet adds only `to_str` / `to_int` on the interface arm.

The rule is one fixed set of names. A spec gates it by listing `builtin.rbs`'s aliases of the form
`C | _I`, so a new upstream alias of that form fails the gate until someone classifies it.

**WD5 — Slices, rollout and triggers.**

| Slice | Content | Default |
| --- | --- | --- |
| 1 | WD1 carrier, WD2 predicate and gate, WD3 dispatch, WD4 alias set. A fixture per parity site, the review's seven repros included. A spec section "Interface-typed values" in `structural-interfaces-and-object-shapes.md` | on |
| 2 | #2686 (`plugin.api-surface`, ADR-128 WD6), which reads the facet | bleeding-edge (ADR-128) |

Slice 1's acceptance is the criterion:

- On `lib`, the plugin and example trees and the survey set, its diagnostics differ from master only in
  rendered type text.
- Each parity fixture is silent with the predicate and fires without it.

Re-evaluation triggers:

- A false positive traced to an interface value means the gate missed a form. Widen the gate's pattern and
  route the site through the predicate; never add a per-site exception.
- Revisit WD4 if a core alias's interface arm is ever the only member that answers a call people make.
- Revisit the deferred half when its re-entry conditions hold (below).

Withdrawal trigger:

- The trigger is a release cycle that shows a parity break the predicate cannot express. An example is a
  leniency keyed on something other than the two forms, such as a facet's class name.
- If that happens, revert to erasure, and keep the facet only for the `Rigor::Plugin` interfaces, the scope
  #2686 needs.

## Deferred: structural assignability (half B)

**What was prototyped.** A requirement-side check that refutes a value passed to an interface parameter
when `call.undefined-method` would fire on one of the interface's members.

- On the first draft's corpus it added 3 diagnostics. All 3 are false positives from wrong project
  signatures, and the check found no true positive.
- The review also found that this criterion is not what the oracle implements:
  - the oracle drops the undefined-method chain's call-site-lexical arms;
  - the chain itself misses an RBS-declared `method_missing` (#2792);
  - it also misses Forwardable and non-literal `define_method` (#2793).

**Re-entry conditions.** The half comes back only when all three hold:

1. #2792 and #2793 are fixed.
2. The oracle keeps the chain's lexical arms: the singleton `def` on the local, the `extend` /
   `define_singleton_method` on the local, and the `self.class` mixin form. "Refuted only when
   `call.undefined-method` would fire on `value.member`" is then what the oracle implements.
3. A corpus that includes delegator-heavy applications shows true positives.

**Open questions that move with it:**

- Should a value typed `Object` or `BasicObject` be `maybe`?
- Should a union be refuted only when every member other than `nil` and `Dynamic` is refuted? The
  standard union reading added 20 nullability and element-width false positives on `lib`.
- Should ADR-64's multi-overload channel, whose `interface_accepts_arg?` checks names only, move onto the
  oracle?
- Should signature compatibility be an opt-in tier, for members both sides declare in authored RBS?
- Where should the oracle live? `Acceptance` has no environment, and the prototype installed the oracle
  thread-locally.

The spec's § "Assignability rules" stays unchanged until then.

**The reused-RBS role table (#929's first half) is deferred with half B.**

- The table's consumers are this check, role inference and `hint.role-generalization.*`. None of them is
  built.
- `%a{rigor:v1:conforms-to _Reader}` already resolves without the table: `ConformanceChecker` looks the name
  up in an environment that loads rbs core.
- A table with no reader would be a gate guarding nothing.
- #929 stays open for both halves.

## Rejected alternatives

| Alternative | Reason |
| --- | --- |
| Keep erasing interfaces | It costs nothing and changes nothing, but #2686 cannot start: a plugin-facing interface whose members never resolve cannot back a rule about calls outside it. Parity removes the risk that made the wrapper unsafe, so the remaining choice is dispatch against no change at all. Measured, dispatch adds precision on plugin and sig'd code and adds no diagnostic. |
| `Dynamic[Interface]` without parity (the first draft) | The review reproduced 7 false positives on correct code. |
| `Type::Interface < Type::Top` as the choke point | It needs no site edits, but it misses the seven identity comparisons, `Combinator.dynamic` would collapse the value to `untyped`, and a later requirement-side carrier would inherit "is the universal type". |
| Hand edits at each site, with no predicate | The next `untyped`-keyed site would silently opt out; the gate needs one name to allow. |
| `call.undefined-method` for an undeclared member | The method exists at runtime. ADR-128 WD6 made the same call. |
| Carrying the core conversion aliases | It changes diagnostic text across every corpus, for a facet the union's class member already covers (WD4). |
| A bare `Interface` as the value | Every `untyped`-keyed site would need an arm, and a missed one would be a false positive. |

## Consequences

- **Positive:** declared members of an interface value type their calls.
  - `scope.type_of(node)` reads `Rigor::Type::t` in a plugin hook.
  - `_Each[Integer]#each`'s block parameter reads `Integer`.
  - `_ToStr`'s `to_str` reads `String`.
  - #2686 can start.
- **Positive:** the parity gate turns "an interface value behaves as `untyped`" from a code-reading claim
  into a spec that fails.
- **Negative:** the facet is lost wherever an `untyped` value is replaced, for example by ADR-67 WD3, rejoins
  and joins. It is a last resort, not a type.
- **Negative:** #929's assignability half and role table stay open.
- **Measured:** the parity prototype costs +0.70% allocations on `lib` and +0.08% on Mastodon `app`, inside the 1%
  band. 7 of the 20 parity sites were reached on the corpus, with 3,880 hits; the other 13 need slice 1's
  fixtures.

## Relationship to other ADRs

- [ADR-1](1-types.md) — capability roles and structural interfaces. This ADR covers interface values only;
  assignability is deferred.
- [ADR-5](5-robustness-principle.md) — why the value stays `untyped` to every other rule.
- [ADR-64](64-non-nil-argument-type-mismatch.md) — the name-only interface channel, which this ADR leaves as
  it is.
- [ADR-67](67-parameter-type-inference.md) — WD3's override, which applies to interface parameters unchanged.
- [ADR-84](84-cross-file-return-memo-scoping.md) — the memo exemption the predicate now covers.
- [ADR-128](128-plugin-hook-surface-interfaces.md) — the plugin interfaces this makes resolvable.
  - WD5's seam does not arise: the value is `untyped`, so `_Scope` passes `scope: Scope`.
  - WD6's rule reads the facet.
