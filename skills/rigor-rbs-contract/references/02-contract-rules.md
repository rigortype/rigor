# 02 — Deciding a candidate

Every change to a declaration either makes it say less, makes it say more, or replaces a declaration
that is wholly wrong. The kind decides the evidence it needs. Cite that evidence with the change;
without it, the candidate is reported, not changed.

## What counts as evidence

| Evidence | How to cite it | Good for |
| --- | --- | --- |
| The library's documentation **for the version under review**: a doc comment on the method, the README shipped in that gem | quote it with its `file:line` in that version's source | any contract on code you do not own |
| The owner's explicit answer, for the project's own code | the question and the answer; better, a doc comment written from it | any contract on that code |
| A runtime witness: a call that RBS's runtime type checker (`rbs/test/setup` or `RBS::UnitTest`) rejects under the old declaration and accepts under the new one | the call, and the error it raised under the old declaration | saying less; showing a wholly wrong declaration is never returned |
| Rigor's findings: `def.return-type-mismatch`, a `sig-gen` proposal, a `type-of` answer | the command and its output | locating a candidate and the exit to aim a witness at; filling an undeclared or `untyped` slot |
| A correct call the old declaration rejects, found by `rigor check` on use-site code | the call and the diagnostic | widening a parameter or an input record |
| An undeclared or `untyped` parameter's structural need, read from the body | the line that uses it | typing that parameter as an interface (`_ToS`, `_Each[T]`) |
| Reading the implementation for anything else | — | nothing. It finds candidates; it does not decide them |

How to run a witness: [`01-finding-candidates.md`](01-finding-candidates.md) § "Signal 6".

