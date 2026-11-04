# ADR-130 — Plugin-interface values: member dispatch, and `untyped` everywhere else

Status: **Accepted, 2026-11-04, ratified by the maintainer.** It is not implemented yet:

- slices 1a and 1b are pending;
- #2686 is slice 2.

The ADR covers only part of #929's value half: values typed by the plugin-facing interfaces under
`Rigor::Plugin`. Three things are deferred, each with a re-entry condition:

- the same facet for every RBS interface;
- structural assignability;
- the role table.

The prototype was measured on `lib`, 48 plugin and example trees, and fourteen survey targets:

- it added no diagnostic row on any of them;
- its behavioural parity differential was empty;
- with dispatch off, sig-gen output on `lib` and the plugin trees was byte-identical to master;
- lens, with dispatch on, changed 15 plugin-tree return sites, which is the intended precision;
- allocations rose by 0.085% on `lib` (round-3 head).

Three review rounds reproduced findings on earlier drafts: eleven false positives and two structural
divergences, nested tuple and hash-shape joins. All of them are fixtures. The false positives are silent
under this draft, and the joins match master.

Grounding: [`docs/notes/20261104-interface-types-prototype-measurement.md`](../notes/20261104-interface-types-prototype-measurement.md)
(per-target deltas for all three drafts, the parity differential, sig-gen and lens output, the fixtures,
allocation attribution).

## Context

RBS interface types erase to `untyped` today. `RbsTypeTranslator::TRANSLATORS` maps `RBS::Types::Interface`
to `:translate_untyped` (`lib/rigor/inference/rbs_type_translator.rb` ~L81). That leaves ADR-128's plugin
interfaces inert:

- `base.rbs` types each hook's scope as `Rigor::Plugin::_Scope`, and #2681 carries those types into plugin
  code.
- `scope.type_of(node)` still reads `Dynamic[top]`.
- So #2686's `plugin.api-surface` rule has nothing to read.

The obvious fix is to carry an interface value as `Dynamic[_Foo]` and let dispatch read the facet. Two review
rounds showed this is unsafe, because the engine keys behaviour on `Dynamic[top]` itself. Each failure
below was reproduced:

- **The `untyped`-keyed sites.** 20 sites in `lib/` test a `Dynamic`'s facet for `Type::Top`, or compare a
  type with `Combinator.untyped`. An interface facet falls out of every one, and seven false positives
  followed. The sites include overload selection's imprecise passes, the #1840 rejoin, ADR-67 WD3's
  override and the ADR-84 memo exemption; the note lists them all.
  - Example: `(1 + x).nan?` with `x : _ToInt` reports undefined `nan?`.
- **Union normalisation.** `Dynamic[top] | Dynamic[top]` dedups to one member. `Dynamic[_A] | Dynamic[_B]`
  stays a two-member union that no `Dynamic` test sees, so `possible-nil-receiver` follows any join of two
  interface values.
- **A member whose overloads do not take the call.** For `xs.each.with_index` with
  `xs : _Each[Integer, Array[Integer]]`, the block-less call took the block overload's return and reported
  undefined `with_index`.
- **Alias memoisation.** Erasing some interfaces and not others made the closed-alias memo depend on
  translation order.
- **sig-gen.** Dispatch through an interface changed sig-gen output.
- **Nested joins** (round 3). The top-level merge left `[Dynamic[_A]] | [Dynamic[top]]` as two arms, where
  master has one. It also left `{ k: Dynamic[_A] } | { k: Dynamic[top] }` as two shapes, which a later
  `merge` collapsed to a `Hash`.
- **A possibly-nil block-pass** (round 3). `xs.each(&blk).with_index` took the block overload and reported
  undefined `with_index`.

Terminology ([`CONTEXT.md`](../../CONTEXT.md)): *interface* is the RBS structural type; *protocol* is ADR-28's.

## Decision

A value typed by an interface under `Rigor::Plugin` is `untyped` to every site in the engine, with one
exception: a call on it to a member the interface declares resolves through that member's RBS, when one of
the member's overloads takes the call's shape. Every other RBS interface erases to `untyped` as it does
today.

**Criterion (behavioural parity).** With interface dispatch switched off, `rigor check --format json` must
be byte-identical to erasure on every corpus.

- The only exception is rendered type text: `dump_type`, hover, `type-of`, and diagnostic messages that
  print the value's type.
- Dispatch is the only behaviour the facet may change.
- A spec enforces the criterion by running the parity fixtures in both modes. The note records the same
  differential over the corpus.

