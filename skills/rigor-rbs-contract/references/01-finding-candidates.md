# 01 — Finding candidates

A candidate is a declaration that may promise the wrong thing, or a public method that promises nothing
because it is not declared. Collect them from the signals below, record the command that produced each,
and only then decide anything. Every signal sees part of the picture; the table at the end says which
part.

All commands run with the RBS under review on Rigor's signature path and the library's source as the
analysed paths. How to arrange that for each target: [`03-target-own-code.md`](03-target-own-code.md),
[`04-target-gem-rbs-collection.md`](04-target-gem-rbs-collection.md).

## Signal 1 — `rigor check` over the library's own source

```sh
rigor check --no-baseline --format=json lib
```

The rule to look for is **`def.return-type-mismatch`**: the body's last expression has a type the
declared return does not accept. Its message names both sides — `declared String, inferred String?` — so
it is a direct refutation and the strongest evidence this skill gets from a tool. `--no-baseline`
matters in an application: a baseline may already be hiding exactly these.

Also worth reading here: `def.override-return-widened` (a subclass's declaration widens what its parent
promised) and `static.value-use.void` (code inside the library uses a value its own declaration says is
`void` — usually a sign the `void` is still right and the caller is the problem).

What it cannot see: only the **last expression** is compared. An explicit `return nil` earlier in the
body, or a falsy arm behind an untyped value (`mime && new(mime[0])` where `mime` is untyped reads as
`Dynamic[top] | Marcel::Magic`), produces no diagnostic. The rule is also silent when the declared return
is `untyped` or `void`, and when the body is `Dynamic`.

## Signal 2 — `rigor sig-gen --diff` against the declarations

```sh
rigor sig-gen --diff --format=json lib
```

Each entry in `candidates` has a `classification`:

| `classification` | Meaning | What it is evidence for |
| --- | --- | --- |
| `new_method` | a public method with no declaration; `rbs` is the proposal | filling an undeclared slot — adopt the proposal verbatim, or leave the method out |
| `tighter_return` | Rigor proved a return narrower than `declared_return_rbs` | over `untyped`: an adoptable proposal. Over anything else: a "say more" change, which needs a contract source — the proposal alone is not enough |
| `skipped` | no proposal; `skip_reason` says why | nothing — see triage below |

`sig-gen` never proposes over a declared `void`, never tightens a declared nominal to a literal, and never
reports a declaration that is *narrower* than the body. So an empty `--diff` does not mean the
declarations are sound; Signal 1 and the leads below cover that half.

Private and protected methods are skipped unless you pass `--include-private`; a collection entry rarely
wants them.

## Signal 3 — `rigor check` over code that uses the library

Use-site code is where an input contract shows up: the project's own callers, the gem's `spec/` or
`test/`, or a collection entry's `_test/`.

```sh
rigor check --no-baseline --format=json <use-site paths>
```

Read each finding against the question "is this call correct Ruby that the library accepts?":

- **`call.argument-type-mismatch` on a call the library accepts** — the declared parameter is too
  narrow. retryable's `{ sleep: 3.2 }` failed because one record type required all ten keys.
- **`call.undefined-method` on a method the library defines** — a missing declaration.
- **`call.possible-nil-receiver`** — usually the declaration is right and the caller is wrong; check
  before "fixing" the RBS to silence it.

A use-site diagnostic can also be a Rigor false positive. If the call is correct and the declaration is
correct too, reproduce it minimally and route it through `rigor-ask`; do not bend the RBS around it.

## Signal 4 — `rigor type-of` on a return expression

```sh
rigor type-of lib/foo.rb:LINE:COL
```

Use it to confirm or rule out a lead. `String?` is proof. `Dynamic[top] | Foo` means one arm is unknown —
the declaration may or may not be right, and the decision needs documentation or a run.

## Leads from reading — locate only

These are worth searching for because no command reports them, but each is a lead, not evidence. A
lead becomes a candidate only with documentation, a test, or a run that shows the case is real.

- an explicit `return` or `return nil` before the last expression;
- `x && y`, `x&.y`, or `find`/`detect`/`Hash#[]` whose `nil` result is returned as is;
- `rescue … nil` or a `rescue` clause whose value is returned;
- a method whose declaration is `void` but whose doc comment describes a return value (the reverse
  case: the declaration may be too wide, and the documentation is the evidence).

## Signal 5 — the documentation

Read the library's documentation as its own sweep, not only to confirm a lead:

- doc comments containing "Returns", "nil", "or", "raises", "yields";
- the README's examples, which show which calls the authors consider the public API;
- the API reference, for public methods the RBS does not declare.

A documented return that the declaration contradicts is a candidate even when every Rigor signal is
silent — that is how sidekiq's `Client#push` (`String`, documented to return `nil` when middleware stops
the job) was settled.

## Triage before deciding

Drop these before spending evidence on them:

| Shape | Why it is not a contract finding |
| --- | --- |
| `skip_reason` `sig.skipped.abstract-method`, `template-method`, `overridden-bot`, `overridden-by-unsigned-subclass` | abstract or template methods; the declaration states what overriders return, which the base body cannot show |
| `sig.skipped.platform-guarded` | the definition loads only under a `RUBY_ENGINE` / `RUBY_PLATFORM` guard; the declaration describes the other platform's implementation |
| `sig.skipped.untyped-return` | Rigor has no answer; the gap protocol in `rigor-type-oracle` applies |
| a proposal of `[]` or `{}` | usually a collection the method fills later, or a registry callers append to; the element type is the contract, not "empty" |
| a proposal of `bot` or `top` | `bot` is almost always an abstract or raising method; `top` says nothing a declaration should adopt |
| a `tighter_return` that drops an arm the code clearly has (an `else`, a `rescue`) | an inference gap; report it, do not adopt it |

`rigor explain <skip-reason>` documents each skip reason in full.

## What each signal sees

| Question | Signal |
| --- | --- |
| Is a declared return narrower than the body's last expression? | 1 |
| Is a declared return narrower than an early `return` or an untyped falsy arm? | leads + documentation or a run |
| Is a public method undeclared? | 2 (`new_method`), 5 |
| Could an `untyped` return be precise? | 2 (`tighter_return` over `untyped`) |
| Is a parameter too narrow? | 3 |
| Is a `void` hiding a documented value? | 5 |
