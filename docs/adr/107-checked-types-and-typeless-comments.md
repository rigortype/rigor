# ADR-107 — Checked types and typeless comments in Rigor's own tree

Status: **Accepted, 2026-09-08 — implemented by [#822](https://github.com/rigortype/rigor/pull/822).**
The corpus rewrite (`af1a0b84`) empties the type slot in every YARD tag under `lib/`, `plugins/*/lib`
and `examples/*/lib`; the contract lands in `AGENTS.md` § "Types and Comments" and `CONTEXT.md`
(`f1fdb845`); the gate `spec/docs/type_shaped_comments_spec.rb` lands with the same PR. Two of the
three gates this ADR names are not built yet — [#812](https://github.com/rigortype/rigor/issues/812)
(`make check` must fail on a warning) and
[#825](https://github.com/rigortype/rigor/issues/825) (`sig/` provenance) — and § Gates records what
each one is load-bearing for. Archetype: deliberative. Stakes: mid — reversible in one mechanical
pass, blast radius is this repository's own tree and the agents working in it, and it does not touch
the engine's false-positive envelope.

Grounding: the ingestion experiment on [#779](https://github.com/rigortype/rigor/pull/779)'s rebased
head (`c523b0a3`, § "What the annotations said when Rigor read them"), the five-model authoring probe
of 2026-09-08 (§ "What models write, with and without a rule"), and the rewrite's own diff
(§ "What #822 changed").

## Context

Rigor exists to replace unchecked type claims with checked ones. Its own `lib/` carried **1,121
unchecked type claims** — 720 `@param` and 401 `@return` YARD tags whose bracketed type slot no tool
in this repository has ever read. The tool's own tree was the largest body of unchecked types its
authors touched daily: the cobbler's children going barefoot.

Nobody decided this. YARD's bracket is the default shape of a Ruby doc comment, and every tag was
written by someone — or something — reading the code and typing what they believed. That is exactly
the artefact Rigor was built to eliminate, and the belief was often wrong on the day it was recorded.

### The trigger

[#779](https://github.com/rigortype/rigor/pull/779) proposed converting those tags to rbs-inline, and
then not reading them:

| | |
| --- | --- |
| Rewritten | 720 `@param` + 401 `@return` YARD tags → 775 `# @rbs name: T -- prose` lines |
| Files touched | 234 of 446 under `lib/` |
| Ingestion | `require_magic_comment: true` set in `.rigor.dist.yml`, so `lib/` was **not** parsed |
| Stated justification | "already declared in `sig/`" — true for **17** of the 234 files; `sig/` covers 36 of 446 |

The result would have been type-shaped comments in the product's own syntax that the product was
configured not to read: strictly worse than the YARD tags, because they *look* checked. The PR was
closed. But it produced the one thing the tags had never had — a mechanical translation into a form
Rigor can actually parse — and that made the invariant testable for the first time.

### What the annotations said when Rigor read them

Running the analyzer over #779's rebased head with ingestion forced on:

```sh
rigor check --no-cache --no-ci-detect --format=json --treat-all-as-inline-rbs lib
```

**85 diagnostics, exit 1** (0 with the ingestion gate left on, which is the whole point):

| Rule | n | What it was |
| --- | --- | --- |
| `def.return-type-mismatch` | 34 | 17 declared `Rigor::Type?`, 2 `Rigor::Type`, 1 `Array[Rigor::Type]?`. `Rigor::Type` is an empty, documentation-only namespace module that no type class includes (`lib/rigor/type.rb`); the alias is `Rigor::Type::t`. YARD's informal `[Rigor::Type, nil]` transcribed literally is simply wrong RBS — and had been for months. |
| `call.undefined-method` | 32 | `new` on partially annotated classes: an annotated `initialize` sibling makes the class declared, an unannotated one does not. All 15 defining files carry `# @rbs`. |
| `call.wrong-arity` | 12 | Same cause, other half. |
| `rbs.coverage.definition-build-failed` | 1 | `RBS::NoTypeFoundError` on `Registry`, taking **44 classes** with it: an annotation-free class produces no declaration, so a cross-file reference to it fails to build. |
| `call.possible-nil-receiver` | 3 | Includes a genuine finding: `# @rbs registry: Rigor::Effects::Registry?` followed by an unguarded `registry.suggest`. |
| `call.argument-type-mismatch` | 1 | |
| remainder | 2 | |

Two readings, and both matter. The 34 return mismatches are the direct measurement of drift: **12% of
the 281 return annotations contradicted the implementation the first time anything checked them.** The
other 46 are the *shape* of a half-annotated tree — a partially declared class is worse than an
undeclared one, which is [#823](https://github.com/rigortype/rigor/issues/823) below.

The mechanical rewrite also lost information in the other direction: YARD duck types (`[#call]`,
`[#each]`) have no rbs-inline spelling, so they became `untyped --` prose. The one thing the old tags
said that a type cannot is what the translation discarded.

### What models write, with and without a rule

The tags are not a historical artefact; they are what gets written next. Probe of 2026-09-08, five
models, **one sample each** — a probe, not a measurement. Fixtures are kept as the `rigor-type-oracle`
skill's eval fixtures.

**Round 1 — an exemplar is present** (a file already in typeless YARD, five tasks): 5/5 imitated the
typeless form with zero brackets; 5/5 complied with the stated rule; 5/5 answered "unstated" when
asked what type `@param format …` states, and extracted the prose constraint instead; 5/5 propagated a
parameter rename `format` → `fmt` into the tag; 5/5 imitated an RDoc-style file without inventing
`call-seq` or type words. With an exemplar in the buffer, the form is free.

**Round 2 — an undocumented class, no exemplar.** This is the case that decides the rule's placement:

| Model | Rule in `AGENTS.md` | No rule |
| --- | --- | --- |
| Claude Haiku | typeless YARD | typed YARD — `currency [String]`, guessed |
| Claude Sonnet | typeless YARD | rbs-inline `#:` — `(Regexp?) -> Array[[Numeric, String?, Time]]`, `at: Time`, guessed |
| Claude Opus | typeless YARD; `@raise` lost its exception class | prose only, in RDoc markup |
| DeepSeek V4 Pro | typeless YARD | typed YARD — `currency [Object]`, guessed |
| Qwen3.7 Max | typeless YARD; wrote `@raise [ArgumentError]` | typed YARD — `pattern [Regexp, String, nil]`, guessed |

Four of five write an unchecked type unprompted; with the rule in the contract, **5/5 wrote zero
bracketed `@param` / `@return`**, and both deviations were on `@raise`, whose payload is an exception
class rather than a value type. The Sonnet cell is the sharpest: under the product default
([ADR-93](93-default-rbs-inline-ingestion.md)) those `#:` lines would have been ingested as live
contracts — a guessed type promoted to a checked one, which passes or fails on luck.

Residue the rule does not reach: one or two prose type words per file ("a numeric value", "an array of
entries"). Not gate-able, and § Consequences carries it as a known cost.

### Three sweeps, no stable state

| When | Pass | Why it did not hold |
| --- | --- | --- |
| 2026-06 | Removed stale slice-era forward references (`Slice N will …`) | No gate; the shape regrew |
| 2026-07 | [#40](https://github.com/rigortype/rigor/pull/40) / [#41](https://github.com/rigortype/rigor/pull/41) — 120-column comment reflow | Formatting only; said nothing about content |
| 2026-09 | [#779](https://github.com/rigortype/rigor/pull/779) — YARD → rbs-inline, then gated off | Changed the syntax of the unchecked claim, not its status |

Three hand passes over the same corpus in four months. That is the argument for a gate rather than a
fourth pass — [ADR-97](97-adr-index-budgets.md)'s criterion 2 arriving on a different surface: an
economy rule with no mechanical gate is a temporary state, not a decision.

## Decision

> **In Rigor's own tree a type statement exists in exactly one of three states: inferred by Rigor
> (nothing is written down), declared and checked by Rigor, or absent. There is no fourth state,
> "written for documentation."** A type generated without being checked against reality is the
> artefact Rigor exists to eliminate; carrying 1,121 of them in the implementation is not a
> documentation style, it is the product's thesis contradicted in its own source.

The criterion generalizes past comments: *if a claim about types is not produced or verified by the
analyzer, it does not get written down where a reader will trust it.* Applied to a `.rb` comment it
forbids the type slot; applied to `sig/` it forbids an unexplained hand-written signature; applied to
an agent it means "ask Rigor, do not read the neighbours."

### Roles: where a type may live

| Source | What it holds | What keeps it true |
| --- | --- | --- |
| **Implementation** | the truth | — |
| **Inference** | the first type source. Nothing is written down; the type is computed on demand | the precision gate `rigor coverage --threshold 0.58 lib`, which only ever moves up |
| **`sig/`** | contracts: the public API boundary of [ADR-2](2-extension-api.md), plus authored intent | `make check`, `spec/rigor/public_api_drift_spec.rb`, `make steep-check` |
| **Comments** | prose only — never a type | `spec/docs/type_shaped_comments_spec.rb` |

`sig/` has an internal provenance rule that follows from
[ADR-5](5-robustness-principle.md)'s asymmetry:

- **Return types are generated** — `rigor sig-gen` emits the strictest carrier the body proves
  (ADR-5 clause 1), and the generator never emits a tightening the analyzer itself would reject.
- **Parameter types are authored intent** — inference does not derive them, and ADR-5 clause 2 keeps
  them deliberately lenient. A hand-written parameter type is the author saying what the method is
  *for*, which is information the implementation does not contain.
- **Anything else hand-written is a recorded inference gap**, not a preference. Per
  [ADR-14](14-rbs-sig-generation.md) the gap is the more valuable signal: the response is to extend
  the engine, not to backfill by hand because it is quick.
  [#825](https://github.com/rigortype/rigor/issues/825) specifies the gate that makes the third
  category recorded rather than assumed; it is queued, not built.

### Comments carry prose

A comment states what the next lines and the signature do not:

- **Why** — an ADR, an issue, a false-positive bound, an alternative that was tried and declined.
- **A constraint the type system cannot express** — an ordering, an invariant between two arguments,
  a bound that holds only after a guard.
- **What `nil` means here** — absence, "not computed yet", and "explicitly empty" are three different
  things, and the type says only which one is spellable.

It never restates a name, a type, or a signature. Doc comments use YARD's tag grammar with the type
slot left empty — the grammar makes it optional, so these stay valid tags and keep the
parameter-name binding a gate can check — and an em dash after the name token, so the boundary
between the name and the prose is visible without knowing the parameter list:

```ruby
# Resolves the receiver's declared shape.
#
# @param node — the call whose receiver is resolved
# @param scope — the enclosing scope; its narrowing facts bind the receiver
# @return nil when the receiver's class carries no declaration at all —
#   distinct from a declaration that resolves to an empty shape
# @raise Rigor::Error — when the environment has no definition builder
def resolve_receiver(node, scope)
```

**Why the em dash (WD).** In YARD's default grammar `[Type]` is also the delimiter between name and
description, and PHPDoc's `$name` sigil plays the same role; with the slot emptied, `@param format
the output format` hides the boundary. Eight candidate forms were run through YARD's own parser
(0.9.x) to see which keep the name binding — the property the R3 gate and YARD's unknown-parameter
warning both rest on:

| Form | YARD reads | Name binding |
| --- | --- | --- |
| `@param format desc` | text `desc` | kept, no visible boundary |
| `@param format — desc` | text `— desc` | kept — **chosen** |
| `@param format -- desc` | text `-- desc` | kept, but it is rbs-inline's `-- prose` separator, one token from `# @rbs format: T -- desc` |
| `@param format [] desc` | text `[] desc` (not an empty type slot) | kept, reads as an empty array and invites filling |
| `@param [] format desc` | name `[]` | broken |
| `` @param `format` desc `` | name `` `format` `` | broken |
| `@param format: desc` | name `format:` | broken, and rbs-inline's own spelling |
| RDoc `format:: desc` | a definition list, no tag | no `@param` to bind |

The em dash is already this corpus's prose separator, cannot be mistaken for a type or a keyword
argument, and is what YARD's HTML renderer inserts between name and description anyway — the one
cost is that rubydoc.info shows it twice (`format — — desc`). `@return` carries no name and takes no
delimiter. Gate R5 requires the dash after every `@param` / `@yieldparam` / `@option` name and every
`@raise` class.

`{Foo#bar}` cross-references and `@see` stay — they are navigation, not type claims. `@!attribute [r]`
keeps its bracket: `[r]` is an access mode, not a type.

### Inline `#:` and `# @rbs` do not appear in this tree

Not under `lib/`, `plugins/*/lib`, or `examples/*/lib`, for two independent reasons:

1. **The product default would ingest them as live contracts.** ADR-93 wires the bundled plugin on
   whenever `rbs-inline` resolves, and the spec's § "Inline annotation handling" makes an annotation
   a real contract wherever it appears. So an inline type here is either checked — in which case it
   is `sig/` with worse ergonomics and the precedence hazard of
   [#824](https://github.com/rigortype/rigor/issues/824) — or gated off, which is #779's fourth state
   wearing the product's own syntax.
2. **This tree is the demonstration of [ADR-0](0-concept.md)'s "no annotations required."** A
   codebase whose author reaches for annotations to type it is evidence about the inference engine,
   and the honest response is to fix the engine.

This is a rule about *this* repository. [ADR-32](32-rbs-inline-comment-ingestion.md) /
[ADR-93](93-default-rbs-inline-ingestion.md) /
[ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md) are untouched: in an adopting project, `#:` and
`# @rbs` are type *sources*, and Rigor honours them.

### Reading a type is a generated view

The type is one command away rather than in the buffer:

| Command | What it answers |
| --- | --- |
| `rigor annotate FILE` | every line's inferred type, appended as `#=> T` (the xmpfilter convention) |
| `rigor type-of FILE:LINE:COL` | the type at one position |
| `rigor sig-gen --print` | the RBS the implementation proves |

None of these can lie, because none is stored: each is regenerated from the implementation on every
invocation. That is the whole trade — a comment is free to read and can be years stale; a generated
view costs a command and cannot be.

## Gates

| Gate | What it holds | State |
| --- | --- | --- |
| **G1** `spec/docs/type_shaped_comments_spec.rb` | no `[Type]` after a doc tag; no `#:` / `# @rbs` under the three lib roots; every `@param` names a real parameter of the `def` below; no stale `Slice N will` forward references | lands with #822 |
| **G2** [#812](https://github.com/rigortype/rigor/issues/812) — `make check` fails on a warning | `def.return-type-mismatch` is a **warning**, so `make check` exits 0 with a contradicted return type in the tree. Without G2 the declared-and-checked half of the invariant is theatre | `--fail-on=warning` in a sibling PR |
| **G3** [#825](https://github.com/rigortype/rigor/issues/825) — `sig/` provenance | every hand-written entry is generated, authored parameter intent, or a recorded gap | queued |

Already in force, and already serving the invariant: the precision gate
(`rigor coverage --threshold 0.58 lib`) keeps inference the primary source rather than a fallback;
`spec/rigor/public_api_drift_spec.rb` keeps `sig/` and the public surface from separating;
`make steep-check` reads `sig/` with a second checker.

G1 is the load-bearing half of this ADR, for the reason the three sweeps give: the rule survives the
session that read it only if something enforces it afterwards. Its detector is the bracket — a
lexical shape a spec can find, which is why the decision keeps YARD's tag grammar rather than moving
to a prose convention with no failure mode.

## Engine work the invariant surfaced

Per ADR-14, a gap that pushes an author toward hand-writing is information about the engine. The
experiment produced two, both filed:

- **[#823](https://github.com/rigortype/rigor/issues/823) — partial annotation degrades its
  siblings.** In a class where one method is annotated, the unannotated siblings become `untyped`
  shadows on `master` (or missing methods under #779's variant) — the `call.undefined-method` +
  `call.wrong-arity` pair, 44 of the 85 diagnostics above. The state a sibling should land in is
  "declared as present, typed by inference": the annotation should add a contract for the method it
  names without demoting the ones it does not.
- **[#824](https://github.com/rigortype/rigor/issues/824) — precedence between `sig/` and an inline
  annotation for the same method.** Today the collision degrades the whole class to `Dynamic[top]`.
  #779's variant silently stripped the inline declaration instead, which violates
  [ADR-32](32-rbs-inline-comment-ingestion.md) WD12's rule that where two dialects disagree, silence
  is the failure to avoid.

Both are preconditions for the "checked rbs-inline in our own tree" alternative below, which is why it
is deferred rather than rejected outright.

## Rejected alternatives

| Candidate | Reason it lost |
| --- | --- |
| **RDoc conventions** (`== Parameters:` with `name::` lists) | Stdlib-native and well-trained, but converting ~32k lines of Markdown-flavoured comments is a markup migration, not a comment pass; there is no parameter-name binding to gate; and `:call-seq:` is itself a type slot in prose. The probe shows models imitate RDoc happily *with an exemplar* — but with none, their prior reaches for typed YARD or `#:` anyway (Round 2). Decisively: RDoc has no machine-detectable failure mode. The bracket is the detector. |
| **Checked rbs-inline in this tree** (keep `# @rbs`, turn the ingestion gate off) | Consistent with the product spec, and the honest version of what #779 wanted. Non-viable today: #823 makes a partially annotated class worse than an unannotated one, and #824 has no precedence rule against the existing `sig/`. It also reverses ADR-0's thesis in the one tree that demonstrates it, and Rigor's own answer to the parameter half is caller observation (ADR-14 `--observe`), not annotation. Users' projects are a different question, and ADR-93 stands there. |
| **Typed YARD made checked**, via a YARD→RBS synthesizer plugin | Aligns with the model prior, so it would be cheap to comply with. But a *guessed* type that happens to pass the check narrows the contract silently — the Sonnet `Regexp?` case would have shipped as a real parameter contract nobody chose. It also needs #823 first, and it re-imports the "informal type language" problem the 34 `Rigor::Type?` mismatches are made of. |
| **Prose-only, Ruby-core style** (no tags at all) | Canonical and the most heavily trained form of all. But there is no `@param`-name binding to gate, and core-style prose states types in sentences ("Returns a new Array") — so the silent residue § Consequences already accepts would be considerably larger, with nothing to measure it. |
| **Keep the ingestion gate** (`require_magic_comment: true` in `.rigor.dist.yml`, i.e. ship #779) | The worst available combination: annotations in the product's own syntax, in the product's own tree, that the product is configured not to read. They look checked. Every one of the 85 diagnostics was invisible while the gate was on. |

## Consequences

Positive:

- One rule with one detector, stated once in the contract every session loads, and enforced after
  that session ends. The probe says the rule transfers: 4 of 5 models write an unchecked type
  unprompted, 0 of 5 do with the rule present.
- 1,121 unchecked claims in `lib/` are gone rather than restyled, and the 34 that actively
  contradicted the implementation cannot silently return.
- 44 duck-typed tags became prose in a judgment pass, and say more than `[#call]` did — the
  information the rbs-inline translation would have thrown away.
- "What type is this?" has one address (`rigor annotate` / `type-of` / `sig-gen --print`) rather than
  three sources that can disagree.

Negative:

- **Residue the gate cannot see.** One or two prose type words per file survive ("a numeric value",
  "an array of entries"). A bracket is a shape; a sentence is not. The rule is stated to cover them
  and the gate is not.
- **Reading a type costs a command.** For a human skimming an unfamiliar file that is a real
  regression against a well-maintained typed comment — and the whole bet is that "well-maintained" is
  what 1,121 tags and a 12% contradiction rate say does not happen.
- **The invariant is not fully gated on the day it is accepted.** G2 is unbuilt, so a contradicted
  return type in `sig/` still exits 0; G3 is unbuilt, so `sig/` provenance rests on convention. § Gates
  names both rather than letting the Status line imply otherwise.
- **This tree deliberately diverges from what Rigor tells adopting projects to do.** ADR-93 says an
  inline annotation is a contract; here it is forbidden. The divergence is bounded by #823/#824 and
  recorded so it is not read as an inconsistency to "fix" in either direction.
- **YARD's rendered parameter types are gone** for anyone generating YARD docs from this tree. No
  consumer does today.

Carry-over: #812 (G2), #825 (G3), #823 and #824 (the engine gaps). #822 carries **no changelog
fragment** ([ADR-105](105-pr-landing-flow.md)): the diff touches Prism comment lines only, the
non-comment byte stream of every file is unchanged, and nothing user-facing changed.

## What #822 changed

The numbers, since the corpus will move and this is the record of what it was:

| | |
| --- | --- |
| Diff | 313 files, +859 / −1342; only comment lines changed, every file's non-comment byte stream identical |
| Type slot emptied | 814 `@param`, 457 `@return` |
| Tags dropped entirely | 261 `@param`, 161 `@return` — a bare tag with no description restates the signature |
| `@raise [X]` → `@raise X` | 6 (an exception class, not a value type) |
| Duck types restored as prose | 44, in a judgment pass |
| `lib/` before the pass | 32,652 comment lines of 102,056 total |

## Relationship to other ADRs

- **[ADR-0](0-concept.md)** — "Application Ruby code stays free of Rigor-only annotation syntax."
  This ADR applies the same standard to Rigor's own code and to a neighbouring syntax ADR-0 permits:
  the tree that demonstrates inference-first typing should be typed by inference.
- **[ADR-5](5-robustness-principle.md)** — supplies `sig/`'s provenance rule. Returns are generated
  because clause 1 makes them the analyzer's job; parameters are authored because clause 2 makes them
  the author's.
- **[ADR-14](14-rbs-sig-generation.md)** — the parent policy. § "The authorship policy, and why"
  already says prefer `sig-gen`, and the gap is the more valuable signal; this ADR extends the same
  rule from `.rbs` to `.rb` comments and adds the gate. Its contradiction rule is what the 34 return
  mismatches would have been adjudicated under, had they been in `sig/` instead of in comments.
- **[ADR-32](32-rbs-inline-comment-ingestion.md) / [ADR-93](93-default-rbs-inline-ingestion.md) /
  [ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)** — the product's inline-ingestion contract,
  untouched. The exclusion here is scoped to this repository, and #824 is the precedence question
  ADR-32 WD12's silence rule already predicted.
- **[ADR-57](57-self-call-return-adoption.md)** — the adjudication protocol the 85 diagnostics were
  read under: classify every firing, fix the artifacts at their root, and let the residual decide.
  #823 and #824 are that residual.
- **[ADR-97](97-adr-index-budgets.md)** — the same criterion on a different surface: an unenforced
  documentation rule is not observably true, and the gate is part of the decision rather than a
  follow-up to it. Three hand sweeps in four months is this ADR's `db8d01bf`.
- **[ADR-73](73-skill-driven-user-experience.md) / [ADR-81](81-skill-set-optimization.md) and
  [ADR-108](108-type-provenance-for-agents.md)** — the shipped-skill surface. ADR-108 carries the
  product-level generalization: the same "ask the tool, do not read the neighbours" rule, expressed
  as the `rigor-type-oracle` skill and the contract an adopting project inherits with it.
- **[ADR-105](105-pr-landing-flow.md)** — why #822 carries no `changelog.d/` fragment (§ Consequences).
