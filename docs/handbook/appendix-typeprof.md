# Appendix — Coming from TypeProf

[TypeProf](https://github.com/ruby/typeprof) is Ruby's
official type *inference* tool — a type-level abstract
interpreter, maintained inside Ruby core, that reads
un-annotated `.rb` files and tells you the types it deduced.
If you have used TypeProf, the most important thing to know is
that **Rigor and TypeProf share TypeProf's headline promise**:
neither one asks you to write `.rbs` first. Where the Steep
appendix opens with "both consume the same RBS," this one opens
with the inverse: both *produce* type information from plain
Ruby. The interesting differences are in *how* they infer and
*what they do with the result*.

This appendix is for users who already think in TypeProf terms
and want to know which Rigor concept matches which TypeProf
concept.

## The five-second pitch

| Question | TypeProf | Rigor |
| --- | --- | --- |
| Primary job | Generate RBS prototypes from Ruby | Check Ruby for provable bugs (`rigor check`) |
| Needs `.rbs` to start? | No — infers from `.rb` | No — infers from `.rb` |
| Inference strategy | Whole-program abstract interpretation ("type-level execution") from entry points | Local, per-method inference with budgets + a catalog at boundaries |
| Scale target | Small files / a prototyping pass | Whole codebase, incrementally, cached |
| Default output | RBS signatures (+ some errors as a side effect) | Diagnostics (+ RBS on demand via `sig-gen`) |
| Diagnostic philosophy | Report what abstract interpretation stumbles on | Stay silent unless the bug is provable |
| Literal precision | Widens to nominal in output (`1` → `Integer`) | Keeps `Constant<1>`, refinements, `IntegerRange` |

If TypeProf's slogan is "run your Ruby at the type level and
write down what came back," Rigor's is "prove what you can,
flag only that, and scale it." The two overlap most exactly at
one feature — `rigor sig-gen` (Chapter 11) does the job
TypeProf's CLI was built for.

## Both infer without annotations — that is the common ground

TypeProf and Rigor are the two Ruby
tools that give you something useful on a `lib/` directory
with **zero `.rbs` files**. Steep, by contrast, expects the
signatures up front. So if you came to Rigor from TypeProf,
the "no annotations needed" stance (Chapter 1) will already
feel familiar — it is the assumption you have been working
under all along.

```ruby
# slug.rb — no sig/ directory anywhere
class Slug
  def normalise(raw)
    raw.strip.downcase
  end
end
```

TypeProf abstractly interprets `normalise`, sees `String#strip`
then `String#downcase`, and (given a call site that passes a
`String`) emits `def normalise: (String) -> String`. Rigor
infers the same body locally and, under `sig-gen`, emits the
same signature — while *also* knowing internally that the
result is a `non-empty?`-unconstrained but lower-cased string
carrier, which it erases to `String` at the boundary.

Where they diverge:

- **TypeProf** follows the call graph. To learn that `raw` is
  a `String`, it needs to *see a call* that passes one — so
  TypeProf is most useful when pointed at a program with an
  entry point (or a small harness that exercises the methods).
- **Rigor** infers each method on its own terms against a
  catalog of core/stdlib/gem types, bounded by inference
  budgets, and falls back to `Dynamic[top]` for a parameter it
  cannot pin — no entry point or harness required.

## Type vocabulary — TypeProf output vs Rigor carriers

TypeProf emits RBS, so its *output* vocabulary is RBS. Rigor
reads and erases to the same RBS. The difference is internal
precision: TypeProf widens literals on the way out; Rigor
keeps a richer carrier and only erases at the boundary.

| Ruby expression | TypeProf output | Rigor internal (display) |
| --- | --- | --- |
| `1` | `Integer` | `Constant<1>` (erases: `Integer`) |
| `"foo".upcase` | `String` | `Constant<"FOO">` (erases: `String`) |
| `[1, "a"]` | `[Integer, String]` | `Tuple[Constant<1>, Constant<"a">]` |
| `{name: "x", age: 1}` | `{name: String, age: Integer}` | `HashShape{name: …, age: …}` |
| `x` unknown | `untyped` | `Dynamic[top]` (display: `untyped`) |
| `nil`-or-`Integer` | `Integer?` | `Integer \| Constant<nil>` (display: `Integer?`) |
| a `> 0`-guarded int | `Integer` | `positive-int` refinement (erases: `Integer`) |

The practical upshot: feed the same file to both, and
TypeProf's RBS and `rigor sig-gen`'s RBS will usually agree at
the *declaration* level, because Rigor's
[RBS erasure](../type-specification/rbs-erasure.md) deliberately
discards exactly the extra precision (`Constant`, `Refined`,
`IntegerRange`) that TypeProf never tracked. Inside the
analyzer, Rigor is carrying more — which is what powers its
refinement-carrier narrowing and constant-folding diagnostics.
(TypeProf does its own flow-sensitive narrowing on type-identity
predicates like `is_a?` / `nil?`; what it does not carry is the
*value-predicate refinement* layer or the curated diagnostics
Rigor produces from it.)

## Analysis model — the largest conceptual difference

This is where the tools part ways.

**TypeProf is a whole-program abstract interpreter.** It walks
the program from its entry points and *executes it at the type
level*: every method call propagates abstract argument types
to the callee, the callee's body is interpreted, and return
types flow back. This is inter-procedural and remarkably
precise on small programs — TypeProf can infer a method's
parameter types purely from how it is *called*, which neither
Steep nor Rigor attempts.

The cost is scale. Abstract interpretation of a whole program
is expensive, and the analysis can blow up combinatorially on
large or highly polymorphic codebases. TypeProf is explicitly
positioned as a tool for small programs, single files, or a
*starting-point* RBS pass — not a checker you run over a
100k-line app on every save.

**Rigor is a local, budgeted inferrer with a catalog at the
boundary.** It infers one method at a time. When that method
calls another, Rigor consults a *catalog* of known return
types (core, stdlib, gem RBS, plugin contributions) rather
than re-interpreting the callee's body. Calls it cannot
resolve become `Dynamic[top]` and stop there. This is less
precise than TypeProf on a self-contained toy program — Rigor
will not deduce a parameter type from a single call site the
way TypeProf can — but it is bounded by
[inference budgets](../type-specification/inference-budgets.md)
and backed by per-file caching (ADR-6), so it stays usable on
a whole codebase and across runs.

| | TypeProf | Rigor |
| --- | --- | --- |
| Unit of analysis | Whole program from entry points | One method at a time |
| Cross-method types | Re-interprets the callee body | Looks up the callee in a catalog |
| Infers params from call sites? | Yes (its signature move) | No (params default to `Dynamic[top]`) |
| Bounded? | By practical blow-up limits | By explicit inference budgets |
| Incremental / cached? | TypeProf 2 / `--lsp` improves this | Per-file cache across runs + machines |

The trade is intentional: TypeProf buys precision on
small inputs with whole-program interpretation; Rigor buys
scale and silence with local inference and a catalog.

## RBS generation — `typeprof` CLI vs `rigor sig-gen`

This is the one feature where the tools do the *same job*, and
it is worth a direct comparison. Generating RBS from Ruby is
TypeProf's entire reason to exist; for Rigor it is one
secondary command, [Chapter 11](11-sig-gen.md).

| | `typeprof foo.rb` | `rigor sig-gen` |
| --- | --- | --- |
| Output | RBS to stdout | RBS via `--print` / `--diff` / `--write` |
| Param types | Inferred from call sites | Conservative; `--params` policy, ADR-5 trade-off |
| Existing sigs | Regenerates from scratch | `new-file` / `new-method` / `tighter-return` classification; never overwrites a tighter human return |
| Literal precision in output | Widened to nominal | Erased to RBS (same widening at the boundary) |
| Driving signal it feeds back | A one-shot prototype to hand-edit | Gaps in `sig-gen` are themselves the signal Rigor should infer better |

A note specific to *this* repository: the project's standing
policy (AGENTS.md § "RBS Authorship") is to prefer
`rigor sig-gen` over hand- or AI-authored RBS, precisely
*because* a gap in `sig-gen` output is more valuable feedback
than a patched-over signature. If you are used to running
`typeprof` and pasting its output into `sig/`, the Rigor
analogue is `rigor sig-gen --diff` — but the mindset shifts
from "scaffold then edit" to "if the scaffold is wrong, fix
the inference."

## Tests as inference fuel — the bidirectional question

A natural follow-on to the analysis-model section: if TypeProf
learns parameter types from call sites, and tests are nothing
*but* call sites, how do the two tools use your `spec/` (or
`test/`) suite? There are two directions, and the tools
differ on each.

### Direction 1 — tests → method types

Tests are a pile of concrete examples of how a method is
called, so they are evidence for parameter types. This is
where the analysis models show through most sharply.

- **TypeProf fuels on call sites — and a test is just one
  kind of call site.** TypeProf has no concept of "a test." It
  infers parameters by abstractly interpreting the whole
  program, so *any* call it can see feeds a parameter type:
  top-level code, an example under `__END__`, a throwaway
  driver, or a line in a spec are all the same to it. A call
  that runs `Foo.new.bar(42)` — wherever it lives — is how
  TypeProf learns `bar` takes an `Integer`; with no such call,
  the parameter stays `untyped`. Tests happen to be a rich
  *source* of call sites (so pointing TypeProf at exercising
  code, including a suite, helps), but TypeProf neither
  recognises nor privileges them as tests.
- **Rigor does not read tests for `rigor check`.** Its local
  model leaves un-narrowed parameters at `Dynamic[top]`; the
  bug-finding gate never consults `spec/` to tighten them.
  Tests become a parameter signal only in the opt-in
  `rigor sig-gen --params=observed --observe=spec/` path
  ([Chapter 11](11-sig-gen.md)), which unions the observed
  argument type per position across every call site.

So the contrast is sharp: TypeProf interprets a spec as
ordinary Ruby (the `it` blocks are just more call sites),
whereas Rigor's sig-gen collector models the RSpec DSL
*structurally* — `described_class`, `subject`, and `let` are
recognised as bindings, not just executed:

```ruby
RSpec.describe Calc do
  subject { Calc.new }                  # :subject → Nominal[Calc]
  let(:other) { Calc.new }              # :other   → Nominal[Calc]
  it { subject.greet("Alice") }         # observed: Calc#greet receives String
  it { described_class.new.add(1, 2) }  # observed: Calc#add receives Integer, Integer
end
```

### Direction 2 — method types → tests

The reverse flow: once signatures land in `sig/`, they make
the *spec itself* checkable. `rigor check` (and the
`rigor-rspec` plugin) types `subject` / `let` bodies against
the real return types and checks matchers, which sharpens the
next `sig-gen` run, closing the loop. (Note the two RSpec
machines are separate: sig-gen's collector is built in and
needs no plugin; `rigor-rspec` is the standalone diagnostic
analyser. They run side by side, not shared.)

### The decisive difference — ADR-5

Observation-derived parameters are almost always **too
narrow**: a method only ever exercised with `String` in the
suite looks like it takes `(String)` even when it accepts far
more. The tools split on what to do about that.

- **TypeProf emits the observed-narrow parameter** — its job
  is to report what the type-level run saw.
- **Rigor refuses to make that the default.** Under the
  [robustness principle](../type-specification/robustness-principle.md)
  (strict returns, lenient parameters), `--params=observed` is
  a deliberate opt-in and its output is a *suggestion to
  review*, not a frozen contract. The default `untyped` is the
  stance that the suite's current usage should not silently
  become every future caller's obligation.

| | TypeProf | Rigor |
| --- | --- | --- |
| Role of tests | No special role — a test is just one more call site that fuels inference | Opt-in fuel for `sig-gen` only (never the `check` gate) |
| How a spec is read | Executed as ordinary Ruby (not recognised as a test) | `subject` / `let` / `described_class` recognised structurally |
| Observed-narrow params | Emitted as-is | Treated as a reviewable suggestion (ADR-5, opt-in, human gate) |
| Bidirectional loop | arg ↔ return within one pass | spec → sig → spec-checking → sharper sig |

Two honest limits on the Rigor side (both in Chapter 11):
same-name `let` bindings nested across `describe` / `context`
are last-wins, and `before` / `around` hook bodies are not
consulted for binding mutations.

## Diagnostics — a side effect vs the main product

TypeProf reports some errors as it interprets — an undefined
method, an obviously impossible operation — but these are a
*byproduct* of the inference pass, not a curated linter. They
can be noisy, and TypeProf is not pitched as a bug-finding gate.

Rigor inverts this. The diagnostic stream *is* the product,
and the governing rule (ADR-0, and the
[false-positive discipline](08-understanding-errors.md) the
whole tool is built around) is to stay silent unless the bug
is provable. Running `rigor check lib` yields a small,
high-confidence set of findings, not a transcript of
everything the interpreter found surprising.

So the mental shift coming from TypeProf is: do not expect
Rigor's output to be "the types it found" (use `sig-gen` for
that). Expect it to be "the small number of places the code is
provably wrong."

