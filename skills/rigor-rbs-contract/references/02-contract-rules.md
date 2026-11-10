# 02 — Deciding a candidate

Every change to a declaration either makes it say less or makes it say more. The direction decides the
evidence it needs. Cite that evidence with the change; without it, the candidate is reported, not
changed.

## What counts as evidence

| Evidence | How to cite it | Good for |
| --- | --- | --- |
| The library's documentation: a doc comment on the method, the README, the API reference | quote it, with the file and line or URL | any contract on code you do not own |
| The owner's explicit answer, for the project's own code | the question and the answer; better, a doc comment written from it | any contract on that code |
| Rigor's proof: `def.return-type-mismatch`, a `sig-gen` proposal, a `type-of` answer without `Dynamic` | the command and its output | saying less; filling an undeclared or `untyped` slot |
| A test or a one-off run that exercises the case | the test, or the command and what it printed | saying less: showing a `nil` or an argument shape is real |
| A parameter's structural need, read from the body | the line that uses it | widening a parameter to an interface (`_ToS`, `_Each[T]`) |
| Reading the implementation for anything else | — | nothing. It finds candidates; it does not decide them |

Documentation is graded by how directly it speaks. A doc comment that states the return ("Returns a
unique Job ID. If middleware stops the job, nil will be returned instead") is strong. A README example
that happens to use the value is weaker; say which kind you are citing.

## Saying less

| Change | Needs | Example |
| --- | --- | --- |
| A return admits a value it excluded (`String` → `String?`) | Rigor's proof, a run, or documentation | sidekiq `Client#push`; marcel `Magic.by_magic` (`instance` → `instance?`, shown by running it on input that matches nothing) |
| A parameter accepts more (`String` → `String \| Pathname`, a concrete class → an interface) | the body's structural need, documentation, or a correct call the old declaration rejects | marcel `by_extension` takes `_ToS`, because the gem only calls `to_s` on it |
| A record key becomes optional on input | a correct call that omits it | retryable `{ sleep: 3.2 }` |
| A declaration is added for a public method, as `untyped` slots | nothing beyond the method existing | — |

Before widening a return, look at what callers lose. Every caller now has to handle the new case, so the
change is right only if the case is real. "It could be nil if someone passes nonsense" is not evidence;
a documented or demonstrated `nil` is.

## Saying more

| Change | Needs |
| --- | --- |
| A narrower return over a declared non-`untyped` type | a contract source. A `tighter_return` proposal alone is not enough |
| A narrower return over `untyped`, or a new method's return | Rigor's proof (`sig-gen`'s proposal, verbatim) — or a contract source for anything it did not propose |
| A narrower parameter | a contract source. Observed call sites (`sig-gen --params=observed`) show what callers pass today, not what the method accepts; widen literals before adopting them |
| `void` or `boolish` → a value type | documentation of the value. The body returning something is not documentation |
| A deliberately wide nominal (`Numeric`, `Object`) → what the body returns | documentation of the narrower value |

## Rules that come up on almost every run

**`void` and `boolish` stand.** Every Ruby method returns its last expression, so a body nearly always has
a value. `-> void` says that value is not part of the contract; `boolish` says only its truthiness is.
Rigor enforces the first through `static.value-use.void`. Do not tighten either to the body's value unless
the library documents that value. In sidekiq 7.0, `perform_async` and `Client.enqueue*` return `push`'s
result from their bodies, but nothing documents it, so their `void` stayed while `push` itself became
`String?`.

**One alias, two contracts.** When a type alias, record or interface is both what callers pass in and
what the library hands back, check whether the two agree. Inputs usually accept partial or loose values;
outputs usually guarantee more. If they differ, split the alias — for example `option_overrides` (keys
optional) for input and `options` (keys required) for output — rather than making it loose enough for
both and weakening every return that uses it. Inputs stay lenient; outputs stay as precise as their
documented guarantee.

**A nilable wrapper on a value is not the same as an optional key.** `{ ?sleep: Numeric }` says the key may
be absent; `{ sleep: Numeric? }` says it may be present and `nil`. Use the second only where a present
`nil` is accepted and means something.

**Interfaces describe what the method uses.** When a parameter is only used through one or two methods,
an interface (`_ToS`, `_ToPath`, `_Each[T]`, or one you declare inside the library's namespace) is the
honest contract. Do not add top-level aliases or interfaces to a shared RBS tree.

**Consistency across versions.** A collection entry often has several version directories. Apply the same
contract to each version whose code and documentation say the same thing, and say in the write-up which
versions you changed and which you did not and why.

## When the evidence runs out

Leave the declaration as it is and put the candidate in one of the write-up's lists:

- **Deliberately left unchanged** — you looked, and the declaration is the right contract (a `void`
  over a value; a wide nominal; a proposal that is an inference gap).
- **Open questions** — the evidence does not settle it. For your own code, ask the owner. Upstream, a
  question in the pull request description is better than a guess in the diff.
