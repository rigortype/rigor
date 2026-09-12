# ADR-111 — Where a refinement is written in a `.rb` file: one carrier, no Rigor-only comment dialect

Status: **Proposed, 2026-09-12.** Rules on [#996](https://github.com/rigortype/rigor/issues/996).
Recommends **reaffirming** that Rigor has no comment dialect of its own: a refinement in a `.rb` file
rides the `%a{rigor:v1:…}` annotation the RBS grammar already defines, beside a plain type position that
states its erasure, and never inside one. Nothing is implemented. One precondition is open — Steep's
behaviour on the fixture set has not been measured by anyone — and the measurement that *was* taken
found a defect the issue did not know about: no `%a{}` spelling is accepted by both inline readers
today. WD5 turns that into the follow-up and the re-evaluation trigger. The maintainer decides.

Grounding:
[`docs/notes/20260912-inline-refinement-carrier-probe.md`](../notes/20260912-inline-refinement-carrier-probe.md)
— twelve spellings through the `rbs-inline` gem and rbs 4.2.0's `RBS::InlineParser`, with the probe
script; [#997](https://github.com/rigortype/rigor/issues/997) for the two failure modes of the naive
spelling, which are independent of this ruling.

## Context

Rigor's refinements — `non-empty-string`, `finite-float`, `Integer[1..10]` — are not RBS types. In a
`.rbs` file they attach to a declaration as `%a{rigor:v1:return: non-empty-string}` metadata beside a
plain signature ([rbs-extended.md](../type-specification/rbs-extended.md)), and every other RBS tool
keeps reading the plain signature. The question is what the same refinement looks like in a `.rb` file,
where [ADR-93](93-default-rbs-inline-ingestion.md) makes an inline annotation a live contract rather
than documentation. Three things make it urgent now:

- A YARD-alternative documentation tool is being designed against Rigor. It is exactly the surface that
  would emit these comments, and it will emit whatever spelling this ADR commits to — or, absent a
  commitment, one Rigor has not.
- [ADR-108](108-type-provenance-for-agents.md) binds every agent in an adopting project to write only
  types Rigor produced. Its probe found a guessed `#:` line the most dangerous form of the defect,
  because ADR-93 ingests it. Whatever is decided here decides what those agents may write.
- Whatever is decided is a public spelling, and [ADR-50](50-release-engineering-and-stability-strategy.md)
  WD1 freezes the `RBS::Extended` grammar at v1.0. A second carrier is a second frozen surface.

**The route that exists.** `docs/manual/16-rbs-extended-annotations.md` documents an inline lane and it
works: `# @rbs %a{rigor:v1:return: non-empty-string}` above `# @rbs return: String` types the call site
as `non-empty-string`; `# @rbs %a{rigor:v1:param: f is finite-float}` narrows `f` in the body. The manual
closes with a position this ADR must overturn or reaffirm: *"There is no Rigor-only comment dialect:
`# rigor:` comments remain suppression-only."* The naive spelling — the refinement where the type goes,
`# @rbs g: finite-float` or `#: (finite-float) -> String` — fails twice over (#997): the first takes the
whole class to `Dynamic[top]` behind a remediation message for a different cause, the second is dropped
in silence. Those are evidence about ergonomics, not the decision.

**The argument this ADR has to answer.** `%a{}` works, but it rides the *shared* inline-RBS lane.
`# @rbs` is rbs-inline's grammar, read by every tool in that ecosystem, so a Rigor payload inside it
means one file states different contracts to different readers: Steep sees `(Float) -> String` where
Rigor sees `(finite-float) -> String`. In a `.rbs` file that divergence is bounded because the plain
signature is the artifact and `%a{}` is metadata beside it; in a `.rb` file, the argument goes, the
comment *is* the contract Rigor believes, so the compatibility guarantee the inline lane exists to
provide stops holding — which argues for a lane Rigor owns outright, `# @rbs-ext …` or similar, that
upstream never parses because it is not an `@rbs` tag at all.

**The argument, tested.** The probe note measures what each candidate spelling does to the two inline
readers that exist as libraries — the `rbs-inline` gem, which is Rigor's reader
([ADR-32](32-rbs-inline-comment-ingestion.md) WD11), and rbs's built-in `RBS::InlineParser`
([ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)). Four findings carry the decision:

1. **Invisibility is cheap, and `@rbs-ext` does not buy it.** Any comment that does not begin with
   `@rbs` — `# rigor: …`, `# @rigor …` — is ignored by both readers, and the `# @rbs return: String`
   beside it still binds. But rbs-inline detects an annotation with `/\A#(\s*)@rbs(\b|!)/`, and `\b`
   matches before a hyphen: `# @rbs-ext` *is* an `@rbs` annotation with an unknown body — swallowed
   silently by the gem, reported as `AnnotationSyntaxError` by the built-in reader. The issue's
   candidate name is measured out, whatever the ruling.
2. **The divergence the argument fears is already bounded in the `%a{}` lane, for the same reason it
   is bounded in `.rbs`.** In the documented form the plain contract is *still written* — `# @rbs
   return: String` is the line every other reader binds — and the refinement rides an annotation the
   RBS grammar defines as opaque metadata. Steep seeing `String` where Rigor sees `non-empty-string` is
   not a `.rb`-specific hazard; it is what a Rigor-only fact means in any buffer, and it is exactly the
   `.rbs` situation the argument calls bounded. What would make it *unbounded* is a refinement in the
   type position itself, where nothing plain is left for another reader to see — which is the naive
   spelling, and it breaks every reader measured (the gem truncates `finite-float` to the type
   `finite`; the built-in reader diagnoses and drops the whole signature).
3. **What the argument did not know: no `%a{}` spelling is accepted by both readers today.** The
   own-line form the manual documents is gem-only — the built-in reader reports it as a syntax error
   and keeps only the plain type. The forms the built-in reader accepts, `# @rbs %a{…} () -> String`
   and `#: %a{…} () -> String` on one line, are the ones the gem breaks: it keeps the annotation and
   silently throws away the method type, or drops the line. `%a{pure}` — rbs core's own annotation,
   which Steep reads ([ADR-103](103-effect-labels.md) WD14) — splits identically. This is a gem-vs-
   built-in grammar divergence of the kind ADR-32 WD11 already catalogues, not a property of the
   `rigor:v1:` payload; but it is a real compatibility cost of the inline `%a{}` lane, it is silent on
   Rigor's side (the reader that matters most says nothing, which is #997's class of defect), and
   manual 16's "any other RBS tool preserves or ignores the annotation" is not true of the built-in
   reader as measured.
4. **The oracle never writes a refinement into a type position.** `rigor sig-gen` renders every type
   through `erase_to_rbs` (`lib/rigor/sig_gen/generator.rb`, `method_candidate.rb`): what it emits is
   the erasure, plain RBS. A `%a{rigor:v1:…}` line is authored intent — written by a person, or copied
   from a `.rbs` that already carries it — never something the oracle hands an agent to paste.

**What is not measured.** Steep. `tool/steep/` pins Steep 2.0.0 over rbs 4.0.2; it was not installed
where the probe ran, and neither this thread nor the design note that once asserted "Steep tolerates
unknown annotations" (`docs/design/20260816-effect-labels.md` § 6.5) has run a fixture through it.
Whether Steep reads inline `.rb` annotations through `RBS::InlineParser`, and whether it surfaces that
parser's `AnnotationSyntaxError` as a user-visible error, is the precondition (WD5). The built-in column
of the probe is also version-dependent by construction, since [ADR-79](79-rbs-version-range-over-pinned-determinism.md)
keeps Rigor on the project's own `rbs`.

## Decision (recommended)

> **Boundedness, not invisibility, is the property.** A Rigor-only fact in a `.rb` file is written
> *beside* a plain type position that states its erasure, in a carrier the base grammar already defines
> as opaque metadata — never *inside* the type position, and never in a carrier only Rigor defines. A
> reader that ignores the carrier reads the erasure; a reader that understands it reads the refinement;
> and a carrier the base grammar owns is the only one whose payload survives the inline reader's own
> writer into generated RBS.

Applied: the own-line `%a{}` form passes (erasure written, RBS-defined carrier); the naive spelling
fails the first clause (nothing plain left); a Rigor-owned tag passes the first clause and fails the
second — measured invisible, but its payload dies at the rbs-inline writer boundary, it is a second
grammar to own and freeze, and it is the "new Ruby comment DSL" [ADR-0](0-concept.md)'s
`RBS::Extended` bullet names as the road not taken.

### WD1 — Reaffirm: no Rigor-only comment dialect

The manual sentence stands, rewritten to carry its reasoning: the `# rigor:` family stays
suppression-only (`disable`, `disable-file`; `check_rules.rb`'s `LINE_SUPPRESSION_PATTERN` /
`FILE_SUPPRESSION_PATTERN`, with `UNKNOWN_SUPPRESSION_MARKER` policing the RuboCop-reflex spellings),
and the only carrier for a `rigor:v1:` directive in either buffer is the `%a{}` annotation. Both
`docs/manual/16-rbs-extended-annotations.md` and `rbs-extended.md` state the ruling and the boundedness
criterion above, and the manual's compatibility claim is narrowed to what the probe measured until WD5
lands.

### WD2 — The inline erasure contract

Normative in `rbs-extended.md` (a new "Inline buffers" paragraph) and cross-referenced from
[rbs-erasure.md](../type-specification/rbs-erasure.md):

- In a `.rb` file the type position — the `# @rbs name: T` / `# @rbs return: T` / `#: (…) -> T` line —
  carries **plain RBS**, and for a refined member it carries the refinement's erasure: `String` for
  `non-empty-string`, `Float` for `finite-float`, `Integer` for `Integer[1..10]`
  ([imported-built-in-types.md](../type-specification/imported-built-in-types.md) is the table). That
  line is the contract every other reader sees, and it is what Rigor's own `sig-gen` would write.
- The refinement rides `%a{rigor:v1:…}` and MUST refine the plain type it sits beside. A payload whose
  refinement exceeds the plain contract is already a conflict under `rbs-extended.md` § "Authoring
  rules"; the inline lane adds no rule, it inherits that one.
- A refinement name in a type position is a parse failure of that annotation and is reported as one
  (#997's diagnostics, naming the token and the `%a{}` carrier it belongs in). It is **never rewritten**
  into the carrier on the author's behalf — [overview.md](../type-specification/overview.md) § "Inline annotation handling" forbids
  rewriting inline annotations, and rejected alternative 3 below records why a rewrite is the worst
  option even where it is permitted.

### WD3 — Scope: one directive set, one carrier, two buffers

The question "refinement payloads only, or the whole `rigor:v1:` set?" dissolves under WD1: the
inline lane adds no grammar, so there is nothing to scope. Every directive `rbs-extended.md` defines
reaches Rigor through the same `RBS::Definition::Method#annotations` object whichever buffer it came
from (`lib/rigor/rbs_extended.rb`, `read_predicate_effects`), and the manual already documents effects
and `%a{pure}` inline. The class-level directives (`conforms-to`, the HKT pair) are not measured inline
in the probe and stay documented for `.rbs` until they are. Nothing new is frozen at v1.0.

### WD4 — What the documentation tool and an ADR-108 agent may write

Exactly what the oracle produced, which is the ADR-108 provenance criterion applied to this surface:

- a type position carries the `sig-gen` / `annotate` spelling — an erasure, plain RBS;
- a `%a{rigor:v1:…}` line is written only when it is authored intent the tool is carrying from a
  source that already states it (an existing `.rbs`, a human's instruction), never derived from a
  reading of the body;
- a refinement name never appears in a type position.

The tool gains one guarantee from WD1 it would not get from a dialect: every comment it emits is a
spelling rbs-inline's own writer copies into generated RBS, so a project that later moves to `sig/`
keeps the refinement.

### WD5 — The precondition, the defect, and the re-evaluation triggers

This ADR's compatibility claim is the measured one, and the measurement is one reader short.

- **Precondition — measure Steep.** Run the probe note's fixtures through `make steep-install` /
  `make steep-check` with Steep's inline reading enabled, and record per row what Steep reports;
  append to the note. Until it lands the manual states only what the note measured.
- **Defect — Rigor's reader silently drops the same-line forms.** `#: %a{…} () -> T` and `# @rbs %a{…}
  () -> T` are rbs syntax the built-in reader accepts; the gem drops the method type or the line
  without a diagnostic, which violates ADR-32 WD12 (a parsed-but-unhonoured annotation is never
  swallowed) and `overview.md`'s "100% compatible with RBS and rbs-inline syntax". Route to its own
  issue; add the row to ADR-32 WD11's lost-construct list; fix on Rigor's side so that both spellings
  reach the environment with the annotation attached — the plugin's synthesis seam
  (`plugins/rigor-rbs-inline/lib/rigor/plugin/rbs_inline.rb`, where WD6's `default_type` marker and the
  `#:nodoc:` rewrite already sit) is the injection point. Once fixed, the manual documents **both**
  forms and recommends the same-line one, because it is the one the ecosystem's long-run reader
  accepts.
- **Re-evaluation triggers.** (i) Steep reports the own-line form red *and* the same-line form cannot
  be made to work in Rigor's reader within a release: revisit toward rejected alternative 2, with the
  ADR-0 amendment it requires stated. (ii) Rigor migrates to `RBS::InlineParser` (ADR-94): the own-line
  form becomes the invalid one and the manual flips to same-line. (iii) rbs defines an inline carrier
  for third-party metadata of its own: adopt it.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| 1. `# @rbs-ext …` — the issue's candidate name | Rejected, measured | Not outside the `@rbs` grammar: `@rbs\b` matches before the hyphen in both readers. The gem swallows it silently; the built-in reader reports `AnnotationSyntaxError`. A dialect, if ever chosen, cannot be spelled this way. |
| 2. A Rigor-owned tag outside `@rbs` (`# rigor: …` extending the suppression family, or `# @rigor …`) | Deferred — WD5's fallback | Measured invisible to both readers, and `# rigor:` is a prefix Rigor already reserves. Costs: it is the "new Ruby comment DSL" ADR-0's `RBS::Extended` bullet rules out, so it needs an ADR-0 amendment; a second grammar Rigor must parse, version and freeze at v1.0 beside `%a{rigor:v1:…}`; its payload is lost at the rbs-inline writer boundary, so `sig/` migration drops it; and the documentation tool gets two spellings of one directive set. Invisibility is the property it buys, and finding 2 shows boundedness — which `%a{}` has — is the property that matters. If it is ever taken: refinement payloads only, smallest first. |
| 3. Pre-parse rewrite of refinement names in `@rbs` / `#:` type positions into the erasure plus a `%a{}` | Rejected | The unbounded case by construction: the file states a contract only Rigor can read and every other reader sees a broken signature (measured: the gem emits `finite`, the built-in reader diagnoses). `overview.md` forbids rewriting inline annotations; ADR-32 WD1/WD3 keep the grammar upstream's. The `#:nodoc:` rewrite is not a precedent — it targets RDoc directives, not annotations. |
| 4. Refinements only in `.rbs`; retire the inline `%a{}` lane | Rejected | #996's own criterion keeps the lane; annotating one method in `.rbs` forces declaring its whole signature (manual 16); the effect-labels design already chose the inline lane for envelopes on this ground. |
| 5. Keep the manual sentence unchanged | Rejected | The issue's criterion: reaffirmed or overturned, the page says why and answers the divergence rather than leaving it unstated. |

## Consequences

Positive:

- No new public surface: the v1.0 freeze covers one grammar, and the documentation tool and every
  ADR-108 agent get a single rule — erasure in the type position, `%a{}` beside it, never a
  refinement inside it.
- The compatibility claim becomes a measured one with a named gap, instead of an assertion.
- The probe surfaces a live reader-conformance defect (finding 3) that would otherwise have stayed
  behind the same silence #997 describes.

Negative / carry-over:

- A Rigor-only payload is invisible to Steep and every non-Rigor reader in *both* lanes. That is what
  "Rigor-only" means, and this ADR chooses to make it bounded rather than to pretend it away.
- Until WD5's defect is fixed, the documented own-line form is red under rbs's built-in reader as
  measured, and whether that reaches a Steep user is unknown. A project running both tools should
  hold refinements in `.rbs` until the note's Steep column exists.
- #997 does not narrow: both naive spellings stay invalid, so both diagnostics stay wanted.
- The class-level directives inline are undocumented until measured (WD3).

## Relationship to other ADRs

- **[ADR-0](0-concept.md)** — the binding boundary: no Rigor-specific inline DSL in application code;
  `RBS::Extended` attaches through RBS annotations "rather than through a new Ruby comment DSL". WD1
  keeps that letter; alternative 2 is the one that would amend it.
- **[ADR-5](5-robustness-principle.md)** — the reason the criterion is boundedness: a carrier that
  breaks another reader manufactures failures in that reader, and one that hides a contract from
  Rigor silently manufactures false negatives here.
- **[ADR-14](14-rbs-sig-generation.md) / [ADR-108](108-type-provenance-for-agents.md)** — the oracle
  writes erasures (finding 4); WD4 is the provenance criterion applied to the inline surface.
- **[ADR-32](32-rbs-inline-comment-ingestion.md)** — WD11 (the gem stays the reader; WD5 adds a row to
  its lost-construct list), WD12 (parsed-not-honoured is reported; the same-line drop violates it),
  WD13 (`sig/` wins over inline — unchanged).
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — WD1 freezes `%a{rigor:v1:…}` at
  v1.0; this ADR adds nothing to that row.
- **[ADR-79](79-rbs-version-range-over-pinned-determinism.md)** — why the built-in reader's column is
  version-dependent.
- **[ADR-93](93-default-rbs-inline-ingestion.md)** — makes the inline comment a live contract, which
  is the stake; its WD6 `%a{rigor:v1:inferred-return}` is Rigor already using this carrier in the
  inline lane for a Rigor-only fact.
- **[ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)** — the long-run reader; trigger (ii).
- **[ADR-103](103-effect-labels.md)** — WD14's `%a{pure}` pays the same reader split (finding 3).
- **[ADR-107](107-checked-types-and-typeless-comments.md)** — inline `#:` / `# @rbs` are welcome in
  Rigor's own tree when informative; WD4 says which spelling of a refinement that may be.
- **[ADR-109](109-ruby-native-range-notation.md)** — `Integer[1..10]` is the refinement notation this
  ADR keeps out of RBS type positions (row H of the probe).
