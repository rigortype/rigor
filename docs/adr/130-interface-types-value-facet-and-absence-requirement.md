# ADR-130 — RBS interface types: a gradual value facet and an absence-only structural requirement

Status: **Proposed, 2026-11-04.** Nothing is implemented. A throwaway prototype measured both halves
separately over `lib`, 48 plugin and example trees and twelve survey targets: the value half added no
diagnostic site, and the requirement half added 3, all false positives caused by wrong project
signatures upstream of the check. The decision awaits the maintainer's ruling before any slice lands.

Grounding: [`docs/notes/20261104-interface-types-prototype-measurement.md`](../notes/20261104-interface-types-prototype-measurement.md)
(diagnostic deltas per half over `lib`, the bundled plugins and examples, and twelve survey targets;
reach counts; allocation cost).

## Context

RBS interface types (`_ToStr`, `_Each[T]`, `_Reader`, `Rigor::Plugin::_Scope`) carry no information in
Rigor today. `RbsTypeTranslator::TRANSLATORS` maps `RBS::Types::Interface` to `:translate_untyped`
(`lib/rigor/inference/rbs_type_translator.rb` ~L81), so a value typed `_Foo` is `Dynamic[top]` and a
parameter typed `_Foo` accepts anything. Three things wait on that:

- **ADR-1's capability roles are inert.** The core role catalog (#928, `data/capability_roles/`) is
  checked only by an explicit `%a{rigor:v1:conforms-to}` assertion
  (`lib/rigor/rbs_extended/conformance_checker.rb`). An interface-typed parameter, the place roles are
  meant to be used, checks nothing.