## Working decisions

**WD1 — Representation.** A plugin-interface value is `Dynamic[Type::Interface(name, type_args)]`.

- `Type::Interface` is a plain-lattice carrier that appears only as a `Dynamic` facet. `name` uses
  `Nominal`'s spelling.
- **Generics.** Type arguments translate in the caller's context. Dispatch binds the interface's own
  parameters from `RbsLoader#interface_definition(name).type_params`. A defaulted parameter left unbound
  reads `Dynamic[top]`.
- **`self`, `instance` and `class`.** Inside a member, `self` is the receiver. `instance` and `class` read
  `Dynamic[top]`.
- **Unions.** `Combinator.union` deduplicates members modulo facet erasure.
  - *Facet erasure* rewrites `Dynamic[<plugin interface>]` to `Dynamic[top]`. It applies recursively inside
    `Tuple` elements, `HashShape` values, `Nominal` type arguments and nested unions.
  - Two or more members that are equal after erasure merge into their erased form. So
    `Dynamic[_A] | Dynamic[top]` becomes `Dynamic[top]`, `[Dynamic[_A]] | [Dynamic[top]]` becomes
    `[Dynamic[top]]`, and `{ k: Dynamic[_A] } | { k: Dynamic[top] }` becomes `{ k: Dynamic[top] }`. A join
    therefore has the shape master's dedup gives it.
  - The facet is lost there. It is a last resort, not a type.
  - A union of one interface member and other members keeps the facet on that member.
  - In `Dynamic[_Scope] | Rigor::Scope`, every `untyped`-keyed consumer sees the interface member through
    the predicate, exactly as master sees `Dynamic[top] | Rigor::Scope`.
  - Dispatch on that union resolves per member. A call declared on both arms answers the join of the two
    answers, where master answers `Dynamic[top]`.
- **Intersections.** #529's first-informative-member rule is unchanged.

**WD2 — Parity: one predicate and two gates.**

`Type::Combinator.untyped?(type)` is true for `Dynamic[top]` and for `Dynamic[Interface]`. Every site that
keys a leniency on `untyped` calls it. Mechanically, that is every expression in `lib/` that does either
of these:

- tests a `Dynamic`'s `static_facet` for `Type::Top`;
- compares a type with `Combinator.untyped` by `==` or `equal?`.

All of them move to the predicate except `Combinator.dynamic`'s own constructor check. The union merge
(WD1) uses the same erasure.

Some sites read a facet for its content: `ReceiverBlindBlock`, `BlockAutoSplat#opaque_array_carrier?`,
`MatchRebinding`'s Regexp test, the effects collector and the census widening. None of them has an arm for
`Interface`, so for an `Interface` facet each answers what it answers for `top`. `receiver_descriptor` also
reads the facet; it is the dispatch exception (WD3).

Parity keeps today's behaviour even where the facet would be more precise:

- ADR-67 WD3 overrides an interface parameter.
- An RBS `-> _Foo` result is treated as an `untyped` result wherever one is treated specially.

Two gates enforce parity:

- **Behavioural.** A spec runs every parity fixture twice.
  - With dispatch off, the run must match the erasure baseline after a single normalisation: each rendered
    facet name, `Dynamic[<plugin interface>]`, becomes `Dynamic[top]`.
  - Everything else must be byte-identical, so a structural divergence (an extra union arm, a lost shape)
    cannot pass as rendered text.
  - With dispatch on, the run may differ only at calls of declared members.
- **Lint.** A spec greps `lib/` for the two raw forms outside `Combinator` and fails on any hit. It is
  cheap, but it only catches a known spelling, so the behavioural gate is the one that binds.

**WD3 — Member dispatch.**

- `RbsDispatch#receiver_descriptor` (`rbs_dispatch.rb` ~L431) maps an `Interface` facet to
  `[name, :interface, type_args]`.
- `lookup_method` (~L517) answers from the interface definition.
- Overload selection, block-parameter binding and `self` substitution then run on the member's method
  types.

**The overload-shape rule.** Dispatch resolves only when one of the member's overloads takes the call's
shape:

- a block when the call passes one, and no required block when it does not;
- the positional count, within required plus optional unless the overload has a rest parameter;
- no required keyword the call omits.

Otherwise the call reads `untyped`. The argument rules never check a call on a `Dynamic` receiver, so
nothing else would catch a shape mismatch. Without the rule, dispatch took whichever overload the
selector's fallback picked, and that overload's return made the next call wrong.

