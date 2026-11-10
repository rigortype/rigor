---
name: rigor-rbs-contract
description: >-
  Audit, repair, and extend RBS declarations as contracts — a gem's own `sig/`, an application's `sig/`,
  or a gem_rbs_collection entry — by checking each one against Rigor's inference and the library's
  documented behaviour, then proving and explaining the change. Use when correcting or contributing RBS;
  not for sourcing one type mid-task (`rigor-type-oracle`) or raising `coverage --protection` numbers.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor RBS Contract

An RBS declaration is not a record of what a method happens to return. It is a promise about what
callers may rely on. Ruby returns every method's last expression, so inference always finds *some*
type; whether callers may depend on it is a choice only a declaration makes. This skill turns that into
a repeatable loop: find where declarations and code disagree, decide which side is wrong on cited
evidence, change the declaration, prove the change, and explain it so a reviewer can re-check it.

## First: load the version-current copy

Commands, flags, rule ids and skip-reason ids drift between Rigor releases, so follow the copy that
ships with the **installed** Rigor rather than a vendored or frozen copy of this file:

```sh
rigor skill --full rigor-rbs-contract   # this body + all its references/, inline
```

If you already loaded it via `rigor skill`, proceed. If `rigor` is not on `PATH`, run
**`rigor-next-steps`** first.

## When to use

- A gem author wants their shipped `sig/` checked, corrected or extended.
- An application's quality owner wants the RBS their `rigor check` relies on — the project's `sig/`, or
  a dependency's community RBS — audited, or a wrong dependency signature fixed.
- Someone is contributing to `ruby/gem_rbs_collection`: adding methods, fixing a declaration, or acting
  on a discrepancy Rigor surfaced.
- A diagnostic or a review comment says "the RBS says X but the code does Y", and the task is to settle
  which one is right.

## When NOT to use

- **Writing one type in the middle of another task** → `rigor-type-oracle`. It owns where a single type
  comes from; this skill owns what a set of declarations should promise.
- **Raising `rigor coverage --protection` numbers** on the project's own code → `rigor-protection-uplift`.
- **Installing community RBS** that exists but is not set up → `rigor-rbs-setup`.
- **A Rigor diagnostic you believe is wrong about correct code** → `rigor-ask`; that is an engine
  question, not a contract one.

## The two rules

**Contract rule.** Inference proves what a body does. It may *refute* a declaration, or fill a slot
nobody declared, but it never chooses the abstraction a declaration makes. A contract the body does not
prove is written only on the word of the party entitled to make it, and cited: the library's own
documentation for code you do not own, the owner's explicit answer for code they do.

**Direction rule.** Making a declaration *say less* — a return that admits `nil`, a parameter that
accepts more — needs a **witness** that the case is real: a call shown, by RBS's own runtime type checker,
to return or to need what the old declaration excludes; or the library's documentation. Rigor's findings
locate these cases and name the exit to aim at, but they have false positives, so on their own they are
a lead, not a witness. Making it *say more* — a narrower return, a narrower parameter, `void` replaced by
a value — needs a contract source. A `sig-gen` proposal counts only where the slot was undeclared or
`untyped`.

Four consequences come up on almost every run:

- **`void`, `boolish` and a deliberately wide nominal stand** unless the library documents a value.
  The body returning something is not documentation.
- **Reading the implementation finds candidates; it does not decide them.** The one exception is an
  undeclared or `untyped` parameter's structural need — an argument used only through `to_s` accepts
  `_ToS`. A *declared* parameter is a promise too; today's body is no reason to widen it.
- **A wholly wrong declaration is treated as missing.** When the declared type and the body share
  nothing (declared a connection pool, returns an `Integer`), it is neither saying less nor more: type
  the slot as if it were undeclared, and witness that the declared type never comes back.
- **One alias that is both input and output carries two contracts.** When they differ, split it rather
  than weaken it until both fit.

The full decision table, with the evidence each change needs and the shapes that look like findings but
are not: [`references/02-contract-rules.md`](references/02-contract-rules.md).

## Step 0 — Pick the target; it decides who has authority

| Target | Who decides a contract | Mode | Reference |
| --- | --- | --- | --- |
| The project's own code — a gem's `sig/`, an application's `sig/` | the owner | **interactive**: batch the open contract questions and ask | [`03-target-own-code.md`](references/03-target-own-code.md) |
| A gem you do not own — a gem_rbs_collection entry, or a local override of one | the gem's documentation | **autonomous** up to a finished branch and description; undocumented contracts are left alone and listed; pushing and opening the pull request wait for the user's go-ahead | [`04-target-gem-rbs-collection.md`](references/04-target-gem-rbs-collection.md) |

An application whose wrong signature comes from a dependency's community RBS is the second row: fix it
upstream, and keep a local override only until the fix is released.

## The loop

1. **Find.** Collect candidates from Rigor and from the documentation, not from a read-through. How,
   per signal, and what each one can and cannot see:
   [`references/01-finding-candidates.md`](references/01-finding-candidates.md).
2. **Triage.** Drop the shapes that are not contract findings — abstract methods, mutable registries
   proposed as `[]`, platform-guarded files, a `Dynamic` inference, a memoised value Rigor reads as
   nilable — before spending evidence on them.
3. **Decide.** For each remaining candidate, gather the evidence the direction rule asks for and cite
   it: the witness call and the error it raised, the command and its output, the quote with its
   `file:line` in the version under review, or the owner's answer. A candidate without the evidence it
   needs is not changed; it is reported.
4. **Write.** Change the declaration. Prefer `rigor sig-gen` output verbatim where it applies; write by
   hand only what the evidence supports, and nothing beyond it.
5. **Prove.** Run the target's gate. For every change that says less, keep the runtime witness: the
   call fails RBS's type checker under the old declaration and passes under the new one. Add a use-site
   test that exercises the new contract — a `nil` check on a newly optional return, a call with the
   newly accepted argument.
6. **Explain.** Every change carries its evidence. Every Rigor finding and every candidate you
   deliberately left alone — above all a `void` whose body returns a value, and a Rigor finding no
   witness confirmed — carries its reason, so a reviewer can tell restraint from oversight.

## Done when

Every candidate from step 1, including every row Rigor reported, is changed with its cited evidence,
left alone with its reason, or reported as an open question; the target's gate is green; and the write-up lists all three groups.

When the owner does not answer an open question, or the documentation cannot be found, stop there: leave
those declarations as they are, finish and prove the changes the evidence did settle, and hand back the
open list. Never resolve an open question by picking the option the body happens to match.

## Gaps are findings here too

When Rigor answers `Dynamic[top]`, `untyped`, or skips a method, that is not permission to fill the
slot from your reading — `rigor-type-oracle`'s gap protocol applies unchanged. What this skill adds is
the other source: where the library documents the contract, the documentation fills the slot, with the
quote. Where neither speaks, the slot stays as declared.
