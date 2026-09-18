# Feedback for the ZARD first draft from the `@extrbs` ruling

Status: review memo, 2026-09-19. Written for the ZARD first draft. The binding decisions are
[ADR-112](../adr/112-extrbs-comment-channel.md) and, once each lands,
[`docs/type-specification/rbs-extended.md`](../type-specification/rbs-extended.md). Reviewed against
ZARD at `8e5816b` (`CONTEXT.md`, ADR-0001 to ADR-0003).

## What the ruling fixed on Rigor's side

- Rigor reads `# @extrbs` as a type source. The name is confirmed: `@rbs-ext` is read by rbs-inline as
  an `@rbs` annotation, and Steep reports it as an error (probe row B in
  [`20260912-inline-refinement-carrier-probe.md`](20260912-inline-refinement-carrier-probe.md)).
- **The public contract is what other tools read: `.rbs`, `@rbs`, and `#:`.** A type plain RBS can
  spell, such as `:asc | :desc`, goes in `@rbs` / `#:`. `@extrbs` carries what RBS cannot spell. This
  is guidance, not a gate: an `@extrbs` holding plain RBS is valid, and Rigor stays silent about it.
- `@extrbs` uses the `@rbs` tag forms (`name: T`, `return: T`, `(T) -> U`, `%a{…}`), and a type
  position may use the `rigor:v1:` type grammar. That grammar is being widened to a superset of RBS
  types ([#1074](https://github.com/rigortype/rigor/issues/1074)). No short sigil like `#:` exists for it.
- Rigor writes the generated signature into `sig/`: each type's erasure in the type position, plus
  `%a{rigor:v1:…}` for the refinement declared in `@extrbs`. Rigor never writes into `.rb` files.
- If the same member appears in more than one source and the declarations are consistent, Rigor uses
  the more precise one. If they contradict each other, Rigor reports an error.
- None of this is implemented yet: see [#1073](https://github.com/rigortype/rigor/issues/1073)–[#1076](https://github.com/rigortype/rigor/issues/1076).
  A ZARD first draft should target the spec, not the current `rigor` release.

## Where ZARD's draft and the ruling disagree

1. **ADR-0001 puts every typed contract in `@extrbs`.** Under the ruling, contracts live in two
   places: `@rbs` / `#:` for plain RBS, and `@extrbs` for anything beyond it. Proposed amendment:
   "ZARD reads typed contracts from `@rbs`, `#:` and `@extrbs`. A contract plain RBS can express is
   written in `@rbs` / `#:`; `@extrbs` carries what RBS cannot." The `CONTEXT.md` entry for `@extrbs`
   narrows to match. It should describe a typed channel for contracts beyond plain RBS, whose type
   positions accept the RBS::Extended vocabulary, rather than "a channel for InlineRBS and RBS::Extended".
   If ZARD keeps a single-channel style, Rigor still reads it. The cost is that Steep and Sorbet then
   see nothing inline for those members.
2. **ADR-0003 says the core owns syntax diagnostics, but the payload type grammar is Rigor's.** The
   ruling is that the grammar's normative text lives in Rigor's type specification. Proposed split:
   - The ZARD core owns ZARD-specific syntax: the em-dash marker, tag shapes, and tag boundaries and
     spans. It reports diagnostics for that syntax.
   - The core keeps an `@extrbs` type position as text with its span.
   - Diagnostics for the type itself come from Rigor, through the Rigor lens.
   - A shared, analyzer-free parser gem for the payload is the follow-up if ZARD ever needs to validate
     types without Rigor. That is a decision for then, not now.
3. **Pin a grammar version, not only a release.** Releases are synchronised, but a project's lockfile
   can still pair versions that are out of step. ZARD should declare which `rigor:v1` / `@extrbs`
   grammar revision it reads and writes, so that a mismatch is a reported fact rather than a silent
   difference.

## Things ZARD should do because of the ruling

- **Emit `@extrbs` first in the annotation block, as `# @extrbs` with one space.** rbs-inline continues
  a paragraph when a line is indented further than the tag. A `#  @extrbs` line after
  `# @rbs return: T` is absorbed and silently lost there, and rbs's built-in reader rejects the same
  shape (ADR-112 WD2). A formatter that re-indents comment blocks must keep this layout.
- **`--` inside `@extrbs` is rbs-inline's contract-note syntax.** ADR-0002 already keeps it separate
  from the em-dash documentation marker. The ruling agrees: `@extrbs` reuses rbs-inline's tag parser,
  so `name: T -- note` behaves as it does in `@rbs`.
- **Do not duplicate a contract into `.rbs` by hand.** `sig/` is Rigor's generated output. A
  hand-written copy that drifts becomes a reported contradiction.
- **Steep in inline mode sees only `@rbs` / `#:`.** A member declared only in `@extrbs` is visible to
  Steep through the generated `sig/`. A project that configures sig-gen to skip inline-declared
  members, to avoid Steep reporting duplicates, keeps those members' `@extrbs` refinements inside
  Rigor only ([#1076](https://github.com/rigortype/rigor/issues/1076)).

## Open question left to ZARD

**A type written in a documentation tag is a third place a type appears.** ADR-0002's
`@param value [String] — …` is a documentation claim. ZARD defines it as optional, checkable by Rigor,
and not a replacement for a contract. The ruling does not rank it. Two questions for the draft:

- What happens when a documentation claim contradicts the contract? The consistent answer with
  ADR-112 is that the contract wins and Rigor reports the mismatch.
- Should ZARD discourage a claim when a contract already states that type? A claim that repeats the
  contract is exactly the YARD duplication ZARD exists to avoid. One option is to let `zard-doc lint`
  flag a claim that only repeats the contract.