## Invocation

| TypeProf | Rigor |
| --- | --- |
| `typeprof app.rb` | `rigor sig-gen --print lib/app.rb` (for RBS) / `rigor check lib` (for bugs) |
| `typeprof -I sig app.rb` (load RBS) | `signature_paths:` in `.rigor.yml` (auto-detected) |
| `typeprof --lsp` (TypeProf for IDE) | `rigor lsp` (ADR-19) |
| harness file to drive call-site inference | not needed — local inference per method |
| core/stdlib RBS loaded automatically | catalog of core/stdlib types loaded automatically |

Both tools read gem RBS via the standard `rbs-collection`
mechanism, the same one Steep uses.

## What TypeProf has and Rigor does not

- **Parameter inference from call sites.** TypeProf's
  whole-program interpretation lets it deduce a method's
  *parameter* types from how the method is called. Rigor does
  not — an un-annotated, un-narrowed parameter is
  `Dynamic[top]` until a `.rbs` or a guard says otherwise.
- **True inter-procedural body interpretation.** TypeProf
  re-interprets callee bodies; Rigor looks callees up in a
  catalog. On a small self-contained program TypeProf can
  follow data flow further than Rigor will.
- **First-class "infer the whole signature" output.** It is
  TypeProf's primary product, with years of tuning aimed
  squarely at it. `rigor sig-gen` is deliberately more
  conservative (especially on parameters, per ADR-5).