**Documentation is pinned to the version.** Quote the doc comment or README from the unpacked source of
the version whose declaration you are changing. A website, wiki or default-branch README describes some
other release, so it may support a question in the write-up but is never the sole support for a change —
least of all for `void` → a value. Grade what you quote: a doc comment that states the return ("Returns
a unique Job ID. If middleware stops the job, nil will be returned instead") is strong; a README example
that happens to use the value is weak. Say which kind you are citing.

## Saying less

| Change | Needs | Example |
| --- | --- | --- |
| A return admits a value it excluded (`String` → `String?`) | a runtime witness or that version's documentation. On code you do not own, a Rigor finding alone is never enough | sidekiq `Client#push` (documented, and a halting middleware returns `nil`); marcel `Magic.by_magic` (`instance` → `instance?`, witnessed by a lookup on input that matches nothing) |
| A parameter accepts more (`String` → `String \| Pathname`) | documentation, or a correct call the old declaration rejects | — |
| An undeclared or `untyped` parameter is typed as an interface | the body's structural need | marcel `by_extension` takes `_ToS`, because the gem only calls `to_s` on it |
| A record key becomes optional on input | a correct call that omits it | retryable `{ sleep: 3.2 }` |
| A declaration is added for a public method, as `untyped` slots | nothing beyond the method existing | — |

**Rigor's findings have false positives, so they are leads.** sidekiq 7.0's `Config#client_middleware`
is `@client_chain ||= Chain.new(self); yield @client_chain if block_given?; @client_chain`, and
`rigor check` reports `declared Chain, inferred Chain?` although it never returns `nil`. An agent that
widened on that finding would push a `nil` check onto every caller of the gem. A witness is what tells
the two apart: no input makes `client_middleware` return `nil`, so none can be produced.

**A missing witness is not proof the other way.** A run that raises nothing shows only that the inputs
you tried behave; it never justifies a narrower declaration. When you cannot produce a witness and the
documentation is silent, leave the declaration and record the finding.

**A declared parameter is a promise both ways.** Widening it promises callers that the library accepts
more, and the next release may not keep that promise (a body that only calls `to_s` today may call
`downcase` tomorrow). So a declared parameter widens only on documentation or a correct call it rejects,
never on the body's current structural need alone.

Before widening a return, look at what callers lose. Every caller now has to handle the new case, so the
change is right only if the case is real. "It could be nil if someone passes nonsense" is not a witness;
an input the documentation allows, or a use the library's own callers make, is.

## Saying more

| Change | Needs |
| --- | --- |
| A narrower return over a declared non-`untyped` type | a contract source. A `tighter_return` proposal alone is not enough |
| A narrower return over `untyped`, or a new method's return | Rigor's proof (`sig-gen`'s proposal, verbatim) — or a contract source for anything it did not propose |
| A narrower parameter | a contract source. Observed call sites (`sig-gen --params=observed`) show what callers pass today, not what the method accepts; widen literals before adopting them |
| `void` or `boolish` → a value type | that version's documentation of the value. The body returning something is not documentation |
| A deliberately wide nominal (`Numeric`, `Object`) → what the body returns | that version's documentation of the narrower value |

## Replacing a wholly wrong declaration

Sometimes the declared type and the body have nothing in common: sidekiq 7.0's `Config#total_concurrency`
is declared `ConnectionPool[RedisClientAdapter]`, and its body is `capsules.each_value.sum(&:concurrency)`
(`rigor check` reports `inferred Integer`). That is neither saying less nor saying more. Treat the slot
as undeclared:

1. Take the type from that version's documentation, or from `rigor sig-gen --print` run on a copy of the
   declarations with this member removed — the same source an undeclared method would get.
2. Witness that the old declaration is wrong: one call whose result RBS's type checker rejects against
   the old type.
3. Say in the write-up that the declaration was replaced, not widened or narrowed.

## Rules that come up on almost every run

**`void` and `boolish` stand.** (For the project's own code, the owner may decide otherwise; that is a
contract decision, so ask rather than infer.) Every Ruby method returns its last expression, so a body
nearly always has a value. `-> void` says that value is not part of the contract; `boolish` says only
its truthiness is. `static.value-use.void` reports a use of the first where a project enables it. Do not
tighten either to the body's value unless the library documents that value. In sidekiq 7.0,
`perform_async` and `Client.enqueue*` return `push`'s result from their bodies, but nothing documents
it, so their `void` stayed while `push` itself became `String?`.

**One alias, two contracts.** When a type alias, record or interface is both what callers pass in and
what the library hands back, check whether the two agree. Inputs usually accept partial or loose values;
outputs usually guarantee more. If they differ, split the alias — for example `option_overrides` (keys
optional) for input and `options` (keys required) for output — rather than making it loose enough for
both and weakening every return that uses it. Inputs stay lenient; outputs stay as precise as their
documented guarantee.

**A nilable wrapper on a value is not the same as an optional key.** `{ ?sleep: Numeric }` says the key may
be absent; `{ sleep: Numeric? }` says it may be present and `nil`. Use the second only where a present
`nil` is accepted and means something.

**Interfaces describe what the method uses.** When an undeclared or `untyped` parameter is only used
through one or two methods, an interface (`_ToS`, `_ToPath`, `_Each[T]`, or one you declare inside the
library's namespace) is the honest contract. Do not add top-level aliases or interfaces to a shared RBS
tree.

**Consistency across versions.** A collection entry often has several version directories. Apply the same
contract to each version whose code and documentation say the same thing — witnessed or quoted in that
version — and say in the write-up which versions you changed and which you did not and why.

## Every finding gets a disposition

Each row Rigor reported (Signal 1 and Signal 2) and each lead you followed ends in exactly one list:

- **Changed** — with its evidence.
- **Deliberately left unchanged** — you looked, and the declaration is the right contract: a `void` over
  a value; a wide nominal; a proposal that is an inference gap; a Rigor finding no witness confirmed
  (say so — "`rigor check` reports `Chain?`; no input returns `nil`").
- **Open questions** — the evidence does not settle it. For your own code, ask the owner. Upstream, a
  question in the pull request description is better than a guess in the diff.
