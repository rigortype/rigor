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
declared return does not accept. Its message names both sides — `declared String, inferred String?`, or
a literal such as `inferred "a"?`. It compares a union member by member, so a typed member beside
`Dynamic` still counts: sidekiq 7.0's `Client#push` against its old `-> String` reports
`declared String, inferred Dynamic[top]?`. `--no-baseline` matters in an application: a baseline may
already be hiding exactly these.

A mismatch is a **lead**, not a witness. The rule has false positives: a memoised value re-read after a
`yield` (`@c ||= Chain.new(self); yield @c if block_given?; @c`) reads as `Chain?` although it can
never be `nil` — sidekiq's `Config#client_middleware` is that shape. A mismatch becomes a change only
with a runtime witness (Signal 6) or documentation.

Also worth reading here: `def.override-return-widened` (a subclass's declaration widens what its parent
promised). `static.value-use.void` (code uses a value a declaration says is `void`) is off in every
profile and fires only under the `use-of-void-value` bleeding-edge feature, so its silence proves
nothing.

What it cannot see: only the **last expression** is compared. An explicit `return nil` earlier in the
body, or a falsy arm behind an untyped value (`mime && new(mime[0])` where `mime` is untyped reads as
`Dynamic[top] | Marcel::Magic`), produces no diagnostic. The rule is also silent when the declared return
is `untyped` or `void`, and when the whole inferred type is `Dynamic`.

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

`sig-gen` never proposes over a declared `void` and never tightens a declared nominal to a literal. It
also compares a declaration that is *narrower* than the body over every exit — an early `return nil`
included — but classifies the result `equivalent`, which `--diff` does not print (#3062). So an empty
`--diff` does not mean the declarations are sound; Signal 1, the leads below and Signal 6 cover that
half.

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

## Signal 4 — `rigor type-of` on a returned value

```sh
rigor type-of lib/foo.rb:LINE:COL
```

Point it at the returned *value*, not the `return` keyword: in `return nil unless ok`, the column of
`nil` answers `nil`, while the column of `return` answers `bot` (the statement itself never produces a
value). Use it to confirm or rule out a lead. `String?` is proof. `Dynamic[top] | Foo` means one arm is unknown —
the declaration may or may not be right, and the decision needs documentation or a run.

## Leads from reading — locate only

These are worth searching for because no command reports them, but each is a lead, not evidence. A
lead becomes a change only with documentation or a witness (Signal 6).

- an explicit `return` or `return nil` before the last expression;
- `x && y`, `x&.y`, or `find`/`detect`/`Hash#[]` whose `nil` result is returned as is;
- `rescue … nil` or a `rescue` clause whose value is returned;
- a method whose declaration is `void` but whose doc comment describes a return value (the reverse
  case: the declaration may be too wide, and the documentation is the evidence).

## Signal 5 — the documentation

Read the documentation that ships with the version under review — doc comments and the README in that
version's source — as its own sweep, not only to confirm a lead, and note each quote's `file:line`. A
website or wiki describes some other release; see `02-contract-rules.md` for what it may support.

- doc comments containing "Returns", "nil", "or", "raises", "yields";
- the README's examples, which show which calls the authors consider the public API;
- the API reference, for public methods the RBS does not declare.

A documented return that the declaration contradicts is a candidate even when every Rigor signal is
silent. For sidekiq's `Client#push`, Signal 1 found the candidate and the doc comment — "If middleware
stops the job, nil will be returned instead" — settled it.

## Signal 6 — a runtime witness

RBS ships a runtime type checker. It wraps the methods of the classes you name, runs your Ruby, and
reports every argument or return value that does not match the loaded declarations. A call it rejects
is a **witness**: the evidence a "say less" change needs, and the way to tell a real Rigor finding from
a false positive. This runs the library's code, so for a gem you do not own, do it in a disposable
environment.

Write a short script that calls the method with an input aimed at the exit Rigor or your reading
pointed to — for `return nil unless carrier_accepts?(parcel)`, a parcel the carrier rejects:

```ruby
# witness.rb
require "courier"
Courier::Client.new.deliver(Courier::Parcel.new(2, 50))
```

```sh
RBS_TEST_TARGET='Courier::*' RBS_TEST_OPT='-I sig' RBS_TEST_RAISE=1 ruby -I lib -rrbs/test/setup witness.rb
# [Courier::Client#deliver] ReturnTypeError: expected `::String` but returns `nil`
```

Add `-rbundler/setup` before `-rrbs/test/setup` under Bundler, and `-r <library>` in `RBS_TEST_OPT` for
each standard library the declarations use. Run it again after the change: it must pass. The same check
fits a test suite as `RBS::UnitTest`'s `assert_send_type "(untyped) -> String?", receiver, :deliver,
arg`, which also checks the call against the declaration loaded for the class, so it fails before the
fix and passes after it.

A run that raises nothing is not a witness the other way: it shows only that the inputs you tried
behave. When no input you can justify produces the excluded value, the finding is "left unchanged — no
witness", not a change. For a project with a test suite, running the whole suite once under
`rbs/test/setup` checks every declaration the suite exercises.

`rbs prototype runtime` is a different tool: it prints the methods, arities, mixins and constants of the
loaded classes, with every type `untyped`. It is useful for finding undeclared methods — including ones
`define_method` creates — and parameter shapes, never for a return type.

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
| a `def.return-type-mismatch` adding `nil` to a memoised value (`@x ||= …`, possibly re-read after a `yield`) | a known false-positive shape; it needs a witness, and usually none exists |
| a mismatch whose `nil` comes only from a lookup (`Hash#[]`, `find`, `detect`) on a key or element the library always supplies | worst-case reading; it needs a witness with an input the library allows |

`rigor explain <skip-reason>` documents each skip reason in full.

## What each signal sees

| Question | Signal |
| --- | --- |
| Is a declared return narrower than the body's last expression? | 1, confirmed by 6 |
| Is a declared return narrower than an early `return` or an untyped falsy arm? | leads, confirmed by 6 or 5 |
| Is a Rigor finding real or a false positive? | 6 |
| Is a public method undeclared? | 2 (`new_method`), 5, `rbs prototype runtime` |
| Could an `untyped` return be precise? | 2 (`tighter_return` over `untyped`) |
| Is a parameter too narrow? | 3 |
| Is a `void` hiding a documented value? | 5 |