**A block-pass that may be nil matches both shapes.** This covers `&expr` where `expr` is a nil-bearing union
or `Dynamic`. At runtime the call may be block-less, so the call answers only when two things hold:

- both the block-ful and the block-less shape are taken;
- their returns agree.

Otherwise the call reads `untyped`. Before this rule, `xs.each(&blk).with_index` with a possibly-nil `blk`
took the block overload's `Array[Integer]` and reported undefined `with_index`. `&:sym` is never nil, so
it keeps the ordinary block shape.

**A member the interface does not declare reports nothing.**

- The call falls through the later tiers, as a call on an `untyped` receiver does.
- `call.undefined-method` would be a false positive, because the value's class is wider than the
  interface. `lib/rigor/plugin/base.rb` itself reads `class_ordering` and `io_boundary_for` beyond what
  `_Environment` and `_Services` declare.
- Reporting such calls is the job of #2686's opt-in `plugin.api-surface`.

**WD4 — Scope: the `Rigor::Plugin` interfaces only.** An interface carries the facet when its absolute name
is in the `::Rigor::Plugin` namespace. Today that means the five interfaces in
`sig/rigor/plugin/interfaces.rbs`. The reasons:

- This is all #2686 needs.
- It reaches no user code; only plugin source and `lib/` hold such values.
- rbs core's conversion aliases (`int`, `string`, `path`, …) contain no plugin interface, so they need no
  rule of their own.

The scope also keeps the alias memo sound:

- Whether an interface carries the facet is a pure function of its `TypeName`, through the namespace path.
  A closed alias therefore translates to the same type whichever file or worker translates it first.
- So `@closed_alias_translations`, keyed by the expansion, stays correct.
- If a later slice makes the facet depend on anything but the type name, it must add that input to the memo
  key. If it cannot, it must bypass the memo, as a requirement translation would.

**WD5 — Which outputs show the facet.**

| Output | Behaviour |
| --- | --- |
| `sig-gen` | Analyses with interface dispatch off, so its output is master's by the parity criterion. Measured with dispatch on, 13 of 1,358 plugin-tree candidates changed from skipped to a new return; 11 of them were `prepare: (untyped) -> nil` through `_FactStore#publish`. With dispatch off, both `lib` and the plugin trees were identical to master. |
| lens | Runs with dispatch **on**, as `check` does. Lens is documented as the type `rigor check` gives, so it shares `check`'s snapshot and needs no separate fingerprint. The 15 plugin-tree `body_return` sites that change from `untyped` to a type are intended precision: 12 read `nil` through `_FactStore#publish`, and 3 read an `Array` type. `lib` is unchanged. |
| `type-of`, hover, `dump_type` | These render `Dynamic[Rigor::Plugin::_Scope]` and the precise results of declared-member calls. That rendering is the intended text. |

sig-gen alone runs with dispatch off. It writes RBS a plugin author did not write against an interface, and
it reads no analysis cache, so no cache identity is involved.

**WD6 — Slices, rollout and triggers.**

| Slice | Content | Default |
| --- | --- | --- |
| 1a | The `untyped?` predicate at every site, the union merge, both gates and the parity fixture harness. No `Interface` carrier exists yet, so output is byte-identical by construction | on |
| 1b | The `Rigor::Plugin` interface carrier and dispatch with the overload-shape and nil block-pass rules; a fixture per parity site and every review repro on plugin interfaces; a spec section "Interface-typed values" in `structural-interfaces-and-object-shapes.md` | on |
| 2 | #2686 (`plugin.api-surface`, ADR-128 WD6), which reads the facet | bleeding-edge |

Triggers:

- **Re-evaluation.** A false positive traced to an interface value is a parity bug. The fix widens the
  predicate or a gate, never a per-site exception.
- **Withdrawal.** If a parity break cannot be expressed through the predicate, revert to erasure and give
  #2686 a receiver-syntax test instead. An example is a leniency keyed on a facet's class name.

## Deferred

**The facet for every RBS interface.** It re-enters when the behavioural parity differential is green over
the corpus with the facet on all interfaces. At that point, rbs core's conversion aliases are decided by
measurement. The first draft found that carrying them changes diagnostic text (`got Dynamic[_ToInt] |
Integer`) for a facet the union's class member already covers.

**Structural assignability (half B).**

- What it was: an interface parameter refuting a value when `call.undefined-method` would fire on one of the
  interface's members.
