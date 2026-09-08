# ADR-110 — An inherited declaration does not outrank the receiver's own `def`

Status: **Accepted, 2026-09-09 — the adjudication only; nothing is implemented.** This ADR answers
[#744](https://github.com/rigortype/rigor/issues/744) half 2, the question
[#745](https://github.com/rigortype/rigor/pull/745) deliberately left open when it fixed half 1. The
engine change it decides is gated on WD5's corpus measurement and is not scheduled here. Archetype:
deliberative. Stakes: high — it moves a precedence the whole dispatcher rests on, its blast radius is
every project whose classes override a signed ancestor method, and it sits directly on the
false-positive envelope.

Grounding: [#744](https://github.com/rigortype/rigor/issues/744) (repro, and the four live redmine
sites), [#745](https://github.com/rigortype/rigor/pull/745) (half 1, measured 82 → 6 on redmine).

## Context

When a call's receiver is a class that defines the method in its own source, but only an **ancestor**
carries an RBS signature for that name, Rigor answers with the ancestor's declaration. This is not a
decision anyone took: it falls out of the dispatcher's tier order, where the RBS-backed tier sits above
every tier that can reach a user `def`, and "the first tier that returns a non-`nil` `Rigor::Type` wins;
subsequent tiers MUST NOT be consulted on a hit"
([`inference-engine.md:174`](../internal-spec/inference-engine.md), § the dispatcher tier order). The RBS
lookup itself does not distinguish own from inherited: `RbsLoader#instance_method`
([`rbs_loader.rb:1683`](../../lib/rigor/environment/rbs_loader.rb)) reads `RBS::DefinitionBuilder`'s
fully resolved method table, so a signature written about a base class is returned for every subclass
that inherits the name.

The failure #744 reports is what that produces when the two disagree.
`Redmine::FieldFormat::Base#target_class` honestly returns `nil`; `RecordList#target_class` overrides it
with a lookup. With `-> nil` declared on the base and nothing on the override, a call on a `RecordList`
receiver types as `nil`, `rigor type-of` reports `nil`, and four `undefined method … for nil` fire on the
subclass's own working code — alongside a `def.return-type-mismatch` telling the user their correct
override is wrong.

Half 1 stopped `sig-gen` manufacturing that particular conflict: `demote_overridden_base_methods`
withholds a base method's signature when a project subclass overrides it and the override is not emitted
([`sig_gen/generator.rb:103`](../../lib/rigor/sig_gen/generator.rb)). That was unambiguous — a signature
this tool writes must not make this tool's checker contradict the source it was generated from. It does
nothing for a hand-written `sig/`, which is where the question actually lives.

**Why this is not obvious.** Under RBS semantics the inherited signature is a contract and the override
violates it, so reporting the mismatch is coherent and the current answer is defensible. Two things
undercut it. First, the precedence was never adjudicated, and the one ADR that models method resolution
says the opposite: "the default merge policy follows Ruby's runtime resolution: the candidate that Ruby
would actually dispatch wins" ([ADR-1](1-types.md) § `MethodEntry`, `1-types.md:314`). Second,
[ADR-5](5-robustness-principle.md) is ambiguous on precisely this case. It carves out "inferred
user-method types when no RBS signature is present" (`5-robustness-principle.md:97`) without saying
whether *present* means present on the receiver's class or present after ancestor resolution. #744 half
2 is that ambiguity, and the type specification does not close it either: what
[`robustness-principle.md:22`](../type-specification/robustness-principle.md) binds is Rigor's own
*authorship* — "It does NOT override RBS authorship that already exists" — not which of two disagreeing
sources wins at a call site.

**The corpus has already answered the same question five times, in the same direction, one case at a
time.** None of them generalized the rule:

| Where | What it does |
| --- | --- |
| [ADR-26](26-activerecord-relation-typing.md) signature half — `unauthoritative_inherited_signature?` ([`check_rules.rb:1207`](../../lib/rigor/analysis/check_rules.rb)) | Declines wrong-arity and argument-type-mismatch on an open receiver "only where the name resolved through an ANCESTOR rather than the open class itself … where the resolution was never authoritative to begin with" |
| Top-level `def` veto — `try_local_def_dispatch` ([`expression_typer.rb:1192`](../../lib/rigor/inference/expression_typer.rb)) | Prefers the source `def`; when its body cannot be re-typed answers `Dynamic[Top]`, because "RBS dispatch would be wrong (the method is user-defined and shadows whatever ancestor method the dispatch would find)" |
| `instance_self_answers?` ([`expression_typer.rb:1222`](../../lib/rigor/inference/expression_typer.rb)) | "The RBS arm is own-class only, deliberately" |
| [ADR-57](57-self-call-return-adoption.md) overridable-method gate (`57:246`) | The mirror image: a base's constant return is not adopted when a discovered subclass redefines the method; degrades to `Dynamic[top]` |
| [ADR-100](100-static-diagnostic-family-and-void-origins.md) void-tail summary | Admits a def only on its **own** resolved signature — exact class, no ancestor walk on the discovery side |

And [`reflection.md:45`](../internal-spec/reflection.md) already states the principle outright for
constants: "**In-source wins on collision** because the user's source is the authoritative declaration."

## Decision

**A signature is authoritative for a receiver only where someone wrote it about that receiver.**
Resolution reaching a signature through an ancestor is a lookup convenience, not an act of authorship.
When the receiver's own class defines the method in source and carries no declaration of its own for it,
the `def` that runs determines the type that flows; the ancestor's declaration does not.

That is the criterion, and it is meant to be reused: it is the sentence the five mechanisms above were
each deriving locally. It is bounded by two clauses that keep it from becoming the much larger claim
that inherited declarations are untrustworthy in general.

**Clause A — the conflict must be visible.** The rule engages only where the receiver's own class has a
source `def` for the name and no declaration of its own for it. With no override, the inherited
declaration *is* about the method that runs, and it binds exactly as today. This is what keeps the
decision out of [ADR-43](43-rbs-complete-ancestor-resolution.md)'s territory, where resolving inherited
return types is the precision win and cannot be separated from the risk: "you cannot get one without the
other" (`43:99`).

**Clause B — withhold, never manufacture.** Disqualifying the inherited declaration may only ever *lose*
precision. It may not substitute a different precise type on the strength of the override alone, and it
may not cause a diagnostic to fire that does not fire today. This is [ADR-58](58-ivar-field-typing.md)'s
side-channel discipline applied to a different mark — "a consumer may only ever *withhold* a firing it
would otherwise make, so the mark can lose precision but can never manufacture a false positive"
([`inference-engine.md:371`](../internal-spec/inference-engine.md)) — and it is what makes the change
checkable: a conforming implementation cannot add a diagnostic to any corpus.

## Working decisions

**WD1 — the answer is the override's inferred return, and `Dynamic[top]` when it has none.** The engine
already re-types a callee body (`ExpressionTyper#try_user_method_inference`), and in #744's repro it
types `RecordList#target_class` correctly. Where the body cannot be typed, the answer is `Dynamic[top]`,
not the ancestor's declaration. This is the shape `try_local_def_dispatch` already ships for top-level
`def`s ([`expression_typer.rb:1192`](../../lib/rigor/inference/expression_typer.rb)); WD1 extends its
reasoning from "the enclosing class shadows a top-level def" to "the receiver's class shadows an
ancestor's declaration".

**WD2 — the disqualification is per `(class, method name, kind)`, decided by ownership, not by
agreement.** The rule does not compare the declared and inferred types and prefer the narrower. It asks
only who the declaration was written about. A rule that engaged on disagreement would need to type the
body before deciding whether to trust the declaration that types the body, and would answer differently
as inference improves.

**WD3 — `def.return-type-mismatch` gains the `defined_on?` gate it is already specified to have.**
[ADR-35](35-override-signature-compatibility.md) states the rule as "method **body** inferred return vs
the method's **own** declared return" (`35:250`), and its sibling rules apply `defined_on?`
([`check_rules.rb:3270`](../../lib/rigor/analysis/check_rules.rb)). `declared_return_type`
([`check_rules.rb:2965`](../../lib/rigor/analysis/check_rules.rb)) does not: it takes whatever
`Reflection.instance_method_definition` resolves, inherited included. The warning on line 7 of #744's
repro is that gap. Gating it brings the implementation into conformance with its own specification and is
justified independently of WD1. The "your signature and your source disagree" signal for the inherited
case belongs to the ADR-35 override-compatibility family, which already requires both sides to be
authored.

**WD4 — nothing is renamed.** *Declaration-sourced* is a bound term
([ADR-58](58-ivar-field-typing.md), `inference-engine.md:367`) for the provenance of a `nil`, and reusing
it here would collide with it. This ADR introduces no term. It names the three near-duplicate predicates
that already express the concept — `defined_on?` ([`check_rules.rb:3270`](../../lib/rigor/analysis/check_rules.rb)),
`rbs_declared_on_class?` ([`expression_typer.rb:1267`](../../lib/rigor/inference/expression_typer.rb)),
`declared_on_class_itself?` ([`sig_gen/generator.rb:1410`](../../lib/rigor/sig_gen/generator.rb)) — and
states that they answer one question; unifying them is not in scope, and `CONTEXT.md` gains nothing.

**WD5 — the change lands only behind a corpus measurement.** [ADR-57](57-self-call-return-adoption.md)'s
mirror-image gate set the bar: the self-check, the plugin self-check and the Mastodon / haml / kramdown
corpora byte-identical, `rgl` losing all 13 warnings (`57:204`). Acceptance criteria, all of which must
hold together:

1. #744's four redmine sites clear against a hand-written `sig/` reproducing the base declaration.
2. **No corpus gains a diagnostic.** Clause B makes this a hard criterion, not a hoped-for outcome.
3. `make check` and `make check-plugins` stay clean.
4. The precision or protection lens is *reported* for the run, not assumed unchanged — Clause A bounds
   the precision loss but does not make it zero, and a silent regression here is the failure mode ADR-43
   warns about.

Failing 2 falsifies the implementation, not the decision. Failing 4 beyond a margin the reviewer accepts
reopens WD1's choice of `Dynamic[top]`.

## Rejected / deferred alternatives

| Option | Status | Reason |
| --- | --- | --- |
| **Keep today's behaviour; the warning is the mitigation** | Rejected | The user gets a warning *and* a false error on working code. A `def.return-type-mismatch` that says the correct override is wrong is not a mitigation for the `call.undefined-method` the same declaration then produces — it is a second wrong answer about the same method. |
| **Join the declared and inferred returns** | Rejected | Produces a type that is wrong for both classes and precise for neither, and contradicts [ADR-5](5-robustness-principle.md) clause 1 in the case that matters most — where the override *is* typeable and Rigor can prove the narrower carrier. |
| **Keep the inherited type; suppress the downstream diagnostics only** | Rejected | The cheapest and most FP-conservative option, and the one this ADR came closest to taking. It fails on a different axis: `rigor type-of` and `dump_type` would keep reporting `nil` for a method that returns a `String`. `AGENTS.md` § "Types and Comments" makes the oracle load-bearing — "To learn a type, ask Rigor" — and [ADR-108](108-type-provenance-for-agents.md) ships that contract to adopting projects. A type oracle that knowingly reports a type the program does not produce is a worse defect than a noisy one, because nothing downstream can detect it. |
| **Distrust inherited declarations generally, override or not** | Rejected | This is [ADR-43](43-rbs-complete-ancestor-resolution.md)'s rejected blanket fix under another name. Clause A exists to prevent it. |
| **The same rule for parameters** | Deferred | `MethodParameterBinder` types an override's parameters from the inherited signature, and [ADR-4](4-type-inference-engine.md) records that as an intended win (`4:186`). The symmetric question is real, but no false positive has been reported for it, and the return side's evidence does not transfer. Revisit when a parameter-side repro exists. |

## Consequences

**Positive.** #744's four redmine sites, and the class of failure they represent: any project whose
`sig/` describes a base honestly and whose subclass overrides the method. The tier order stops
contradicting [ADR-1](1-types.md) § `MethodEntry`. The five mechanisms in § Context gain the stated rule
they were each deriving locally, so the sixth case does not have to rediscover it. WD3 closes a
spec/implementation divergence that exists today regardless of this ADR.

**Negative.** Real precision loss, unavoidable and not mitigated here: a subclass that overrides a signed
ancestor method *conformingly*, with a body inference cannot type, drops from the ancestor's precise
return to `Dynamic[top]`. Those are correct declarations being disqualified for being in the wrong place.
[ADR-43](43-rbs-complete-ancestor-resolution.md) § "the crux" is why this cannot be had cheaply, and WD5
criterion 4 exists to keep the size of it visible rather than to deny it.

**Carry-over.** The three predicates in WD4 stay unmerged. WD5's measurement is unrun, so the size of the
Negative above is unknown at the time of writing — this ADR decides the direction and refuses to state a
number it has not measured.

## Relationship to other ADRs

- **[ADR-1](1-types.md)** — supplies the warrant. Its `MethodEntry` merge policy (`1:314`) already says
  the candidate Ruby would dispatch wins; this ADR brings dispatch into line with it for one case.
- **[ADR-5](5-robustness-principle.md)** — resolves the ambiguity at `5:97`: *present* means present on
  the receiver's own class. ADR-5's "RBS authorship that already exists is respected" is unaffected,
  because a declaration on an ancestor is not authorship about this receiver.
- **[ADR-26](26-activerecord-relation-typing.md)** — the nearest relative. Same argument, same direction,
  scoped to plugin-declared open receivers; this ADR states the rule it was a special case of.
- **[ADR-14](14-rbs-sig-generation.md)** — #744 half 1. ADR-14's contradiction rule protects existing RBS
  from generated tightenings; it has no clause about generated RBS contradicting the *source*, which is
  the gap [#745](https://github.com/rigortype/rigor/pull/745) closed in code.
- **[ADR-35](35-override-signature-compatibility.md)** — WD3 makes `def.return-type-mismatch` conform to
  the description at `35:250`; the inherited-declaration signal moves to ADR-35's own family.
- **[ADR-43](43-rbs-complete-ancestor-resolution.md)** — the cost. Clause A is drawn where it is to stay
  out of ADR-43's crux.
- **[ADR-57](57-self-call-return-adoption.md)** — the mirror image, already accepted and measured; WD5
  adopts its evidence bar.
- **[ADR-58](58-ivar-field-typing.md)** — supplies Clause B's discipline, and the bound term WD4 avoids.
- **[ADR-100](100-static-diagnostic-family-and-void-origins.md)** — precedent for an own-class-only
  admission with no ancestor walk.
- **[ADR-107](107-checked-types-and-typeless-comments.md)**, **[ADR-108](108-type-provenance-for-agents.md)**
  — a different precedence axis (which *file* declares a member, and the agent-facing oracle contract).
  ADR-108 is why the third rejected alternative is rejected.

Two open issues sit in the same family and are not decided here.
[#837](https://github.com/rigortype/rigor/issues/837) is half 1's inverse — sig-gen pinning a literal
return onto a method whose ancestor or siblings declare the wide type — and its own summary names it "the
inverse of the #744 guard"; it is an emission question, where this ADR is a resolution question.
[#839](https://github.com/rigortype/rigor/issues/839) wants a standing check that a `sig/` declaration
describes a method that exists at all. Read together the three are one gradient: a declaration with no
source (#839), a declaration whose source is elsewhere (this ADR), and a declaration narrower than the
contract its siblings share (#837).