## What Rigor has and TypeProf does not

- **Refinement carriers from value predicates.** Both tools do
  flow-sensitive *occurrence typing* on type-identity predicates
  (`is_a?`, `nil?`, `case`/`when`) — TypeProf included. What
  Rigor adds is **refinement carriers**: a *value* predicate
  like `unless s.empty?` or `n > 0` narrows into a named
  refinement type (`non-empty-string`, `positive-int`). TypeProf
  has no refinement-carrier concept, so those value-predicate
  refinements widen back to `String` / `Integer`.
- **Constant folding through method calls.** `"foo".upcase`
  resolves to `Constant<"FOO">`. TypeProf's output is
  `String`.
- **A curated, false-positive-disciplined diagnostic gate.**
  Rigor is a checker first; TypeProf's errors are a byproduct.
- **Whole-codebase scale with caching.** Inference budgets
  plus a per-file cache (ADR-6) keep `rigor check` usable on a
  large app on every run; TypeProf is positioned for smaller
  inputs.
- **RBS::Extended directives.** `%a{rigor:v1:…}` refinement /
  predicate / assertion grammar (Chapter 7) has no TypeProf
  analogue.
- **The plugin ecosystem.** Sorbet-input adapter, Rails-side
  narrowing, `dynamic_return` return-type
  contributions — extension surfaces TypeProf does not model.