- What the prototype found: 3 diagnostics, all false positives from wrong project signatures, and no true
  positive.
- What the review found: the oracle drops the undefined-method chain's call-site-lexical arms, and the
  chain itself misses #2792 and #2793.

It re-enters when all three of these hold:

1. #2792 and #2793 are fixed.
2. The oracle keeps the lexical arms: the singleton `def`, `extend` / `define_singleton_method` on the
   local, and the `self.class` mixin form.
3. A delegator-heavy corpus shows true positives.

Open questions that move with it:

- Should a root-class (`Object`, `BasicObject`) value read `maybe`?
- Should the union reading be every-member? The standard reading added 20 nullability and element-width
  false positives on `lib`.
- Should ADR-64's name-only multi-overload channel move onto the oracle?
- Should there be a signature tier for RBS authored on both sides?
- Where should the oracle live?

**The reused-RBS role table** is deferred with half B.

- Its consumers are half B, role inference and `hint.role-generalization.*`, and none of them is built.
- `conforms-to _Reader` already resolves through `ConformanceChecker` without it.

#929 stays open for all three.

## Rejected alternatives

| Alternative | Reason |
| --- | --- |
| **The facet for every interface (draft 2)** | It reaches every program's core calls and user signatures, while #2686 needs only the plugin interfaces. This is deferred, not rejected: it re-enters on a green corpus parity differential. |
| **Keep erasing** | It costs nothing and changes nothing, but #2686 cannot start: it has no interface to check calls against. Scoped to `Rigor::Plugin`, the facet now reaches no user code, and the gates hold parity. |
| A receiver-syntax test for #2686 (no carrier) | It cannot follow `scope` through locals, helpers or `with_local`. It is the withdrawal fallback. |
| `Dynamic[Interface]` without parity (draft 1) | It produced 7 false positives on correct code. |
| Parity without the union merge and the shape rule (draft 2) | It produced 3 more false positives: two joins and `each.with_index`. |
| `Type::Interface < Type::Top` | It misses the identity comparisons, and `Combinator.dynamic` would fold it away. |
| A grep gate alone | It cannot see a leniency keyed on a form it does not know; the behavioural gate can. |
| `call.undefined-method` for an undeclared member | The method exists at runtime. |

## Consequences

- **Positive:** in plugin code, declared members of the plugin interfaces type their calls.
  `scope.type_of(node)` reads `Rigor::Type::t`, and `scope.environment` reads
  `Dynamic[Rigor::Plugin::_Environment]`. #2686 can start.
- **Positive:** parity is held by a behavioural gate, not a code-reading claim.
- **Newly reachable:** a `call.possible-nil-receiver` in third-party plugin code. It applies to results
  of `_Scope#local`, `_Scope#self_type`, `_Scope#source_path` and `_Environment#nominal_for_name`, which
  the interfaces declare nilable. The finding is correct by contract, and it is the same finding a nominal
  `Rigor::Scope` receiver would give. The bundled plugins measured clean. Slice 1b ships it on by default,
  with a changelog line.
- **Negative:** the facet is lost at every join with another `untyped` value, and wherever ADR-67 WD3
  overrides it.
- **Negative:** most of #929 stays open, and the general facet waits on its own measurement.
- **Measured:**
  - +0.085% allocations on `lib` at the round-3 head. Before the nested merge, the draft 3 head measured
    +0.007% on `lib` and +0.005% on Mastodon `app`.
  - Draft 2's 0.45 points came from `TypeName#to_s`, which draft 3 does not call.
  - Draft 3's first union merge cost 1.26 points by building an array on every normalisation. Counting
    first removed it.

## Relationship to other ADRs

- [ADR-1](1-types.md) — capability roles and structural interfaces. This ADR covers plugin-interface values
  only.
- [ADR-5](5-robustness-principle.md) — why the value stays `untyped` to every other rule.
- [ADR-64](64-non-nil-argument-type-mismatch.md) — the name-only interface channel, which this ADR does not
  change.
- [ADR-67](67-parameter-type-inference.md) — WD3's override, which applies to interface parameters
  unchanged.
- [ADR-84](84-cross-file-return-memo-scoping.md) — the memo exemption the predicate covers.
- [ADR-128](128-plugin-hook-surface-interfaces.md) — the plugin interfaces this ADR makes resolvable.
  - WD5's seam does not arise: the value is `untyped`, so `_Scope` passes `scope: Scope`.
  - WD6's rule reads the facet.
