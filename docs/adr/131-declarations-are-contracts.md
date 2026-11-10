# ADR-131 — Declarations are contracts: documented intent as an RBS authoring source

Status: **Proposed, 2026-11-11.** Ships `skills/rigor-rbs-contract/` (body, four `references/`, an eval
suite) and amends the `rigor-type-oracle` skill and its `AGENTS.md` fragment so the two agree. Nothing in
the engine changes. Archetype: deliberative. Stakes: mid — guidance only and reversible in one docs PR,
but it decides what agents write into adopting projects' `sig/` and into RBS sent to
`ruby/gem_rbs_collection`.

Grounding: the collection audits
([2026-11-06](../notes/20261106-gem-rbs-collection-audit.md),
[2026-11-10](../notes/20261110-gem-rbs-collection-audit-rerun.md)) and the pull requests they produced:
ruby/gem_rbs_collection#1126 (retryable), #1129 (sidekiq) and #1130 (marcel). Also `50f4750fe`, which
added § "Respect a declared `void`" to `docs/agents/type-authoring.md` for this repository only.

## Context

[ADR-108](108-type-provenance-for-agents.md) gives an agent three sources for a type it writes — `type-of`
/ `annotate`, `sig-gen`, and call-site observation for parameters — and says there is no fourth. That
rule is about *where a type comes from*. It is silent on a different question, which the collection work
kept asking: **what a declaration promises to callers.**

Inference cannot answer that question, because every Ruby method returns its last expression. A body
always *has* a type; whether callers may depend on it is a decision only a declaration records. The
three collection PRs each turned on it:

