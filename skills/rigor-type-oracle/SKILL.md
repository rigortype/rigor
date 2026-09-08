---
name: rigor-type-oracle
description: |
  Before writing or asserting ANY Ruby type, get it from Rigor rather than from reading the code: `rigor type-of FILE:LINE:COL` / `rigor annotate FILE` for an expression, `rigor sig-gen --print FILE` for a method signature, call-site observation for a parameter. A type you did not obtain from Rigor is a guess, and a guessed type is never written anywhere. Triggers: writing RBS under `sig/`, an inline `#:` / `# @rbs` annotation, a Sorbet `sig do … end`, a YARD `@param` / `@return`, a type stated in a doc sentence or a review comment, a nil check / `is_a?` / `respond_to?` guard justified by "this should be an X", "add types to this class / file", "document this method", "what type is this / what does this return?". Applies to Rigor's own tree too. When Rigor answers `Dynamic[top]` or `untyped`, or `sig-gen` skips the method, report the gap — never fill it in from inference of your own. NOT for setting Rigor up (use rigor-next-steps) or working a baseline down (use rigor-baseline-reduce).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Type Oracle

You are about to write a type. Stop and ask Rigor first.

This project has a deterministic type oracle installed. Reading the
source and concluding "`currency` is a String, `pattern` is a Regexp" is
*plausible-guess* behaviour: it is right often enough to feel safe and
wrong often enough to poison a signature file, a doc comment, or a
reviewer's mental model. Rigor already knows the answer — for every
expression, at every line, from the same engine that will check the code
tomorrow. Asking it costs one command.

**The rule: a type you did not obtain from Rigor is a guess, and a
guessed type is never written anywhere.** Not in `sig/`, not in an inline
annotation (`#:`, `# @rbs`), not in a Sorbet `sig`, not in a YARD tag,
not in a doc sentence, not in a review comment, and not as the stated
reason for a nil check or an `is_a?` guard.

## First: load the version-current copy

This skill's exact commands, flags, output spellings, and skip-reason ids
drift between Rigor releases, so follow the copy that ships with the
**installed** Rigor rather than any vendored or frozen copy of this file.
Get the complete current procedure in one call:

```sh
rigor skill --full rigor-type-oracle   # this body + all its references/, inline
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed (read any `references/NN-*.md` from the directory the
header names). If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use

Trigger on the *act*, not on the user saying the word "type". You are in
scope the moment you are about to write or assert one:

- Writing or editing RBS under `sig/`.
- Writing an inline annotation — rbs-inline `#:`, `# @rbs`, a
  `%a{rigor:v1:…}` override.
- Writing a Sorbet `sig do … end`, or any other type DSL.
- Writing a YARD / RDoc `@param` / `@return` / `@raise`, or any doc
  sentence that names a type ("returns an Array of entries").
- Stating a type in a review comment, a PR description, or a chat answer.
- Justifying a nil check, an `is_a?` / `respond_to?` guard, or a
  defensive `to_s` with "this should be an X".
- Being asked "what type is this?", "what does this method return?",
  "add types to this class", "document this file".

It applies to **Rigor's own tree** as well: `lib/`, the bundled plugins,
and the examples are held to the same rule, and a gap found there is
engine signal worth more than the annotation you would have written.

## When NOT to use

- **Setting Rigor up on a project that has none** → `rigor-next-steps`
  (which routes to `rigor-project-init`). You cannot ask an oracle that
  is not installed.
- **Working an existing `.rigor-baseline.yml` down** →
  `rigor-baseline-reduce`. That is fixing diagnostics, not sourcing a
  type.
- **Raising type protection from a `coverage --protection` list** →
  `rigor-protection-uplift`. It owns the "where should a type go, and how
  do I verify it" loop; this skill owns "where does the type itself come
  from".

## The three allowed sources

Every type you write comes from exactly one of these. There is no fourth.

| What you need | Ask Rigor with | What you write |
| --- | --- | --- |
| The type of an **expression** at a point | `rigor type-of FILE:LINE:COL` — or `rigor annotate FILE` for every line at once | the `type:` it prints, verbatim |
| The **signature of a method** | `rigor sig-gen --print FILE` | the RBS it prints, verbatim — never what you expected it to print |
| A **parameter's intended type** | `rigor sig-gen --observe PATH --params=observed` (call-site derivation) | the observed type, *reviewed and widened*, kept only while `rigor check` stays green |