## A coexistence pattern

The two tools compose naturally because they sit at different
points in the lifecycle:

1. **Bootstrap with TypeProf (optional).** On a brand-new file
   or small library with no sigs, `typeprof` can give you a
   first RBS draft to read. (Or skip straight to step 2 —
   Rigor does not need it.)
2. **Check with Rigor.** Run `rigor check lib` for the
   provable-bug gate. This is the day-to-day signal.
3. **Generate sigs with `rigor sig-gen`** when you want RBS
   that round-trips with Rigor's own inference and respects
   the `tighter-return` no-overwrite rule.
4. **Add Rigor to CI.** The checker gate runs on every push;
   TypeProf stays a local, occasional prototyping aid.

The standing rule when their RBS disagrees: TypeProf may infer
a *narrower parameter* from a call site that Rigor reports as
`untyped`. That is not a Rigor bug; it is the local-vs-whole-
program trade. If you want Rigor to honour that narrower
parameter, write it into `sig/` (both tools then read it) or
add a guard the engine can narrow on.

## A migration vignette

Suppose you have been using TypeProf to bootstrap `sig/` for a
mid-sized gem: you run `typeprof lib/**/*.rb`, hand-edit the
prototypes, and commit them. You want Rigor's bug-finding on
top.

Steps:

1. **Keep your generated `sig/`.** Rigor reads it as input
   exactly like Steep would — TypeProf-authored RBS is just
   RBS.