- **sidekiq (#1129).** `Client#push` was declared `String`. Its doc comment says "If middleware stops
  the job, nil will be returned instead", so `String?` was right. `perform_async` and `Client.enqueue*`
  return the same value from their bodies, but Sidekiq documents no return for them, so their `void`
  and `boolish` stayed. Inference sees one shape in all of these; the contract is different.
- **marcel (#1130).** `Magic.by_magic` was declared `instance`; its body is `mime && new(mime[0])`,
  which returns `nil` when nothing matches, so the declaration was unsound. Rigor did not prove that
  arm: `rigor type-of` on the body reads `Dynamic[top] | Marcel::Magic`, because `magic_match` is
  untyped, and `rigor check` stays silent. The nil was found by reading and is confirmed by running the
  lookup on input that matches nothing. The parameter of the new `by_extension` became `_ToS`, because
  all the gem does with it is call `to_s`.
- **retryable (#1126).** One `options` alias served as both the accepted input (partial hashes) and the
  emitted output (`#to_hash`, all ten keys). Making the keys optional would have fixed the input and
  weakened the output. The fix split the alias into two contracts.

The engine already takes this side. [ADR-107](107-checked-types-and-typeless-comments.md)'s amendment
treats a declared `void` as authored intent, `sig-gen` never proposes over one (#836), and it never
tightens a declared nominal to a literal (#837) because "the choice to be wider than the body only ever
exists in a declaration someone wrote". But the agent-facing rule did not. `rigor-type-oracle` says
"there is no fourth", which reads as forbidding the `String?` from a doc comment, while it says nothing
against "tightening" `void` to whatever the body returns. `50f4750fe` closed that gap for Rigor's own
contributors only.

The second gap is the workflow. A gem author fixing their `sig/`, an application's quality owner
checking the RBS their checks rely on, and a gem_rbs_collection contributor all run the same loop: find
where a declaration and the code disagree, decide which side is wrong, change the declaration, prove the
change, explain it. No skill owns that loop, so each session reconstructs it — or does the easy wrong
thing and copies the inferred type over the declaration.

## Decision

> **Contract criterion.** A declaration states what callers may rely on. Inference proves what a body
> does, so it may *refute* a declaration or fill a slot nobody declared, but it never authors the
> abstraction a declaration chooses. A contract the body does not prove is admissible only on the word
> of the party entitled to make it, cited: the library's own documentation for code the writer does not
> own, the owner's explicit answer for code they do.

> **Direction criterion.** A change that makes a declaration *say less* — a return that admits a value
> it excluded, a parameter that accepts more — needs evidence that the excluded case is real. A change
> that makes it *say more* — a narrower return, a narrower parameter, a `void` replaced by a value —
> needs a contract source. Rigor's proof is evidence for the first kind; for the second it is enough
> only where the slot was undeclared or `untyped`, which is what `sig-gen` already proposes.

This adds a fourth source to ADR-108's three. It is scoped to contracts — what a declaration promises —
not to the type of an expression, which still comes only from Rigor; and it keeps ADR-108's provenance
rule intact: the documented contract is cited exactly as a command is.

### WD1 — The evidence order

| Evidence | Admissible for | Cited as |
| --- | --- | --- |
| The library's documentation — a doc comment on the method, the README, the API reference | any contract on code the writer does not own | a quote and its location |
| The owner's answer, in conversation, for the project's own code | any contract on that code | the question and the answer, and preferably a doc comment written from it |
| Rigor's proof — `rigor check`'s `def.return-type-mismatch`, a `sig-gen` proposal, `type-of` | refuting a declaration; filling an undeclared or `untyped` slot | the command and its output (ADR-108 WD5) |
| Observation — call sites (`sig-gen --params=observed`), a test or a one-off run that exercises a case | that a case is real; a parameter's lower bound (ADR-108 WD3) | the command, or the test |
| Reading the implementation | locating a candidate; a parameter's structural need (`_ToS` for an argument used only by `to_s`) | — never the sole support for a narrower contract |

The last row is the one most worth stating. Reading `perform_async`'s body says it returns `push`'s
result; that is exactly the inference a declaration is entitled to hide. Reading is how a candidate is
found, not how it is decided.

### WD2 — `void`, `boolish` and other wide declarations stand unless the library documents a value

`void` and `boolish` are promises not to promise. A wider declared nominal (`Numeric` over a body that
returns `Integer`) is the same kind of choice. The skill never tightens one to what the body returns;
the test is whether the library documents the value. This is `50f4750fe`'s rule moved from contributor
guidance into the shipped skill, so it reaches gem authors and collection contributors.

### WD3 — Input and output contracts are separate

A type alias, record or interface that both callers pass in and the library hands back carries two
contracts. When they differ — optional keys in, required keys out — the fix is to split it, not to
weaken it until both fit (#1126). Parameters stay lenient under [ADR-5](5-robustness-principle.md); a
returned record stays as precise as its documented guarantee.

### WD4 — Who decides depends on whose code it is: interactive for one's own, autonomous upstream

For a project's own code the owner is the authority, so the skill is interactive: it batches the
contract questions the evidence leaves open and asks them, and suggests writing the answer as a doc
comment — the citation the next contributor, and any downstream RBS, will need. For a gem the writer does
not own, the documentation is the authority, so the skill can run unattended up to a finished branch
and pull request description; opening the pull request is outward-facing and stays the user's call. A
contract the documentation does not state is left as it is and listed under "deliberately left
unchanged". That list is part of the write-up, because a reviewer otherwise cannot tell restraint from
oversight.

### WD5 — A new skill, not a widening of `rigor-type-oracle`

`rigor-type-oracle` is event-shaped: it fires at the moment an agent is about to write a type, inside
any task. Auditing and repairing a set of declarations is task-shaped: a multi-step loop that ends in a
diff and usually a pull request. One description cannot route both without blunting the oracle's
trigger, the same argument ADR-108 WD1 made against folding the oracle into `rigor-ask`. So
`rigor-rbs-contract` is a new skill. The oracle keeps its three sources for a type itself and gains a
separate section on what a declaration promises, which names the contract source and points to the new
skill. Its `AGENTS.md` fragment admits the contract source in its lead paragraph and gains one bullet for
the `void` rule, so both hold in sessions that load neither skill (ADR-108 WD2's routing criterion).

One skill covers the three targets — a gem's own `sig/`, an application's `sig/`, a gem_rbs_collection
entry — because the judgment is identical and three near-identical descriptions would compete for the
same tasks. What differs (who to ask, which gate proves the change, what the write-up looks like) lives
in per-target `references/`.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep ADR-108's "three sources, no fourth" and leave contracts to contributor docs | Rejected | Leaves the shipped skill contradicting the engine (#836, #837) and the collection PRs; agents outside this repository keep tightening `void` and keep refusing a documented `String?`. |
| Treat reading the implementation as a contract source | Rejected | It is the guess ADR-108 exists to stop, and #1129's `perform_async` is the counterexample: the body's value is exactly what the declaration hides. |
| One skill per target (gem author, application, collection) | Rejected | Shared judgment, colliding descriptions. Per-target `references/` instead (WD5). |
| Widen `rigor-type-oracle` to own the loop | Rejected | Trigger mismatch (WD5). |
| Report-only `sig-gen` classification for declarations narrower than the body | Deferred | The skill runs on today's commands, with the gap stated: `rigor check`'s `def.return-type-mismatch` finds a fully typed last expression the declaration excludes, and nothing finds an explicit early `return nil` or a falsy arm behind an untyped value (marcel). Those stay reading leads that need documentation or a run. A command that reports them ([#3062](https://github.com/rigortype/rigor/issues/3062)) and a public form of the collection audit's harness are follow-ups, not preconditions. |

## Consequences

Positive:

- The three ways the collection PRs were right — a documented nil, a preserved `void`, a split alias —
  become rules a session can apply without having seen those PRs.
- Each contract change carries a citation, so a reviewer can re-check it; a `void` left alone carries
  its reason, so restraint is visible.
- Gem authors are steered to write the contract where it can be cited (a doc comment), which is what
  makes the upstream RBS checkable later.

Negative / carry-over:

- "Documented" is a judgment. A README example is weaker evidence than a doc comment that states the
  return; the skill asks for a quote so the judgment is reviewable, but cannot make it mechanical.
- The unsound-declaration case — a body that can return what the declaration excludes — is the most
  valuable one to find and the worst covered. `def.return-type-mismatch` sees only a fully typed last
  expression; an explicit `return nil` earlier, or a falsy arm behind an untyped value, is invisible to
  every current command. Until that changes the skill treats them as reading leads that need
  documentation or a run, which is the direction criterion applied honestly rather than a tool result.
- The eval suite is unrun at landing: its cases need a Rigor-configured project, as ADR-108 WD7's did.
- Another catalogue entry, frozen into the public skill vocabulary at v1.0 with the rest
  ([ADR-50](50-release-engineering-and-stability-strategy.md) WD1).

## Relationship to other ADRs

- **[ADR-5](5-robustness-principle.md)** — lenient parameters, strict returns; WD3 is that asymmetry
  applied to a shared alias.
- **[ADR-14](14-rbs-sig-generation.md)** — `sig-gen`'s authorship policy; the direction criterion is why
  its proposals are evidence only for undeclared or `untyped` slots.
- **[ADR-107](107-checked-types-and-typeless-comments.md)** — its amendment made a declared `void`
  authored intent in Rigor's own tree; WD2 ships that reading outward.
- **[ADR-108](108-type-provenance-for-agents.md)** — amended by this ADR: a fourth, contract-scoped
  source, cited like the other three; its skill and fragment change to match.
