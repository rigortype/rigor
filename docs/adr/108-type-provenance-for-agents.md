# ADR-108 — Type provenance for agents: the `rigor-type-oracle` skill and the adopting project's contract

Status: **Proposed, 2026-09-08 — implementation in [#826](https://github.com/rigortype/rigor/pull/826), a Draft; flips to Accepted when it lands.**
Ships `skills/rigor-type-oracle/` (body + three `references/` + a four-case eval suite), the contract
paragraph `rigor-project-init` installs into an adopting project's `AGENTS.md` / `CLAUDE.md` (Phase 8a,
`references/06-agent-contract.md`),
and the catalogue wiring (`CATALOG_ORDER` in
[`lib/rigor/cli/skill_describe.rb`](../../lib/rigor/cli/skill_describe.rb), `skills/README.md`, and the
manual's "Start here", which goes from two skills to remember to three). ADR-107 is the repo-side twin:
the same rule turned inward on Rigor's own tree, where it additionally forbids type-shaped comments.
Nothing in the engine changes.

Grounding: the five-model probe of 2026-09-08 recorded in § "Evidence" below, run over what is now
`skills/rigor-type-oracle/evals/fixtures/budget_ledger.rb`;
the oracle's own answers on that fixture, verified against the installed CLI and recorded in
`references/01-oracle-commands.md`.

## Context

Rigor has had the oracle for a long time. `rigor type-of FILE:LINE:COL` prints the inferred type at a
position, `rigor annotate FILE` types every line of a file in one call, `rigor sig-gen --print` prints a
method's signature, `rigor trace` replays how a type was built, `rigor explain` documents a rule that
fired — and with the MCP server ([ADR-33](33-mcp-server.md)) the same five are tool calls
(`rigor_type_of`, `rigor_annotate`, `rigor_sig_gen`, `rigor_check`, `rigor_explain`).

What was missing is not a command. It is the routing at one specific moment: **an agent about to write
or assert a type.** That moment is almost never the subject of the task. It is the third step of
"document this class", "fix this bug", "add RBS for this file", "review this PR" — so it is not
question-shaped, which is why [ADR-74](74-offline-doc-access-and-llms-txt.md)'s `rigor-ask` does not
reach it. `rigor-ask` fires when the user asks something; an agent about to write `@param currency
[String]` is not asking anything. It is confident.

[ADR-0](0-concept.md)'s context paragraph already names the stake — heavy inline annotation "introduces
noise for both human developers and AI coding assistants (LLMs)" — and the whole no-inline-DSL
commitment follows from it. That premise was about what an agent must *read*. The probe below measures
the other half: what an agent *writes* when nothing routes it. A guessed type in a checked position is
worse than no type, because it can pass — and under [ADR-93](93-default-rbs-inline-ingestion.md)
rbs-inline ingestion is on by default, so a guessed `#:` line is not a comment at all. It is a live
contract the engine will believe.

The maintainer's framing, and the reason this is an ADR rather than a skill commit: *guiding AI agents
to obtain deterministic types from Rigor instead of inferring them by reading the codebase may be the
essential feature Rigor has to offer.* Every checker can tell an agent afterwards that what it wrote is
wrong. A tool with a deterministic oracle can tell it what is right, before it writes.

## Evidence — the five-model probe, 2026-09-08

Five models, one sample each: Claude Haiku / Sonnet / Opus as subagents; DeepSeek V4 Pro and Qwen3.7 Max
via OpenCode. The fixture is the class now shipped at `evals/fixtures/budget_ledger.rb` — deliberately
undocumented and deliberately un-inferrable in places.

**Round 1 — with an exemplar.** A file already documented in typeless YARD, five tasks:

| Task | Result (n=5) |
| --- | --- |
| Imitate the typeless YARD form | 5/5, zero bracketed tags |
| Comply with a stated rule | 5/5 |
| "What type does `@param format …` state?" | 5/5 answered "unstated", and extracted the prose constraint correctly |
| Propagate a parameter rename into `@param` | 5/5 |
| Imitate an RDoc-style sibling file | 5/5, no `call-seq`, no type words |

Imitation is not the failure mode. Given a form to copy or a rule to follow, every model followed it.

**Round 2 — no exemplar.** An undocumented class, two arms:

| Arm | Result (n=5) |
| --- | --- |
| Contract paragraph present in `AGENTS.md` | **0/5 wrote a bracketed `@param` / `@return`.** Two deviations, both on `@raise`: Opus dropped the exception class, Qwen wrote `@raise [ArgumentError]` — which the source does prove (`raise ArgumentError`), so it is a form deviation rather than a guess |
| No rule at all | **4/5 wrote guessed types.** Haiku, DeepSeek, Qwen: typed YARD (`currency [String]`, `currency [Object]`, `pattern [Regexp, String, nil]`, `at [Time]`). Sonnet: rbs-inline `#:` signatures (`(Regexp?) -> Array[[Numeric, String?, Time]]`). Opus: prose only |

The Sonnet result is the sharp one. Under ADR-93 those `#:` lines would be ingested as live contracts,
silently narrowing an API that also accepts a `String` pattern — a guess that becomes a false positive
generator, in the file the next reader trusts.

**What Rigor actually answers on the same fixture**, which is what the guesses displace:

| Site | Rigor's answer | The guess it displaces |
| --- | --- | --- |
| `record` return | `Demo::BudgetLedger` | — (the guess happened to be right) |
| `entries_matching` return | `Array[untyped] \| []` | `Array[[Numeric, String?, Time]]` |
| `balance`, `overdrawn?` | skipped, `sig.skipped.untyped-return` — `@opening_balance` is `Dynamic[top]`, so the arithmetic proves nothing | `Numeric` |
| `currency`, `amount`, `at`, `pattern` | `untyped`, by design ([ADR-5](5-robustness-principle.md)) | `String`, `Integer`, `Time`, `Regexp` |
| `entries_matching` param, `--params=observed --observe spec` | `(Regexp)` — derived from call sites, adoptable | — |
| `initialize`, same | `("JPY", ?opening_balance: 100)` — literal types; widen before adopting | — |

**Two limits worth stating.** First, none of the five invoked Rigor in either arm — they were not told
it existed. So the probe measures the *suppression* half (do not write a guess) and not the *sourcing*
half (ask the oracle); that is exactly the condition the skill and the contract paragraph change, and
it is why the eval suite must run inside a Rigor-configured project (WD7). Second, a residue survives
the rule: one or two prose type words per file — "a numeric value", "an array of entries". Not
mechanically gate-able, and accepted as description rather than annotation.

## Decision

Two reusable rules carry this.

> **Provenance criterion.** A type's provenance is part of the type. Written down, a type asserts that
> something checked it — so *a type you did not obtain from Rigor is a guess, and a guessed type is
> never written anywhere.* Its corollary: where Rigor has no answer, **the gap is the finding, not a
> blank to fill.**

> **Routing criterion.** A habit is installed where the habit is exercised. Guessing happens inside
> tasks that are about something else, so the rule cannot depend on a skill matching the task — it has
> to be in context before the task is known.

The second criterion is why **a skill alone is insufficient**, and the decision is three layers:

1. **The skill `rigor-type-oracle`** — action-shaped, triggered on the act of writing or asserting a
   type. Three allowed sources, a gap protocol, provenance in every answer, and a bounded path for when
   the user insists anyway.
2. **The contract paragraph** —
   `references/02-agents-md-fragment.md`,
   installed by `rigor-project-init` into the adopting project's `AGENTS.md` / `CLAUDE.md`. **This is
   the load-bearing layer** (WD2).
3. **The gate** — `rigor check` going red on a contradiction is the backstop under both. In Rigor's own
   tree ADR-107 adds a fourth: type-shaped comments are forbidden outright there.

Rigor's own repository is the first adopter. The cobbler's children go barefoot otherwise — a project
shipping this rule while its own `AGENTS.md` tolerates hand-written types would be arguing against
itself. That half is ADR-107.

### WD1 — Action-shaped, not question-shaped: why a new skill and not `rigor-ask`

A skill's only routing mechanism is its `description:` matching the task at hand. `rigor-ask`'s trigger
is a *question about Rigor* ("why did this fire?", "how does narrowing work?"); this skill's trigger is
an *act* ("about to write RBS / a `#:` / a Sorbet `sig` / a YARD tag / a type in a review comment").
Those are different enough that one description cannot carry both without blunting the one it has —
`rigor-ask` at 169 words is already the single entry [ADR-81](81-skill-set-optimization.md) WD4 flagged
as a candidate for tightening, and widening it further trades trigger recall for coverage of a case it
would still miss (nobody asks a question at the moment of guessing).

So: two skills, cross-linked both ways. `rigor-ask`'s hand-off list gains an "about to *write* a type"
row; `rigor-type-oracle`'s "When NOT to use" routes setup to `rigor-next-steps`, diagnostics to
`rigor-baseline-reduce`, and the coverage loop to `rigor-protection-uplift`.

### WD2 — Three layers, and why the contract paragraph is the load-bearing one

The probe isolates this. **No skill was loaded in either round-2 arm.** The only difference between
4/5 guessing and 0/5 guessing was one paragraph in `AGENTS.md`.

That is the structural point, not a measurement artefact: the contract file is in context
unconditionally, *before the task is known* — the same property [ADR-97](97-adr-index-budgets.md) WD1
uses to justify `AGENTS.md` carrying a premise set rather than an index. A skill is conditional by
construction. For a rule whose whole job is to fire at a moment internal to some other task, the
unconditional surface is the one that works, and the skill is what a session reaches for once it knows
it needs the procedure.

Installation is Phase 8a of `rigor-project-init`: append the section to `AGENTS.md`; use `CLAUDE.md` if
only that exists; create `AGENTS.md` if neither does; merge into an existing types section rather than
adding a competing one; and if the project already states a contradicting rule about type authorship,
**stop and show the user the conflict** — the project's own rule wins until they say otherwise. The
section is reported in the Phase 9 file inventory and recommended for commit, because its value is that
every contributor's agent reads the same rule.

### WD3 — The parameter exception: observation is evidence, reading is not

Inference reads a method *body*, and a body does not state what its callers are allowed to pass. ADR-5
keeps parameters lenient by design, so Rigor spells them `untyped` — not a gap, a decision. This is the
one place where the oracle's silence is permanent and a hand decision is legitimate.

Even there, the legitimate input is evidence rather than intuition:
`rigor sig-gen --observe PATH --params=observed` derives parameters from call sites (the recogniser
already understands RSpec shapes, so a normal spec suite is an observation corpus). The output is
*narrow* evidence — it emits literal types such as `("JPY")`, the union of what today's callers happen
to pass, frozen as a contract — so it is **reviewed and widened** before adoption, and kept only while
`rigor check` gains no new diagnostic.

The reusable form: a hand-written type is legitimate exactly where the oracle's silence is by design
rather than by gap, and even there the input is observation, never a reading of the source.

### WD4 — Gaps are findings, routed, never filled

`Dynamic[top]`, `untyped`, and a `sig.skipped.*` classification are **answers**: "Rigor cannot prove a
type here." Filling that with your own reading converts a known unknown into a confident falsehood. The
protocol is report (exact command, exact output) → locate (`rigor annotate` up the `#=>` column,
`rigor trace --format=json --line=N`) → route: a dependency without RBS to `rigor-rbs-setup`, an
unconfigured framework to `rigor-plugin-tune`, the project's own monkey-patches to
`rigor-monkeypatch-resolve`, a project DSL to `rigor-plugin-author`, a suspicious setup to
`rigor-doctor` — and anything left to a Rigor issue with a five-part report.

This is [ADR-14](14-rbs-sig-generation.md)'s "the gap is the more valuable signal" generalized: from
`.rbs` files in this repository to every surface a type can be written on in any project. The
never-suppress half is [ADR-57](57-self-call-return-adoption.md)'s adjudication stance — classify the
firing, fix it at its root, do not route around it.

**Carry-over.** `rigor explain` documents diagnostic *rules* only; `rigor explain
sig.skipped.untyped-return` answers `Unknown rule`. So the skip-reason table lives in
`references/03-gap-protocol.md`, a
second home for ids the CLI should own. Small follow-up: extend `rigor explain` to the `sig.skipped.*`
ids, or document them in the manual.

### WD5 — Provenance travels with the answer

Every type stated to a human carries the command that produced it — one line: *`entries_matching`
returns `Array[untyped] | []` (`rigor sig-gen --print lib/demo/budget_ledger.rb`)*. Not ceremony: it is
the difference between an assertion the reader must trust and a claim they can re-run in three seconds,
and it is what makes a **wrong** answer findable instead of permanent. It is also the only part of the
rule that survives the output leaving the repository — a review comment or a chat answer has no `rigor
check` behind it, and the citation is all the reader gets.

The same property makes the eval's S3 signal mechanical: every type string in the diff or the answer
must appear verbatim in some recorded command's output.

### WD6 — Catalogue entry, and one of three skills to remember

Under [ADR-73](73-skill-driven-user-experience.md)'s criteria, a skill that cannot expose a cheap
presence-only signal is a **catalogue entry, never a headline recommendation**. This one is
event-triggered in the same sense as `rigor-doctor`: the event is an agent being about to write a type,
and `rigor skill describe` cannot stat that. `CATALOG_ORDER` therefore places it at the end, right
before `rigor-ask` — the two journey-agnostic companions an agent offers at any point.

Being un-routable by `describe` and being worth remembering are independent, and this skill is the case
that separates them. The manual's "Start here" and `skills/README.md` go from two skills to remember to
**three**: `rigor-next-steps` (*what next?*), `rigor-ask` (*answer this about Rigor*), and
`rigor-type-oracle` (*before you write a type, ask Rigor*) — the third being the one to remember while
**writing** rather than while planning.

Per ADR-73 WD1 / ADR-81 WD1 the body is stable scaffold and the version-coupled detail (exact flags,
output spellings, skip-reason ids) lives in `references/`, served live by `rigor skill --full
rigor-type-oracle`; the body opens with the re-fetch directive.

### WD7 — Eval stance: four mechanically-scored cases, and the `waza` budget stays rejected

`evals/evals.json` carries four cases over the
fixture — document an undocumented class, answer a return-type question, add RBS for a file, and a
negative case where the user asserts a type. Three mechanical signals score them:

- **S1** — an oracle call (`type-of` / `annotate` / `sig-gen`, or the MCP equivalents) occurs *before*
  the first tool call that writes a type.
- **S2** — no `@param [` / `@return [` / `#:` / `# @rbs` in the final diff that a Rigor command did not
  produce.
- **S3** — every type string in the diff or the answer appears verbatim in a recorded command's output.

The negative case is deliberate: the user asserting "`pattern` is a `Regexp`" is allowed, and *refusing
them outright is also a failure*. Passing behaviour is to say once what Rigor reports (ideally offering
`--params=observed`, which turns the claim into a derivation), write what was asked, run `rigor check`,
and then **say which lines the check covers** — green over `untyped` surroundings proves that the
annotation contradicts nothing Rigor can see, not that the contract holds.

Per ADR-81 WD3, `waza`'s budget advisories remain the rejected class: this skill is 2,857 tokens
against `rigor-ask`'s 3,103, both far past the 500-token publication default, and both deliberately
comprehensive.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Extend `rigor-ask` instead of adding a skill | Rejected | Trigger mismatch (WD1): `rigor-ask` fires on a question, and the guessing moment produces none. Widening its description to cover the act blunts the trigger it has (ADR-81 WD4) while still missing the case. Cross-links instead. |
| A hook that blocks type-shaped edits (Claude Code `PreToolUse`) | Rejected as the mechanism | Tool-specific and brittle across agents: it must pattern-match a diff for `@param [`, `#:`, `sig do`, and it fires identically on the *derived* types the skill exists to encourage. The contract paragraph and the `rigor check` gate are agent-agnostic. Worth a template in the manual beside the CI / editor recipes; not a decision here. |
| Ship the rule only in the manual (`rigor docs`) | Rejected | Read on demand, not in context. The failure mode is precisely an agent that never suspects it should look — and the probe's guessing arm did not lack information, it lacked a prompt. |
| Make the oracle emit YARD / RBS into the file on the agent's behalf | Rejected | That command already exists (`rigor sig-gen --write`) and is what the skill routes to. The missing piece was the agent's habit at the moment before it writes, not another writer. |
| A headline `rigor skill describe` recommendation | Rejected | No cheap presence-only signal exists for "an agent is about to write a type" (WD6); ADR-73's guardrail keeps `describe` side-effect-free. Catalogue entry plus manual promotion instead. |

## Consequences

Positive:

- The oracle Rigor already shipped becomes reachable at the moment it matters. ADR-0's AI-native claim
  extends from "your code needs no annotations for an agent to read" to "your agent's annotations come
  from the checker".
- The rule survives a skill failing to load (the paragraph is unconditional) and survives a wrong type
  being written anyway (`rigor check` is the backstop). Three layers, each covering the previous one's
  failure mode.
- A class of silent falsehoods becomes routed findings: every gap is either a project-configuration fix
  with an owning skill or an engine issue with a reproduction — which is the same conversion ADR-14
  makes inside this repository, now available to every adopting project.

Negative / carry-over:

- The probe is n=1 per model per condition, five models, one fixture. The effect it shows is large
  (4/5 → 0/5) but it covers suppression only; the sourcing half is unmeasured, and its eval needs a
  Rigor-configured project to run.
- Prose type words survive the rule and are not gate-able (§ Evidence). Accepted as description.
- `rigor explain` does not cover `sig.skipped.*`, so those ids are documented in a skill's
  `references/` rather than by the CLI (WD4 follow-up).
- Onboarding now writes into a file Rigor does not own. Append-only, never overwriting, stopping on a
  contradicting project rule — but it is the first time `rigor-project-init` touches the project's
  agent contract, and a user who declines keeps the skill layer alone.
- The skill id `rigor-type-oracle` joins the public vocabulary frozen at v1.0 under
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1, with the rest of the catalogue.

## Relationship to other ADRs

- **[ADR-0](0-concept.md)** — its context paragraph names annotation noise "for both human developers
  and AI coding assistants (LLMs)". That is the read-side of the thesis; this ADR records the
  write-side, which the probe shows is the larger hazard because a written guess is believed.
- **[ADR-5](5-robustness-principle.md)** — strict on returns, lenient on parameters. WD3's exception is
  that asymmetry seen from the authoring end: the one site where the oracle is permanently silent.
- **[ADR-14](14-rbs-sig-generation.md)** — § "The authorship policy, and why". This ADR generalizes it
  twice over: from this repository to every adopting project, and from `.rbs` files to every surface a
  type can be written on.
- **[ADR-33](33-mcp-server.md)** — the MCP tools are the same oracle; the skill prefers them when the
  server is connected and reads their results identically.
- **[ADR-57](57-self-call-return-adoption.md)** — the adjudication stance WD4 reuses: classify each
  firing, fix at the root, never suppress.
- **[ADR-73](73-skill-driven-user-experience.md) / [ADR-81](81-skill-set-optimization.md)** — the
  mechanism. Catalogue-vs-headline criteria (WD6), the thin-shell / live-core split and the `rigor
  skill --full` directive, and the `waza` evaluation stance (WD7).
- **[ADR-74](74-offline-doc-access-and-llms-txt.md)** — `rigor docs` and `rigor-ask`, the
  question-shaped sibling. WD1 is the trigger boundary between the two skills.
- **[ADR-93](93-default-rbs-inline-ingestion.md)** — why a guessed `#:` is the most dangerous form of
  the defect: ingestion is on by default, so the probe's Sonnet output would have entered the engine as
  a live contract rather than as a comment.
- **[ADR-107](107-checked-types-and-typeless-comments.md)** — the repo-side twin, landing in
  [#822](https://github.com/rigortype/rigor/pull/822): the same rule turned inward on Rigor's own tree,
  where it additionally forbids type-shaped comments. This ADR is what Rigor ships outward; that one is
  what Rigor does to itself.
- **[ADR-105](105-pr-landing-flow.md)** — the landing mechanics; this change's entry is the fragment
  `changelog.d/added/type-oracle-skill.md`.