2. **Run `rigor check lib` once.** Expect a *different* kind
   of output than TypeProf gave you: not signatures, but a
   short list of provable findings — narrowing-aware
   diagnostics (`flow.always-truthy-condition`), return
   mismatches against your committed sigs
   (`def.return-type-mismatch`). Triage as bugs vs noise.
3. **Switch your RBS-generation step to `rigor sig-gen`.**
   Where you previously re-ran `typeprof` and re-edited, run
   `rigor sig-gen --diff` instead. The classification model
   (`new-file` / `new-method` / `tighter-return`) means it
   will *not* clobber a parameter type you hand-tightened.
4. **Optionally tighten sigs with `RBS::Extended`.** TypeProf
   treats `%a{rigor:v1:…}` as ordinary RBS comments and
   ignores them; Rigor reads them as refinement directives.
   The same `.rbs` file produces stricter Rigor output and
   unchanged TypeProf output.

The migration is low-friction because the shared assumption —
RBS as the interchange format, inference as the default — is
exactly the one TypeProf trained you on.

## What's next

You probably do not need to read the rest of this appendix
section sequentially. Three useful pointers:

- [Chapter 11 — Generating RBS with `rigor sig-gen`](11-sig-gen.md)
  — the feature that does TypeProf's job inside Rigor, with
  the no-overwrite classification model.
- [Chapter 8 — Understanding errors](08-understanding-errors.md)
  for the diagnostic gate that is Rigor's product, the thing
  TypeProf does not set out to be.
- [`docs/type-specification/inference-budgets.md`](../type-specification/inference-budgets.md)
  for the budget model that lets local inference scale where
  whole-program interpretation does not.

If you want to compare against another tool, the sibling
appendix pages cover [Steep](appendix-steep.md) — Ruby's other
static checker — plus [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), [mypy](appendix-mypy.md),
[Java / C#](appendix-java-csharp.md), [Rust](appendix-rust.md),
[Go](appendix-go.md), and [Elixir](appendix-elixir.md).
