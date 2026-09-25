# ADR-112 — `@extrbs`: a Rigor-read comment channel for what RBS cannot say

Status: **Accepted, 2026-09-19. WD5 implemented for `sig/` against inline `@rbs` / `#:` on 2026-09-26 ([#1075](https://github.com/rigortype/rigor/issues/1075)); the `@extrbs` half of WD5 and WD1–WD4 not yet implemented.** Rules on
[#996](https://github.com/rigortype/rigor/issues/996) the other way from
[ADR-111](111-inline-refinement-carrier.md)'s recommendation. ADR-111 is superseded as a whole, and
its probe is this ADR's grounding. This ADR partially supersedes [ADR-32](32-rbs-inline-comment-ingestion.md)
WD13, replacing "`sig/` wins per member" with WD5's consistency rule. It amends [ADR-0](0-concept.md)'s
`RBS::Extended` bullet. Implementation is tracked by #1073–#1076.

Grounding:
[`docs/notes/20260912-inline-refinement-carrier-probe.md`](../notes/20260912-inline-refinement-carrier-probe.md).
It ran fourteen spellings through the `rbs-inline` gem, rbs's `RBS::InlineParser`, and Steep 2.0.0 in
inline mode. Row X measured `@extrbs`: all three readers ignored it, and the `@rbs` / `#:` line beside
it still bound. Row B measured `@rbs-ext`: rbs-inline read it as an `@rbs` annotation, and Steep
reported it as an error.

## Context

Rigor's premise is unchanged: it does not ask anyone to scatter types through Ruby code ([ADR-0](0-concept.md)).
Some contracts are still best written next to the implementation, because the implementation is the
reason for them. A parameter that accepts only `:asc | :desc`, or a return value that is never empty,
are examples. The two kinds of contract differ:

- **What RBS can spell** (`:asc | :desc`) already has a home: `@rbs` / `#:`. Steep reads those
  inline, and so does Sorbet for `#:`.
- **What RBS cannot spell** (`non-empty-string`, `Integer[1..10]`) had only the inline `%a{rigor:v1:…}`
  lane. That lane costs a second, parallel statement of the type. The own-line form is also an error
  under Steep's inline mode (ADR-111 finding 5).

ZARD, a documentation notation designed alongside Rigor and released in step with it, makes this
concrete. It keeps API documentation (`@param` / `@return` prose, typeless by default) apart from
typed contracts, because once a project writes structured comments, YARD asks for a type in every
slot, and nothing ever checks those types. `@rbs` / `#:` cannot carry that prose, since both
presuppose a type. ZARD needs a typed channel that can carry the Rigor vocabulary.

ADR-111 weighed a Rigor-owned tag and rejected it on three costs. Each cost is answered here rather
than denied:

1. **The rbs-inline writer keeps the text but drops the meaning.** Rigor is the writer. `rigor sig-gen`
   emits the `%a{}` into the generated signature (WD4), so no reader depends on the rbs-inline writer.
2. **A second grammar to freeze at v1.0.** There is no new grammar. The tag forms are `@rbs`'s own.
   The type grammar is the one `%a{rigor:v1:…}` already carries, widened once so that both carriers
   share it (WD2, WD3).
3. **ADR-0's "no new Ruby comment DSL".** The principle behind that bullet is not to scatter types,
   and it stands. The amendment makes `@extrbs` an opt-in channel for contracts RBS cannot state,
   not a second way to write every type.

## Decision

> **The public contract is what other tools read: `.rbs`, `@rbs`, `#:`. A type RBS can spell is
> written there. `@extrbs` carries only what RBS cannot spell, and Rigor carries it to every other
> reader by writing the generated signature. The author is never asked to state the same type twice,
> and a Rigor-only fact never silently disappears.**

Rigor never writes into a `.rb` file. Every carrier below is authored intent; the sig-gen oracle
([ADR-108](108-type-provenance-for-agents.md)) writes only `.rbs`.

## Working decisions

### WD1 — The channel and its guidance

- `# @extrbs …` is read wherever it appears. It needs no `# rbs_inline:` magic comment: that comment
  protects `@rbs`-shaped prose from being misread, and `@extrbs` is a name only Rigor uses. A search
  of `references/` (rbs, steep, sorbet, yard-heavy trees) finds no use of it.
- **Guidance, not a gate:** a type RBS can spell goes in `@rbs` / `#:`. An `@extrbs` that happens to
  hold plain RBS (`@extrbs order: :asc | :desc`) is valid and draws no diagnostic, because a notation
  tool that emits it is not wrong.
- `@rbs-ext` is not a spelling. rbs-inline matches `@rbs\b`, and `\b` matches before the hyphen
  (probe row B).

### WD2 — Tag forms, parsing, and placement

- An `@extrbs` line has the forms `@rbs` has: `name: T`, `return: T`, a method type `(T) -> U`, and a
  `%a{…}` annotation. The difference is that a type position may use the `rigor:v1:` type grammar
  (WD3). No short sigil like `#:` is added.
- **Parsing.** The rbs-inline `AnnotationParser` finds tag boundaries and splits items; ADR-32 WD3
  (upstream reader) stays in force. Rigor's payload parser reads type positions only. That is the one
  place Rigor parses inline grammar itself, and it is scoped to the type language Rigor owns.
  ADR-32 records the exception.
- **Placement is normative.** The `@extrbs` block comes **first** in the annotation block, spelled
  `# @extrbs` with one space. rbs-inline continues a paragraph when a line is indented further than
  the tag (`annotation_parser.rb`), so a `#  @extrbs` line after `# @rbs return: T` is absorbed and
  dropped silently. rbs's built-in reader rejects the same shape. A line absorbed that way is
  reported, not swallowed (ADR-32 WD12).
- **A standalone `@extrbs` is allowed.** When no `@rbs` / `#:` states the member, Rigor derives the
  erasure, and other tools see the member through the generated signature. When one does, the
  `@extrbs` type must be consistent with it (WD5).

### WD3 — One type grammar for `@extrbs` and `%a{rigor:v1:…}`

- The `rigor:v1:` payload grammar becomes a **superset of the RBS type grammar** plus the refinement
  vocabulary. `Array[non-empty-string]`, `non-empty-string?`, unions and records are then spellable in
  both carriers. The change is additive: every payload valid today stays valid with the same meaning.
  It lands before the v1.0 freeze ([ADR-50](50-release-engineering-and-stability-strategy.md) WD1),
  so it stays under `rigor:v1`.
- **Name resolution is fixed:** a refinement name first, then a plugin resolver, then an RBS name.
  This is the order `Builtins::ImportedRefinements::Resolver` already uses, now stated as a contract,
  so a project alias named like a refinement cannot change a payload's meaning.
- **Every type is writable into `.rbs`.** rbs lexes `%a{`, `%a(`, `%a[`, `%a|`, and `%a<`, each up to
  its first matching closer, with no nesting and no escape (`references/rbs/src/lexer.re:55-59`).
  The writer picks a delimiter the payload does not contain. If a payload contains all five closers,
  the payload grammar's `\u{…}` escape spells a closer without the raw character appearing. Only
  generated files carry this, and people do not hand-edit them. Writing the fact as a comment in
  `.rbs` is not a fallback (rejected alternative 6).

### WD4 — The generated signature is `sig/`, and it is an input

- `rigor sig-gen --write` keeps writing `sig/<path>.rbs`
  ([ADR-14](14-rbs-sig-generation.md)). The generated signature is an input like any `sig/` file, and
  it is the contract a gem ships and downstream Rigor reads (`bundle_sig_discovery.rb`). A new
  `sig-gen --check` passes when `--diff` is empty. That is the CI freshness gate.
- For a member declared in `@extrbs`, the writer emits the erasure in the type position and
  `%a{rigor:v1:…}` beside it. A refinement Rigor merely **inferred** is erased, never emitted: once
  written, an annotation is enforced, so a contract is only what someone meant to state. Effect
  annotations keep their existing opt-in flags.
- **By default every member is written**, including members also declared by an inline `@rbs`, so
  `sig/` is a complete shippable contract. A project that runs Steep with `inline: true` and
  `signature "sig"` would then see each such member twice (`DuplicatedMethodDefinition`). A setting
  skips inline-declared members for those projects. Under it, an `@extrbs` refinement on such a member
  takes effect only when the source is analysed, and the manual says so.
- `rbs-extended.md`'s rule to drop Rigor-only annotations applies to plain-RBS export, where the
  erasure is written, not to sig-gen output.

### WD5 — Consistency across sources replaces "`sig/` wins" (ADR-32 WD13)

One rule covers `sig/` against inline and `@rbs` / `#:` against `@extrbs`:

- **Consistent:** for each overload, one side is a subtype of the other, in either direction. `untyped`
  is consistent with everything, which keeps a migrating project's `sig/ -> untyped` beside an inline
  `-> void` quiet (the herb case in ADR-93).
- **Consistent duplicates merge to the more precise side.** Under WD13 `sig/` won and a refinement
  written inline vanished with nothing said. Now `String` in `sig/` and `non-empty-string` in
  `@extrbs` read as `non-empty-string`.
- **Contradiction** (neither side a subtype of the other) is an **error**. A stale generated signature
  shows up here. That is the strict warning this ADR wants: regenerate, or fix the source.
- The false-positive discipline holds the definition, not the severity. Before shipping, the rule runs
  on herb, mastodon, redmine and Rigor itself. A false positive fixes the rule and does not lower the
  severity.
- Unchanged: two `.rbs` files declaring one member still fail the class's definition build, and a
  project `.rbs` against bundled RBS stays a file-level quarantine.

## Rejected alternatives

| Candidate | Reason |
| --- | --- |
| 1. ADR-111 as recommended: no Rigor-read tag, same-line `%a{}` only | The ergonomic cost of #996 stays. A contract must be stated twice (plain type, then the payload in an annotation), and a notation tool needs a typed channel. ADR-111's strongest cost, the writer boundary, disappears once Rigor is the writer (WD4). |
| 2. `# @rbs-ext …` | Measured inside the `@rbs` grammar (probe row B). |
| 3. `@extrbs` as the only typed channel, plain types included | It hides contracts other tools could read. Plain RBS belongs where Steep and Sorbet see it (WD1). |
| 4. A separate generated directory Rigor does not read back (`sig/generated/`) | It breaks mixed-provenance members, where the return is generated and the parameters are authored on one line ([ADR-107](107-checked-types-and-typeless-comments.md)). RBS cannot split one member across two files. It also leaves the shipped artefact unchecked by the gem's own `check`, and it takes rbs-inline's default output directory. |
| 5. Limit `@extrbs` to today's payload grammar | `Array[non-empty-string]` and `non-empty-string?` would become unspellable, or be dropped when written. |
| 6. Carry an unrepresentable payload as a comment in `.rbs` | Other tools show comments as documentation, and RBS rewriters move or drop them. It would reintroduce a comment carrier in `.rbs`, which ADR-0 and `rbs-extended.md` rule out. The escape in WD3 has no exception left for this to cover. |
| 7. Require an `@rbs` line beside every `@extrbs` (ADR-111 WD2) | The author would state each type twice. The erasure is mechanical, so Rigor derives it. |
| 8. Ship WD5 as a warning first | The severity is not what protects correct programs. The narrow definition of contradiction and the corpus sweep are. |

## Consequences

Positive:

- One type grammar in both carriers, no new keyword set, and one frozen surface at v1.0.
- A refinement survives every boundary. The author writes it once, Rigor writes the `.rbs` beside
  it, and a downstream Rigor reads it back.
- WD13's silent drop of an inline refinement ends. A stale generated signature becomes a reported
  contradiction.

Negative and carry-over:

- Rigor owns a tag name (`@extrbs`) at v1.0. The tag set stays rbs-inline's.
- A Steep-inline project that skips inline-declared members (WD4) sees `@extrbs`-only facts only in
  Rigor.
- A contradiction used to be reported at `:info`, and it is now an error. Implementing the
  consistency check is new work: nothing in `lib/` compares a refinement with its plain contract
  today.
- ADR-32 WD13 carries a partial-supersession marker. ADR-0's bullet is amended.

Implementation issues: [#1073](https://github.com/rigortype/rigor/issues/1073) (`@extrbs` reading,
WD1–WD2), [#1074](https://github.com/rigortype/rigor/issues/1074) (the payload grammar and escape,
WD3), [#1076](https://github.com/rigortype/rigor/issues/1076) (sig-gen emission, `--check`, and
the skip setting, WD4), and [#1075](https://github.com/rigortype/rigor/issues/1075) (the consistency
rule, WD5). Each updates the binding spec when it lands.

## Relationship to other ADRs

- **[ADR-0](0-concept.md)**: its `RBS::Extended` bullet is amended (Context, cost 3).
- **[ADR-14](14-rbs-sig-generation.md) / [ADR-108](108-type-provenance-for-agents.md)**: the oracle
  writes `.rbs`, never `.rb`. `@extrbs` is authored intent, like a `%a{}` line.
- **[ADR-32](32-rbs-inline-comment-ingestion.md)**: WD3 is kept (WD2 records the one exception), WD12
  applies to absorbed lines, and WD13 is partially superseded by WD5.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)**: WD1's `RBS::Extended` row covers
  the widened `rigor:v1` grammar and the `@extrbs` tag.
- **[ADR-93](93-default-rbs-inline-ingestion.md)**: inline annotations are live contracts, and the
  herb measurement is WD5's `untyped` case.
- **[ADR-94](94-rbs-inline-reader-and-the-rbs-3x-floor.md)**: if the reader moves to `RBS::InlineParser`,
  WD2's tag-boundary step moves with it.
- **[ADR-111](111-inline-refinement-carrier.md)**: superseded. Its measurements stand.