- **ADR-128's plugin interfaces are inert.** `base.rbs` types every hook's scope as
  `Rigor::Plugin::_Scope`, and #2681 makes those types reach plugin code, but `scope.type_of(node)` still
  reads `Dynamic[top]` (#2686).
- **The binding spec over-promises.** `structural-interfaces-and-object-shapes.md` § "Assignability
  rules" says member compatibility MUST compare arity, parameters, blocks, overloads and returns. No part
  of that exists, and the strictest reading would fire on correct code wherever an upstream signature is
  narrower than the method it describes.

Two pieces of the engine already reason about interfaces and shape the decision:

- **`call.argument-type-mismatch` sees through interfaces by name, in two channels only.** The nil channel
  (`interface_admits_nil?`, `check_rules.rb` ~L3820) and ADR-64's multi-overload non-nil channel
  (`interface_accepts_arg?`, ~L3902) walk the RBS parameter type and ask whether the argument's class has
  every member name. A single-overload interface parameter is never checked (`read_argument_mismatch`
  ~L3987 returns on the `Dynamic` param).
- **`Acceptance` has no environment.** `Inference::Acceptance.accepts` (`acceptance.rb` ~L33) decides
  class relations from the analyzer's own process (`class_subtype_result` ~L1244). A structural check
  needs RBS and the project's discovery tables, so it cannot live inside the pure acceptance table.

The risk is entirely on the assignability side: deciding that a value does **not** satisfy an interface
fires on correct code whenever the decision is wrong (ADR-5). The member-dispatch side only adds
precision to values that read `Dynamic[top]` today.

Terminology ([`CONTEXT.md`](../../CONTEXT.md)): *interface* is the RBS structural type; *protocol* is
ADR-28's.

## Decision

An interface type states what a value answers, never what it is. Rigor reads it two ways, by position:

1. **As a value** (a return, a bound parameter, a block parameter, an element type) it is
   `Dynamic[Interface[...]]`: gradual like `untyped`, with the interface as its static facet. Dispatch
   reads the facet; every other rule keeps treating the value as `Dynamic`.
2. **As a requirement** (a declared parameter or return type a check rule compares against) it is a bare
   `Interface[...]`, decided structurally through the absence oracle in WD3.

**Criterion.** A value is refuted against an interface only when, for some public member the interface
requires, `call.undefined-method` would fire on `value.member`. Interface assignability therefore makes no
absence judgement the undefined-method rule does not already make; it applies that rule's evidence at a
new position. Everything the rule cannot prove absent is `maybe`, and `maybe` never fires.

## Working decisions

**WD1 — The carrier.** `Type::Interface(name, type_args)`, `name` being the RBS type name in `Nominal`'s
spelling. It is a plain-lattice carrier with `erase_to_rbs` giving the interface name.

- *Generics.* Type arguments translate in the caller's context. Dispatch binds the interface's own
  parameters from `RbsLoader#interface_definition(name).type_params` (not
  `Reflection.class_type_param_names`, which knows only classes). A defaulted parameter left unbound
  (`_Each[T, R = void]` written `_Each[Integer]`) reads `Dynamic[top]`, as an unbound class parameter does.
- *`self`, `instance`, `class`.* Inside an interface member, `self` is the receiver: the
  `Dynamic[Interface]` value. `instance` and `class` have no class to name there, so they read
  `Dynamic[top]`, the translator's reading when no instance type is supplied. The prototype passed
  `Nominal[_Foo]` for `instance`, which the implementation corrects.
- *Aliases.* An alias expands through the existing `translate_alias` path, so `string` reads
  `String | Dynamic[_ToStr]` as a value and `String | _ToStr` as a requirement. The closed-alias memo is
  keyed by the expansion, so a requirement translation bypasses it.
- *Unions* hold interface members like any other member.
- *Intersections* keep #529's first-informative-member rule. `Node & _Node` still reads `Prism::Node`;
  `_A & _B` reads `Dynamic[top]` as a value and `_A` as a requirement, so the requirement under-checks
  rather than over-checks (a known limit).
- *Erasure back to `Dynamic[top]`.* An interface the environment does not hold, a member the interface
  does not declare, and every rule other than dispatch read the value as they read `Dynamic[top]` today.
  `Dynamic#erase_to_rbs` still prints `untyped`, so `sig-gen` output does not change in the first slice.

The value is wrapped rather than bare because every leniency the engine applies to an unknown value is
keyed on `Dynamic`: narrowing (`is_a?` on the value), `possible-nil-receiver`, truthiness, the
argument rules' `return nil if arg_type.is_a?(Type::Dynamic)`, overload selection's imprecise-actual
passes. A bare carrier as a value would have to opt into each of them, and every one it missed would be
a new false positive. The wrapper also settles ADR-128 WD5's seam without either remedy it lists: a
`_Scope` value passed to `Reflection`'s `scope: Scope` is `Dynamic`, which passes any boundary.

**WD2 — Member dispatch on an interface-typed value (half A).** `RbsDispatch#receiver_descriptor`
(`rbs_dispatch.rb` ~L431) maps the facet to `[name, :interface, type_args]`; `lookup_method` (~L517)
answers from `interface_definition(name).methods`; overload selection, block-parameter binding and
`self` substitution run unchanged on the member's method types.

- A member the interface declares types its call from the member's RBS: return type, block parameters,
  overloads.
- **A member the interface does not declare reports nothing.** The call falls through to the later tiers
  (`UniversalObjectDispatch` still answers `is_a?`, `nil?`, `respond_to?`) and otherwise reads
  `Dynamic[top]`. `call.undefined-method` means "this raises `NoMethodError`", and a call outside a
  parameter's interface does not raise: the argument's real class is wider than the contract its callee
  wrote. The prototype counted 192 undeclared calls on interface receivers across the measured trees:
  `Object` methods (`to_s`, `is_a?`, `nil?`, `respond_to?`), engine members `lib/rigor/plugin/base.rb`
  reads past `_Environment` and `_Services` (`class_ordering`, `io_boundary_for`), and calls that rely on
  the argument's real class (faraday's `Headers#initialize_copy` reading `other.names` through
  `Hash#initialize_copy`'s `hash[K, V]` parameter, `Hash | _ToHash`). Every one inspected exists at runtime. A rule that reports calls outside a declared interface is a different discipline,
  "you rely on more than your signature promises", and belongs in an opt-in rule, as ADR-128 WD6 already
  decided for plugin code (`plugin.api-surface`). #2686 builds that rule on this facet.
- Argument, arity and nil checks of a call **on** an interface receiver do not run in this slice: the
  receiver is `Dynamic`, which those rules skip. They are the signature tier's (WD4).

**WD3 — Assignability (half B): the absence oracle.** A requirement position compares through
`Acceptance` as usual; the `Interface` handler consults a conformance oracle the check rule installs for
the duration of its comparison (a thread-local, the pattern `refusing_unread` already uses), because the
oracle needs the scope. Without an oracle the handler answers `maybe`. For a requirement `I` and a value
`v`:

| `v` | Verdict |
| --- | --- |
| `Dynamic[...]`, `bot` | `yes` (gradual, as today) |
| another interface `J` | `yes` when `I`'s members are a subset of `J`'s, else `maybe` |
| a union | members other than `nil` and `Dynamic` decide: `yes` if all conform, `no` only if **every** one is refuted, else `maybe`; a `Dynamic` member makes it `yes`; `nil` alone is the nil channel's |
| a class instance, literal, shape or refinement (its `concrete_class_name`) | `yes` when every public member is on the class's RBS surface or the project's source surface for it; `no` when some member is provably absent (below); else `maybe` |
| a value typed `Object` or `BasicObject` | `maybe`: in a signature those names mean "any object" |
| a class object (`Singleton`), anything else | `maybe` |

*Provably absent* is `call.undefined-method`'s receiver-side chain (`undefined_method_diagnostic`,
`check_rules.rb` ~L743) without its call-site-lexical arms, extracted so both rules share one
implementation. How each source of methods is treated follows from it:

- **`Dynamic` / untyped** — `yes`.
- **A source-only class** (no RBS) — its discovered `def`s, `attr_*` and literal `define_method`s count as
  presence; an absent member is `maybe`, because the chain requires an RBS-known class.
- **`method_missing` / `respond_to_missing?`** — on the class or an RBS ancestor, `maybe`
  (`RbsReceiverSurface.ancestor_may_answer?`).
- **Refinements** — a refinement of the class in effect at the call site that defines the member makes
  it `maybe` (#1120's `refined_method_in_effect?`). The callee's lexical scope does not see the
  refinement, but some core conversions do (`to_s` in interpolation), and a refinement is rare enough
  that the conservative reading costs nothing measurable.
- **`define_method` with a non-literal name** — whatever the undefined-method rule already treats as an
  open surface; this ADR adds no rule of its own.
- **Modules mixed in** — RBS `include`s are in the definition; a project `include` of a module the
  project or RBS declares counts through `ancestry_declares_method?`; an unknown mixin makes the class
  open (`unknown_mixin_includer?`).
- **Overloads and method-type compatibility** — name-only in the default tier. The member's existence is
  what Ruby's implicit conversions and duck-typed callees test; a signature mismatch between two authored
  declarations is the signature tier's (WD4).
- **Generic interface arguments** — ignored in the default tier: `Array[String]` is `yes` for
  `_Each[Integer]`. Checking them needs the member's signature, which is the signature tier.
- **Union values** — the every-member reading in the table. It is deliberately weaker than the nominal
  channel, which fires today on `String?` passed as `String`. The prototype's standard union reading added
  20 diagnostics on `lib`, every one a false positive: 19 nullability (`File.expand_path(x, __dir__)`
  against `String | _ToPath | _ToStr`, `__dir__` being `String?`) and one over-wide element type. The
  every-member reading added none.
- **Root-class values** — a value typed `Object` reached alba's `File.read(@body)` through a helper
  declared `-> Object`, its `String` guard in another method. The undefined-method rule would fire on
  `@body.to_str` too, but a signature's `Object` is a statement of ignorance, not of class, so the oracle
  answers `maybe`.
- **Nominals whose RBS is incomplete** — a gem without signatures is not RBS-known, so `maybe`. A gem whose
  signatures omit a method it defines is the undefined-method rule's existing exposure
  (`rbs.coverage` gaps): this oracle refutes there only where that rule would already fire on a direct
  call, so it adds firing sites, not a failure mode.

The positions are the ones that compare a value against a declared type today:
`call.argument-type-mismatch` (both channels; the multi-overload channel's name-only
`interface_accepts_arg?` is replaced by the oracle) and `def.return-type-mismatch`. ADR-35's override
rules and overload selection keep the value reading (`Dynamic[Interface]`, which accepts everything), so
no overload pick and no inferred return changes in this slice. RBS has no declared-ivar type a rule checks
today; an `attr_writer` call is an argument check.

**WD4 — Strictness tiers.** The default tier is WD3. Anything stricter is a separate opt-in feature:

- *Signature tier* — for a member both sides declare in authored RBS, `ConformanceChecker`'s
  single-overload return, parameter, arity and keyword comparison (`signature_mismatch`, ~L111), the
  ADR-35 both-sides-authored construction; generic arguments compared through it; argument and arity
  checks on calls whose receiver is an interface value. Never against an inferred signature.
- *Outside-interface tier* — a call on an interface value to a member the interface does not declare,
  under its own rule id, generalising `plugin.api-surface` beyond plugin source.

**WD5 — The reused-RBS role table (#929's first half).** The spec's catalog table becomes a gated table:
each role names the interface that carries it and where that interface is declared.

| Role | Interface | Declared by |
| --- | --- | --- |
| iterable | `_Each[T, R = void]` | rbs core `builtin.rbs` |
| readable stream | `_Reader` | rbs core |
| writable stream | `_Writer` | rbs core |
| rewindable | `_Rewindable` | rbs core |
| string-convertible | `_ToS` | rbs core |
| string-coercible | `_ToStr` | rbs core |
| integer-coercible | `_ToInt` | rbs core |
| path-convertible | `_ToPath` | rbs core |
| IO-convertible | `_ToIO` | rbs core |
| block-convertible | `_ToProc` | rbs core |
| hash-coercible | `_ToHash[K, V]` | rbs core |
| array-convertible / coercible | `_ToA[T]`, `_ToAry[T]` | rbs core |
| rewindable stream | `_RewindableStream` | Rigor (`data/capability_roles/`) |
| closable / closable stream | `_Closable`, `_ClosableStream` | Rigor |
| file-descriptor-backed | `_FileDescriptorBacked` | Rigor |
| callable | `_Callable` | Rigor |
| collection, ordering | `Enumerable[T]`, `Comparable` | rbs core (modules; nominal) |

A role backed by a stdlib interface resolves to the upstream declaration, never to a Rigor copy: the
interface name is looked up in the environment like any other (`RbsLoader#interface_definition`), and
Rigor ships no declaration under that name. A spec gates the table: every row resolves in a default run,
the upstream rows carry exactly the member names the table records (so an rbs upgrade that changes one
is noticed), and `data/capability_roles/` declares none of the upstream names. `Enumerable` and
`Comparable` stay nominal: conformance is the `include`.

**WD6 — Rollout.** Half A ships on by default; half B ships as a `:behaviour` bleeding-edge feature
(ADR-50 WD2), folded into the analysis-cache identity as `bleeding_edge.rb` requires of any feature
that changes `check` output, and reports under the existing rule ids. With the feature off, ADR-64's
multi-overload channel keeps its name-only check. The oracle only weakens that check (a member the project
source defines, an open surface), so moving the channel onto it by default is a separate change that can
only remove firings; it removed none on the survey set.

| Slice | Content | Default | Unblocks |
| --- | --- | --- | --- |
| 1 | WD1 carrier + WD2 dispatch; spec § "Interface values" | on | #2686 (`_Scope` live) |
| 2 | WD5 role table and its gate | on (no diagnostics) | #929's first criterion |
| 3 | Extract the undefined-method absence chain into a shared predicate, no behaviour change | — | slice 4 |
| 4 | WD3 oracle at the argument and return positions | bleeding-edge `interface-assignability` | #929's remaining criteria |
| 5 | WD4 signature tier | bleeding-edge, separate id | — |
| 6 | Overload selection reading interface requirements structurally | measured on its own | — |

Re-evaluation triggers: half B moves to default-on when a corpus sweep over the survey set shows every
added firing adjudicated a true positive (the bar ADR-64 met); it is withdrawn if a release cycle of
bleeding-edge use reports a false positive the oracle cannot exclude without weakening
`call.undefined-method` too. The every-member union reading is revisited when the nominal channel's
nullability reading is (ADR-64 WD3, #673), so the two stay one decision.

## Rejected / deferred alternatives

| Alternative | Status | Reason |
| --- | --- | --- |
| Keep erasing interfaces | Rejected | ADR-1's roles and ADR-128's interfaces stay inert, and #2686 cannot start. |
| A bare `Interface` carrier as the value | Rejected for slice 1 | Every `Dynamic`-keyed leniency would need a matching arm, each missed one a false positive; the prototype's value-side zero delta rests on the wrapper. Revisit if a precision need appears that the facet cannot serve. |
| `call.undefined-method` for a member the interface omits | Rejected | The method exists at runtime; ADR-128 WD6 made the same call for plugin code. |
| Full member signature compatibility by default (the spec's current MUST) | Rejected | Upstream signatures are routinely narrower than the methods they describe; ADR-35 limits signature comparison to both-sides-authored RBS for that reason. Kept as the opt-in tier. |
| The standard union reading for interface requirements | Rejected as default | 20 added on `lib`, all nullability or element-type width; kept for the signature tier to reconsider with #673. |
| A structural check inside `Acceptance` with a global environment | Rejected | `Acceptance` is environment-free by design; a thread-local oracle scoped to the rule keeps that. |
| A declared backing class per plugin interface (ADR-128 WD5) | Not needed | The value is `Dynamic`, so `_Scope` passes `scope: Scope`. |
| Role names as a new annotation vocabulary | Deferred | `conforms-to` takes interface names already; a name layer earns its place with role inference (`hint.role-generalization.*`). |

## Consequences

- **Positive:** interface-typed values carry their members' types: `scope.type_of(node)` reads
  `Rigor::Type::t` in plugin code, `_Each[Integer]#each`'s block parameter reads `Integer`, `_ToStr`'s
  `to_str` reads `String`.
- **Positive:** an interface parameter rejects a value that provably lacks a member, with the false-positive
  envelope of a rule that already runs by default.
- **Measured:** half A added no diagnostic site on any measured tree; half B added 3, all false positives
  from wrong project signatures, and found no true positive on the corpus. The prototype cost +0.37%
  (`a`) and +0.67% (`ab`) allocations on `lib`, +0.08% and +0.18% on Mastodon `app`, inside the 1% band.
- **Negative:** half B has no corpus evidence of value yet: every one of its firings so far is a cause the
  nominal channel already reports when the parameter is a class.
- **Negative:** the default tier is weaker than the spec's prose: no signatures, no generic arguments, no
  union refutation short of every member, intersections checked by their first member.
- **Negative:** two readings of one RBS type, chosen by position, is a new invariant the translator's
  callers must respect; a requirement translation leaking into a value would type values bare.
- **Carry-over:** the spec's § "Assignability rules" is rewritten to the tiers (this PR); role inference
  and named-interface matching (§ "Capability-role inference discipline") remain unbuilt.

## Relationship to other ADRs

- [ADR-1](1-types.md) — capability roles and structural interfaces; this ADR implements their
  assignability and narrows the default strictness.
- [ADR-5](5-robustness-principle.md) — why `maybe` never fires and the value stays gradual.
- [ADR-35](35-override-signature-compatibility.md) — the both-sides-authored rule the signature tier reuses.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — the bleeding-edge overlay half B ships in.
- [ADR-64](64-non-nil-argument-type-mismatch.md) — the name-only interface channel the oracle replaces,
  and the nullability deferral the union reading follows.
- [ADR-128](128-plugin-hook-surface-interfaces.md) — the plugin interfaces this makes live; WD5's seam is
  settled by WD1, WD6's `plugin.api-surface` is WD4's outside-interface tier scoped to plugins.
