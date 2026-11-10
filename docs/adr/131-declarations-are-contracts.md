# ADR-131 — Declarations are contracts: documented intent as an RBS authoring source

Status: **Accepted, 2026-11-11 — implemented by [#3061](https://github.com/rigortype/rigor/pull/3061).** Ships `skills/rigor-rbs-contract/` (body, four `references/`, an eval
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
> it excluded, a parameter that accepts more — needs a *witness* that the excluded case is real: a call
> RBS's runtime type checker rejects under the old declaration, or the library's documentation. A
> change that makes it *say more* — a narrower return, a narrower parameter, a `void` replaced by a value
> — needs a contract source. Rigor's findings locate the first kind and name the exit to aim at, but are
> not a witness on their own; for the second they are enough only where the slot was undeclared or
> `untyped`, which is what `sig-gen` already proposes.

This adds a fourth source to ADR-108's three. It is scoped to contracts — what a declaration promises —
not to the type of an expression, which still comes only from Rigor; and it keeps ADR-108's provenance
rule intact: the documented contract is cited exactly as a command is.

### WD1 — The evidence order

| Evidence | Admissible for | Cited as |
| --- | --- | --- |
| The library's documentation for the version under review — a doc comment on the method, the README shipped in that gem | any contract on code the writer does not own | a quote and its `file:line` in that version's source |
| The owner's answer, in conversation, for the project's own code | any contract on that code | the question and the answer, and preferably a doc comment written from it |
| A runtime witness — a call `rbs/test/setup` or `RBS::UnitTest#assert_send_type` rejects under the old declaration and accepts under the new | saying less; showing a wholly wrong declaration is never returned | the call and the error (WD6) |
| Rigor's findings — `rigor check`'s `def.return-type-mismatch`, a `sig-gen` proposal, `type-of` | locating a candidate and its exit; filling an undeclared or `untyped` slot | the command and its output (ADR-108 WD5) |
| Observation — call sites (`sig-gen --params=observed`, `rigor check` on use-site code) | a parameter's lower bound (ADR-108 WD3); a correct call a declared parameter rejects | the command, or the test |
| Reading the implementation | locating a candidate; the structural need of an undeclared or `untyped` parameter (`_ToS` for an argument used only by `to_s`) | — never the sole support for a change to a declared slot |

The last row is the one most worth stating. Reading `perform_async`'s body says it returns `push`'s
result; that is exactly the inference a declaration is entitled to hide. Reading is how a candidate is
found, not how it is decided. A *declared* parameter is no exception: [ADR-5](5-robustness-principle.md)
says a supplied signature binds in both directions, so widening one from today's body promises callers
what the next release need not keep.

Documentation is pinned to the version. A website, wiki or default-branch README describes some other
release; it may support a question in the write-up, never a change on its own.

A declaration that shares nothing with the body — sidekiq 7.0's `Config#total_concurrency`, declared
`ConnectionPool[RedisClientAdapter]` over `capsules.each_value.sum(&:concurrency)` — is neither less nor
more. It is treated as undeclared: typed from the documentation or `sig-gen`, with a witness that the
old type never comes back.

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
unchanged", and so is every Rigor finding no witness confirmed. That list is part of the write-up,
because a reviewer otherwise cannot tell restraint from oversight.

Upstream, the existing collection declaration was written by a contributor, not by the gem's author, so
it earns no deference by authorship. What protects it is the direction criterion's asymmetry: replacing
it with something narrower needs the gem's documentation, and replacing it with something wider needs a
witness or that documentation, so neither an agent's reading nor a Rigor finding alone moves it.

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

### WD6 — The runtime witness: RBS's own checker confirms what Rigor locates

Rigor's findings are leads with known false positives. sidekiq 7.0's `Config#client_middleware` is
`@client_chain ||= Chain.new(self); yield @client_chain if block_given?; @client_chain`, and `rigor
check` reports `declared Chain, inferred Chain?`; the method never returns `nil`. An unattended run that
widened on that finding would push a `nil` check onto every caller of the gem — the exported false
positive this project's rule forbids.

RBS already ships the confirming instrument. `rbs/test/setup`, run with `RBS_TEST_TARGET`, wraps the named
classes' methods with `Module#prepend` and checks every argument and return value against the loaded
declarations; `RBS::UnitTest#assert_send_type` does the same for one call inside a test. Verified on
the eval fixture: a `deliver` call on a rejected parcel raises `ReturnTypeError: expected ::String but
returns nil` under `-> String` and passes under `-> String?`, while the memoised `middleware` that `rigor
check` flags raises nothing on any call.

So the two tools divide the work: Rigor (and reading) says which exit may return the excluded value; a
call aimed at that exit, rejected by the runtime checker under the old declaration and accepted under the
new, is the witness a "say less" change needs. The asymmetry matters: a run that raises nothing proves
only that the tried inputs behave, so it never supports a narrower declaration. `rbs prototype runtime`
is not part of this: it emits every type as `untyped` and serves only to find undeclared methods and
parameter shapes. A witness executes the library's code with the user's privileges, so for a gem the
user does not already run it belongs in a container or VM or waits for the user's go-ahead; it is cited
in the pull request rather than committed, because the collection's `_test/` code is checked statically.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep ADR-108's "three sources, no fourth" and leave contracts to contributor docs | Rejected | Leaves the shipped skill contradicting the engine (#836, #837) and the collection PRs; agents outside this repository keep tightening `void` and keep refusing a documented `String?`. |
| Treat reading the implementation as a contract source | Rejected | It is the guess ADR-108 exists to stop, and #1129's `perform_async` is the counterexample: the body's value is exactly what the declaration hides. |
| One skill per target (gem author, application, collection) | Rejected | Shared judgment, colliding descriptions. Per-target `references/` instead (WD5). |
| Widen `rigor-type-oracle` to own the loop | Rejected | Trigger mismatch (WD5). |
| Rigor's finding alone as sufficient for a "say less" change | Rejected | `def.return-type-mismatch` has false positives (WD6's memoised `client_middleware`); sent upstream unattended, each one becomes a `nil` check imposed on every caller. A witness or documentation is required. |
| Report-only `sig-gen` classification for declarations narrower than the body | Deferred | `sig-gen` already compares a declaration against the body over every exit, early `return nil` included, but classifies a declaration narrower than the body as `equivalent`, which `--diff` never prints; `rigor check` compares only the last expression. Surfacing that verdict ([#3062](https://github.com/rigortype/rigor/issues/3062)) would turn reading leads into tool leads; a witness would still decide. It and a public form of the collection audit's harness are follow-ups, not preconditions. |

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
  valuable one to find and the worst surfaced. `sig-gen` computes it over every exit and discards it;
  `def.return-type-mismatch` reports only the last expression and has false positives. Until #3062
  surfaces the computed verdict, early returns and untyped falsy arms are reading leads, and every
  candidate needs a witness or that version's documentation either way.
- A witness runs the library's code with the user's privileges. The skill sends third-party gems to a
  container or VM or to the user's go-ahead, but it is still execution that a static checker's workflow
  did not need before.
- The eval suite is unrun at landing: its cases need a Rigor-configured project, as ADR-108 WD7's did.
- Another catalogue entry, frozen into the public skill vocabulary at v1.0 with the rest
  ([ADR-50](50-release-engineering-and-stability-strategy.md) WD1).

## Relationship to other ADRs

- **[ADR-5](5-robustness-principle.md)** — lenient parameters, strict returns; WD3 is that asymmetry
  applied to a shared alias, and WD1's rule for declared parameters is its "binds in both directions".
- **[ADR-14](14-rbs-sig-generation.md)** — `sig-gen`'s authorship policy; the direction criterion is why
  its proposals are evidence only for undeclared or `untyped` slots.
- **[ADR-107](107-checked-types-and-typeless-comments.md)** — its amendment made a declared `void`
  authored intent in Rigor's own tree; WD2 ships that reading outward.
- **[ADR-108](108-type-provenance-for-agents.md)** — amended by this ADR: a fourth, contract-scoped
  source, cited like the other three; its skill and fragment change to match.
