# ADR-111 — Where a refinement is written in a `.rb` file: one carrier, no Rigor-only comment dialect

Status: **Proposed, 2026-09-12; revised the same day with the Steep measurement.** Rules on
[#996](https://github.com/rigortype/rigor/issues/996). Recommends **reaffirming** that Rigor has no
comment dialect of its own: a refinement in a `.rb` file rides the `%a{rigor:v1:…}` annotation the RBS
grammar already defines, beside a plain type position that states its erasure, and never inside one.
Nothing is implemented. The precondition the first draft left open — Steep — is now measured, and it
moved one thing: the own-line `%a{}` form the manual documents is a hard error under Steep's inline
mode, so the **same-line** form is the only spelling this ADR recommends, and
[#998](https://github.com/rigortype/rigor/issues/998) — Rigor's own reader drops that form — is the
prerequisite for recommending it, not a follow-up. Re-evaluation trigger (i) has half-fired; WD5 says
what the other half now means. The maintainer decides.

Grounding:
[`docs/notes/20260912-inline-refinement-carrier-probe.md`](../notes/20260912-inline-refinement-carrier-probe.md)
— fourteen spellings plus controls through the `rbs-inline` gem, rbs 4.2.0's `RBS::InlineParser`, and
Steep 2.0.0 in inline mode, with the probe script and the Steepfile;
[#997](https://github.com/rigortype/rigor/issues/997) for the two failure modes of the naive spelling,
independent of this ruling and in flight as [PR #1005](https://github.com/rigortype/rigor/pull/1005);
#998 for the defect WD5 makes the prerequisite, open with no PR at the time of writing.

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

**The argument, tested.** The probe note measures what each candidate spelling does to the three
inline readers a project can run — the `rbs-inline` gem, which is Rigor's reader
([ADR-32](32-rbs-inline-comment-ingestion.md) WD11), rbs's built-in `RBS::InlineParser`
([ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)), and Steep 2.0.0 with `check "lib", inline:
true`, which as measured *is* the built-in parser surfaced as errors. Five findings carry the decision:

1. **Invisibility is cheap, and `@rbs-ext` does not buy it — `@extrbs` does.** Any comment that does
   not begin with `@rbs` — `# rigor: …`, `# @rigor …` — is ignored by every reader, and the `# @rbs
   return: String` beside it still binds. But rbs-inline detects an annotation with
   `/\A#(\s*)@rbs(\b|!)/`, and `\b` matches before a hyphen: `# @rbs-ext` *is* an `@rbs` annotation
   with an unknown body — swallowed silently by the gem, reported as `AnnotationSyntaxError` by the
   built-in reader, an `[error]` under Steep. The issue's candidate name is measured out, whatever the
   ruling. The maintainer's counter-proposal `# @extrbs …` is measured in: clean in all three readers,
   with the `#:` beside it bound (Steep's control proves the binding). A dialect, if ever chosen, has
   a spelling that works — alternative 2 records it.
2. **The divergence the argument fears is already bounded in the `%a{}` lane, for the same reason it
   is bounded in `.rbs`.** In the documented form the plain contract is *still written* — `# @rbs
   return: String` is the line every other reader binds — and the refinement rides an annotation the
   RBS grammar defines as opaque metadata. Steep seeing `String` where Rigor sees `non-empty-string` is
   not a `.rb`-specific hazard; it is what a Rigor-only fact means in any buffer, and it is exactly the
   `.rbs` situation the argument calls bounded. What would make it *unbounded* is a refinement in the
   type position itself, where nothing plain is left for another reader to see — which is the naive
   spelling, and it breaks every reader measured (the gem truncates `finite-float` to the type
   `finite`; the built-in reader diagnoses and drops the whole signature).
3. **What the argument did not know: no `%a{}` spelling is accepted by both library readers today,
   and Steep sides with the built-in one.** The own-line form the manual documents is gem-only — the
   built-in reader reports it as a syntax error and keeps only the plain type. The forms the built-in
   reader accepts, `# @rbs %a{…} () -> String` and `#: %a{…} () -> String` on one line, are the ones
   the gem breaks: it keeps the annotation and silently throws away the method type, or drops the
   line. `%a{pure}` — rbs core's own annotation, which Steep reads ([ADR-103](103-effect-labels.md)
   WD14) — splits identically. This is a gem-vs-built-in grammar divergence of the kind ADR-32 WD11
   already catalogues, not a property of the `rigor:v1:` payload; but it is a real compatibility cost
   of the inline `%a{}` lane, it is silent on Rigor's side (the reader that matters most says nothing,
   which is #997's class of defect), and manual 16's "any other RBS tool preserves or ignores the
   annotation" is true only of the same-line form — and of that form under every reader but Rigor's.
4. **The oracle never writes a refinement into a type position.** `rigor sig-gen` renders every type
   through `erase_to_rbs` (`lib/rigor/sig_gen/generator.rb`, `method_candidate.rb`): what it emits is
   the erasure, plain RBS. A `%a{rigor:v1:…}` line is authored intent — written by a person, or copied
   from a `.rbs` that already carries it — never something the oracle hands an agent to paste.
5. **Steep does not tolerate the own-line form; it rejects it, loudly.** `docs/design/20260816-effect-labels.md`
   § 6.5 asserted "Steep tolerates unknown annotations" and recommended `# @rbs %a{pure}` in `.rb` on
   that basis; no fixture had been run through Steep by anyone. Measured, Steep 2.0.0 in inline mode
   reports `# @rbs %a{rigor:v1:…}` and `# @rbs %a{pure}` alike as `[error] Syntax error: expected a
   token pARROW` (`RBS::InlineDiagnostic`), and `steep check` fails on it. The assertion is refuted
   for the form it was written about. It holds for the same-line form: `# @rbs %a{…} () -> String`
   and `#: %a{…} () -> String` are clean, and a body-type control (`1` under `-> String` →
   `Ruby::MethodBodyTypeMismatch`) proves Steep bound the plain type and ignored the annotation —
   the boundedness this ADR's criterion assumes, exhibited by the reader the argument named.

**What Steep measured, and what still is not.** Steep's column in the note is the built-in reader's
column token for token, at error severity — so Steep's inline mode is `RBS::InlineParser`'s grammar,
the one ADR-94 names as Rigor's long-run reader, already shipping in the checker Rigor is most often
run beside. The scope is exactly `inline: true`: without it Steep reads no `.rb` annotation at all
(every fixture class is `Ruby::UnknownConstant`), so the population exposed is the one that opted
into Steep's inline mode, which is the population that would write these lines. Not measured: any
other Steep or rbs version — the built-in and Steep columns are version-dependent by construction,
since [ADR-79](79-rbs-version-range-over-pinned-determinism.md) keeps Rigor on the project's own
`rbs` — and the class-level directives inline (WD3).

## Decision (recommended)

> **Boundedness, not invisibility, is the property.** A Rigor-only fact in a `.rb` file is written
> *beside* a plain type position that states its erasure, in a carrier the base grammar already defines
> as opaque metadata — never *inside* the type position, and never in a carrier only Rigor defines. A
> reader that ignores the carrier reads the erasure; a reader that understands it reads the refinement;
> and a carrier the base grammar owns is the only one whose payload survives the inline reader's own
> writer into generated RBS.

Applied: the `%a{}` carrier passes (erasure written, RBS-defined carrier) — in its **same-line**
spelling, `# @rbs %a{rigor:v1:…} () -> T` or `#: %a{rigor:v1:…} () -> T`, which is the one whose
carrier every non-Rigor reader measured actually ignores. The own-line spelling the manual documents
passes on paper and fails as measured: the built-in reader and Steep do not ignore the carrier there,
they reject the line, and Steep rejects it as an error (finding 5). The naive spelling fails the first
clause (nothing plain left). A Rigor-owned tag — `# @extrbs …`, now a measured spelling — passes the
first clause and fails the second: invisible to all three readers, but its meaning dies at the
rbs-inline writer boundary (the text is copied into generated RBS as a comment; the carrier there is
still `%a{}`), it is a second grammar to own and freeze, and it is the "new Ruby comment DSL"
[ADR-0](0-concept.md)'s `RBS::Extended` bullet names as the road not taken.

### WD1 — Reaffirm: no Rigor-only comment dialect

The manual sentence stands, rewritten to carry its reasoning: the `# rigor:` family stays
suppression-only (`disable`, `disable-file`; `check_rules.rb`'s `LINE_SUPPRESSION_PATTERN` /
`FILE_SUPPRESSION_PATTERN`, with `UNKNOWN_SUPPRESSION_MARKER` policing the RuboCop-reflex spellings),
and the only carrier for a `rigor:v1:` directive in either buffer is the `%a{}` annotation. Both
`docs/manual/16-rbs-extended-annotations.md` and `rbs-extended.md` state the ruling and the boundedness
criterion above, and the manual's compatibility claim becomes the measured one, **per spelling**: the
same-line form is clean under rbs's built-in reader and under Steep's inline mode; the own-line form
is an error under both. Until WD5's prerequisite lands, the inline lane is documented as what it is —
read by Rigor only, in a spelling Steep's inline mode rejects — and a project that also runs Steep in
that mode is told to hold refinements in `.rbs`.

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
spelling rbs-inline's own writer copies into generated RBS *as an annotation*, so a project that later
moves to `sig/` keeps the refinement — a dialect's line survives that boundary only as comment text
(finding 1). For the same-line form this holds once #998 lands; today the writer drops its method type.

### WD5 — The Steep measurement, the prerequisite, and the re-evaluation triggers

This ADR's compatibility claim is the measured one, and since the revision it is measured across all
three readers. What the first draft called a precondition is now a result, and it changed the shape of
the recommendation.

- **Steep, measured.** Steep 2.0.0 (`tool/steep/`, rbs 4.0.2) with `check "lib", inline: true` reads
  `.rb` annotations with `RBS::InlineParser`'s grammar — its column in the note is the built-in column
  token for token — and surfaces every `AnnotationSyntaxError` as an `[error]` under
  `RBS::InlineDiagnostic`, failing the check. The own-line `%a{}` form (rows A, Q, and `%a{pure}` at
  P) is red. The same-line forms (A2, F, P2) are clean and bound, proven by the body-type controls.
  Without `inline: true` Steep reads no annotation at all, so the exposed population is exactly the
  projects that opted into Steep's inline mode.
- **What that does to the recommendation.** The same-line form is the only spelling this ADR
  recommends for a `.rb` file. The own-line form is documented as the one Rigor accepts today and
  Steep rejects — never recommended. That inverts the first draft's "both forms, same-line
  preferred", and it means the manual cannot recommend anything until the prerequisite lands.
- **Prerequisite — #998, Rigor's reader silently drops the same-line forms.** `#: %a{…} () -> T` and
  `# @rbs %a{…} () -> T` are rbs syntax the built-in reader and Steep accept; the gem drops the method
  type or the line without a diagnostic, which violates ADR-32 WD12 (a parsed-but-unhonoured
  annotation is never swallowed) and `overview.md`'s "100% compatible with RBS and rbs-inline
  syntax". [#998](https://github.com/rigortype/rigor/issues/998) adds the row to ADR-32 WD11's
  lost-construct list; fix on Rigor's side so that both spellings reach the environment with the
  annotation attached — the plugin's synthesis seam
  (`plugins/rigor-rbs-inline/lib/rigor/plugin/rbs_inline.rb`, where WD6's `default_type` marker and the
  `#:nodoc:` rewrite already sit) is the injection point. It was a follow-up while Steep was
  unmeasured; now the recommended spelling is one Rigor's own reader throws away, so the manual's
  recommendation waits on it. #997 stays independent (in flight as PR #1005) and does not narrow:
  both naive spellings remain invalid under every reader.
- **Re-evaluation triggers.** (i) was "Steep reports the own-line form red *and* the same-line form
  cannot be made to work in Rigor's reader within a release". **The first half has fired.** The
  second half is now the whole trigger: if #998 does not land within a release, revisit toward
  deferred alternative 2, spelled `# @extrbs …` (measured, finding 1), with the ADR-0 amendment it
  requires stated. (ii) Rigor migrates to `RBS::InlineParser` (ADR-94): the own-line form becomes
  invalid in Rigor too, and #998 dissolves by construction — the same-line recommendation is then the
  only one standing. (iii) rbs defines an inline carrier for third-party metadata of its own: adopt
  it.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| 1. `# @rbs-ext …` — the issue's candidate name | Rejected, measured | Not outside the `@rbs` grammar: `@rbs\b` matches before the hyphen in both library readers. The gem swallows it silently; the built-in reader reports `AnnotationSyntaxError`; Steep reports it as an `[error]`. A dialect, if ever chosen, cannot be spelled this way. |
| 2. A Rigor-owned tag outside `@rbs` — `# @extrbs …` (the maintainer's counter-proposal), or `# rigor: …` extending the suppression family, or `# @rigor …` | Deferred — WD5's fallback, now with a measured spelling | `@extrbs` is measured invisible to all three readers, with the `@rbs` / `#:` line beside it bound (rows X, Y, and Steep's control); `# rigor:` is a prefix Rigor already reserves. The costs the name never touched: it is the "new Ruby comment DSL" ADR-0's `RBS::Extended` bullet rules out, so it needs an ADR-0 amendment; a second grammar Rigor must parse, version and freeze at v1.0 beside `%a{rigor:v1:…}`; at the rbs-inline writer boundary the *text* survives — the gem copies the line into generated RBS as a comment — but the *meaning* does not, so in `.rbs` the carrier is still `%a{}` and a `sig/` migration re-spells every directive; and the documentation tool gets two spellings of one directive set. Placement is a footgun of its own: after a `#:` line the gem re-renders the comment block. Invisibility is the property it buys, and finding 2 shows boundedness — which the same-line `%a{}` form has under every reader measured — is the property that matters. If it is ever taken (trigger (i)): refinement payloads only, smallest first, the tag before the annotation block. |
| 3. Pre-parse rewrite of refinement names in `@rbs` / `#:` type positions into the erasure plus a `%a{}` | Rejected | The unbounded case by construction: the file states a contract only Rigor can read and every other reader sees a broken signature (measured: the gem emits `finite`, the built-in reader diagnoses). `overview.md` forbids rewriting inline annotations; ADR-32 WD1/WD3 keep the grammar upstream's. The `#:nodoc:` rewrite is not a precedent — it targets RDoc directives, not annotations. |
| 4. Refinements only in `.rbs`; retire the inline `%a{}` lane | Rejected | #996's own criterion keeps the lane; annotating one method in `.rbs` forces declaring its whole signature (manual 16); the effect-labels design already chose the inline lane for envelopes on this ground. |
| 5. Keep the manual sentence unchanged | Rejected | The issue's criterion: reaffirmed or overturned, the page says why and answers the divergence rather than leaving it unstated. |

## Consequences

Positive:

- No new public surface: the v1.0 freeze covers one grammar, and the documentation tool and every
  ADR-108 agent get a single rule — erasure in the type position, `%a{}` beside it, never a
  refinement inside it.
- The compatibility claim is measured across all three readers, per spelling, instead of asserted —
  and the design note's "Steep tolerates unknown annotations" is corrected on the record before a
  second tool builds on it.
- The probe surfaces a live reader-conformance defect (finding 3) that would otherwise have stayed
  behind the same silence #997 describes, and the Steep measurement shows it is the one thing between
  Rigor and a spelling every reader accepts.
- A dialect, if trigger (i) ever completes, starts from a measured name (`@extrbs`) instead of a dead
  one.

Negative / carry-over:

- A Rigor-only payload is invisible to Steep and every non-Rigor reader in *both* lanes. That is what
  "Rigor-only" means, and this ADR chooses to make it bounded rather than to pretend it away.
- Until #998 lands, the only inline `%a{}` form Rigor reads is one Steep's inline mode rejects as an
  error, and the form Steep accepts is one Rigor drops in silence. A project running both tools holds
  refinements in `.rbs` until then, and the manual says so rather than recommending either form.
- ADR-103's inline `%a{pure}`, which the manual documents own-line, is red under Steep's inline mode
  today for the same reason (finding 5); #998's fix covers it, since same-line `%a{pure} () -> T` is
  clean under every reader but Rigor's.
- #997 does not narrow: both naive spellings stay invalid under every reader, so both diagnostics stay
  wanted.
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
- **[ADR-79](79-rbs-version-range-over-pinned-determinism.md)** — why the built-in reader's and
  Steep's columns are version-dependent.
- **[ADR-93](93-default-rbs-inline-ingestion.md)** — makes the inline comment a live contract, which
  is the stake; its WD6 `%a{rigor:v1:inferred-return}` is Rigor already using this carrier in the
  inline lane for a Rigor-only fact.
- **[ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)** — the long-run reader, and as measured
  the grammar Steep's inline mode already runs; trigger (ii).
- **[ADR-103](103-effect-labels.md)** — WD14's `%a{pure}` pays the same reader split (finding 3), and
  its own-line inline spelling is red under Steep (finding 5); the design note's § 6.5 premise is the
  one this ADR refutes.
- **[ADR-107](107-checked-types-and-typeless-comments.md)** — inline `#:` / `# @rbs` are welcome in
  Rigor's own tree when informative; WD4 says which spelling of a refinement that may be.
- **[ADR-109](109-ruby-native-range-notation.md)** — `Integer[1..10]` is the refinement notation this
  ADR keeps out of RBS type positions (row H of the probe).
