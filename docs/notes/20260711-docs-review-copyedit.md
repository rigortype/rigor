# Docs review — L4 copyedit + convention-compliance lens (2026-07-11)

Final layer of the `rigor-docs-review` battery. Surface-level only:
English quality, the `interface` naming rule, cross-reference /
terminology hygiene, link-text quality. Content decisions (fidelity,
reader-level, bloat) are out of lane and were handled by earlier
layers. Branch reviewed: `docs/consistency-audit-0.2.9`.

Overall the corpus is clean and well-edited — no hedging, no
AI-flavoured phrasing, no "in order to" wordiness, no "click here"
link text, no bare-URL links (the two literal `https://…` strings are
intentionally copy-pasteable — the install prompt and the canonical
`llms.txt` index). The `interface` naming rule is followed throughout.
The findings below are minor and concentrated in one file.

## English quality

| Location | Issue (category) | Severity | Proposed fix |
| --- | --- | --- | --- |
| `docs/manual/02-cli-reference.md:416` — "the methods its `narrowing_facts`s narrow" | Awkward double-plural: `narrowing_facts` already ends in a plural noun, so appending `s` reads badly (unlike the sibling `` `node_rule`s `` / `` `dynamic_return`s ``). (English) | FRICTION | Reword to avoid the trailing `s`: "the methods its `narrowing_facts` hooks narrow" (or "the methods narrowed by its `narrowing_facts` hooks"). |
| `docs/manual/02-cli-reference.md:581, 598, 608` — "regenerate`").  JSON", "WD7).  The real", "queued.  Exits" | Double space after a sentence-ending period (three instances, all in the `rigor doctor` / `rigor upgrade` sections). The rest of the corpus is single-spaced. (English) | nitpick | Collapse each to a single space. |

## Interface naming rule

No violations. First use is qualified in every chapter that uses the
term for Rigor's construct:
- `07-rbs-and-extended.md:144` — "named structural interface" ✓
- `appendix-protocols-and-structural-typing.md:11` — "the RBS `interface`" ✓ (and the chapter is the canonical explainer)
- `appendix-go.md` / `appendix-rust.md` / `appendix-java-csharp.md` — the first bare "interface" is the *other* language's own construct (Go's / Rust's `trait` / Java's nominal `interface`), obvious context per exception (b); Rigor's is qualified ("structural interface" / "RBS `interface`") wherever it appears ✓
- `appendix-steep.md:70`, `appendix-type-theory.md:20` — bare `interface` appears only in code font as the RBS keyword / an RBS `_Comparable` name, obvious context ✓

The `handbook/README.md:235` wording-convention block and the
protocols appendix both state the rule explicitly. Compliance is
good.

## Cross-reference / terminology hygiene

| Location | Issue (category) | Severity | Proposed fix |
| --- | --- | --- | --- |
| `docs/manual/02-cli-reference.md:571` — "inert `disable:` / `severity_overrides:` tokens ({ConfigAudit})." | The parenthetical `{ConfigAudit}` is a leaked internal class/check identifier (or an unrendered template token). It appears nowhere else in the corpus, is not a documented convention, and adds nothing for the reader — the sentence already reads "Configuration audit". Reads as broken markup. (cross-reference) | FRICTION | Delete ` ({ConfigAudit})`. |
| Corpus-wide (10 × "analyser"/"analyse" noun/verb spellings vs 41 × "analyzer" + 5 × "analyze") | Mixed British/American spelling of the same word. The noun is American-dominant (`analyzer` 41 vs `analyser` 10) but the verb is British-dominant (`analyse` 24 vs `analyze` 5), and many individual files carry both forms (e.g. `handbook/01-getting-started.md`, `manual/02-cli-reference.md`, `manual/15-…`). Not a defect in any single sentence, but an inconsistency a reader notices. (terminology consistency) | FRICTION | Pick one convention and normalise. Lowest-churn: standardise the noun to the already-dominant `analyzer`, fixing the 10 `analyser` occurrences; ideally also settle the verb (`analyse` currently dominant). House choice — flagging, not prescribing. |

Terminology is otherwise consistent: "carrier" is used uniformly for
value-lattice objects (no drift to "type object", which is reserved
for the internal-spec API); `Dynamic[top]` is defined once in
`02-everyday-types.md` as the gradual carrier and "untyped" is
consistently scoped to its RBS-erased view. The ADR-80
`type_specifier`→`narrowing_facts` rename is fully applied — the only
remaining `type_specifier` mentions (`handbook/09-plugins.md:77-78`)
are the deliberate deprecation note. "Chapter N" references spot-check
to correct targets. The thematically-grouped (non-numeric-order)
contents list in `manual/README.md` is intentional, and each entry
points to the right file.

## Link text quality

No findings. Link text is descriptive throughout; the manual↔handbook
cross-links name their targets accurately. The literal
`raw.githubusercontent.com/.../docs/install.md` URLs and
`<https://rigor.typedduck.fail/llms.txt>` are meant to be read/copied
verbatim, so a bare URL is correct there.

## Possible fidelity issues (out of my lane)

None spotted at the surface level.

## Verdict

The docs are in strong shape after the earlier layers: prose is terse
and free of AI tells, terminology is consistent, the `interface`
convention holds, and cross-references and link text are sound. The
only real friction is clustered in `manual/02-cli-reference.md` — a
leaked `{ConfigAudit}` token, an awkward `` `narrowing_facts`s ``
plural, and three double-spaced sentences, all in the recently-added
`doctor` / `upgrade` / `--capabilities` copy. The one corpus-wide item
is the British/American `analyser`/`analyzer` spelling split, worth a
normalising pass but not urgent. All findings are FRICTION or below;
none block shipping.