The parameter row is the one genuine gap. Inference reads a method
*body*, and a body does not state what its callers are allowed to pass —
so Rigor spells parameters `untyped` by design ([ADR-5](https://github.com/rigortype/rigor/blob/master/docs/adr/5-robustness-principle.md):
strict on returns, lenient on parameters). `--params=observed` derives
them from the call sites instead, which is evidence rather than
invention — but it is *narrow* evidence (it can emit literal types such
as `("JPY")`), so it is the one place you review and widen before
adopting, under the gate that `rigor check` gains no new diagnostic.

Exact command forms, flags, position syntax, JSON shapes, and how to read
each output: [`references/01-oracle-commands.md`](references/01-oracle-commands.md).

## The gap protocol — a gap is a finding, not a blank to fill

`Dynamic[top]`, `untyped`, and a `sig.skipped.*` classification are
**answers**. They mean "Rigor cannot prove a type here", which is
information about the project or about the engine. Filling that hole with
your own reading converts a known unknown into a confident falsehood, and
it does so in a file the next reader will trust.

So when the oracle comes back empty:

1. **Report it.** Give the exact command and its exact output.
2. **Find out why**, when it matters: `rigor trace --format=json --line=N FILE`
   replays how the type was built; `rigor explain <rule>` documents a
   diagnostic that fired nearby.
3. **Route it.** A project-side gap has a sibling skill that closes it
   (missing gem RBS → `rigor-rbs-setup`; an unconfigured framework →
   `rigor-plugin-tune`; the project's own monkey-patches →
   `rigor-monkeypatch-resolve`; a project DSL → `rigor-plugin-author`).
   An engine-side gap is a Rigor issue.

Which output means which gap, the full routing table, and how to word the
issue: [`references/03-gap-protocol.md`](references/03-gap-protocol.md).

## Provenance — every type you state carries its command

When you tell a human a type, tell them how to re-derive it. One line is
enough:

> `entries_matching` returns `Array[untyped] | []`
> (`rigor sig-gen --print lib/demo/budget_ledger.rb`).

This is not ceremony. It is the difference between an assertion the
reader must trust and a claim they can re-run in three seconds — and it
is what makes a wrong answer *findable* instead of permanent.

## With the MCP server connected, use the tools

If the Rigor MCP server is wired up (`rigor-mcp-setup`), `rigor_type_of`,
`rigor_annotate`, `rigor_sig_gen`, `rigor_check`, and `rigor_explain` are
the same oracle as tool calls — prefer them over shelling out, and treat
their results exactly as this skill treats CLI output. Argument shapes:
[`references/01-oracle-commands.md`](references/01-oracle-commands.md)
§ "The MCP tools".

## Worked example

Asked to document `Demo::BudgetLedger`, the guessing path writes
`@param currency [String]`, `@return [Numeric]`, `@param pattern
[Regexp]`. Here is the oracle path.

```sh
rigor annotate lib/demo/budget_ledger.rb
```

```ruby
    def initialize(currency, opening_balance: 0)   #=> Dynamic[top]
      @currency = currency                         #=> Dynamic[top]
      @entries = []                                #=> []
    def balance(as_of: nil)                        #=> Dynamic[top]
    def entries_matching(pattern)                  #=> Array[Dynamic[top]] | []
```

```sh
rigor sig-gen --print lib/demo/budget_ledger.rb
```

```
rigor sig-gen: skipped 2 method(s) it could not type or would not overwrite
(sig.skipped.untyped-return: 2). Run with --format=json to see each one with
its skip_reason.
class Demo::BudgetLedger
  def initialize: (untyped, ?opening_balance: untyped) -> void
  def record: (untyped, ?memo: untyped, ?at: untyped) -> Demo::BudgetLedger
  def entries_matching: (untyped) -> (Array[untyped] | [])
end
```

What you now know, and may write: `record` returns
`Demo::BudgetLedger`; `entries_matching` returns `Array[untyped] | []`.
What you must **report rather than write**: `balance` and `overdrawn?`
were skipped as `sig.skipped.untyped-return` — `@opening_balance` is
`Dynamic[top]`, so the arithmetic proves nothing. `currency` is not
`String` on any evidence Rigor has; it is `untyped`, and the YARD tag is
`@param currency — the ledger's currency` with no type at all.

Call-site derivation closes the parameter half where specs exist:

```sh
rigor sig-gen --print --params=observed --observe spec lib/demo/budget_ledger.rb
#   def initialize: ("JPY", ?opening_balance: 100) -> void
#   def entries_matching: (Regexp) -> (Array[untyped] | [])
```

`entries_matching: (Regexp)` is now *derived*, and adoptable. The
`("JPY")` / `100` literals are the narrowness warned about above — widen
them to `String` / `Integer` before adopting, and keep the change only
while `rigor check` stays green.

## When the user insists on a hand-written type anyway

They may. It is their code, and a human can know an intended contract
that no static reading can prove. Do not argue past one exchange:

1. Say once what Rigor actually reports for that site, with the command.
2. Write what they asked for.
3. Run `rigor check` on the touched paths and report the result.
4. **Say which lines the check covers.** A green `rigor check` proves
   that the annotation contradicts nothing Rigor can currently see — it
   does not prove the contract. Where the surrounding types are
   `untyped`, there is nothing to contradict, and you must say so rather
   than let a green run read as confirmation.

If the check *does* go red, the annotation modeled the wrong contract:
report it and revert, never suppress the diagnostic.

## Installing the rule in the project

An agent that never loads this skill still guesses. The durable fix is
one paragraph in the project's `AGENTS.md` / `CLAUDE.md`, so the rule is
in context every session rather than only when a skill happens to
trigger. The text to paste:
[`references/02-agents-md-fragment.md`](references/02-agents-md-fragment.md).
`rigor-project-init` installs it during onboarding.
