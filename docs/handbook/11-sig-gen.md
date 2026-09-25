# Generating RBS with rigor sig-gen

When `rigor check` is happy with your code but `sig/` is still
mostly empty, the analyzer is doing useful inference that
never reaches anyone but itself. `rigor sig-gen` is the
companion command that emits the inferred signatures as RBS
so the rest of the toolchain — Steep cross-checks, IDE
tooltips, downstream consumers reading your gem's `sig/` —
sees what Rigor sees.

This chapter is a walkthrough of the command's UX, the
classification model, the output modes, and the
`--params` policy trade-off that comes straight out of
[ADR-5](../adr/5-robustness-principle.md)'s asymmetric
"strict on returns, lenient on parameters" rule.

## When to reach for it

- You inherited a Ruby project with zero RBS coverage and
  want a starting point that is more honest than `rbs
  prototype rb`'s syntactic skeleton.
- You added a method, `rigor check` recognises it, and now
  you want the corresponding sig file updated without
  retyping the signature by hand.
- Your existing RBS declares `() -> Numeric` but Rigor
  proves `() -> Integer`. You want the tighter spelling
  applied to `sig/` (after review).

What it is **not**: a replacement for hand-authored RBS
that captures intent the source code does not. If a public
method should accept `_ToStr` because the contract is
"anything that responds to `to_s`" but the current callers
only happen to pass `String`, `sig-gen` will not invent
`_ToStr` for you — the [`--params` policy](#the---params-policy-and-adr-5)
section below and ADR-5 explain why.

## A first run

Given a `lib/calc.rb`:

```ruby
class Calc
  def add(a, b)
    "sum"
  end

  def greet(name)
    "hi"
  end
end
```

and an empty `sig/`, `rigor sig-gen` prints RBS skeletons:

```
$ rigor sig-gen
# lib/calc.rb
class Calc
  # [new]
  def add: (untyped, untyped) -> String
  # [new]
  def greet: (untyped) -> String
end
```

By default the command writes nothing — it prints the
proposal so you can review it. Pass `--write` to apply the
proposal to `sig/`.

## The output modes

| Mode | Behaviour |
| --- | --- |
| `--print` (default) | Print RBS to stdout, grouped by source file + class declaration. |
| `--diff` | Show a unified-style diff comparing the existing-declared spelling (if any) against the inferred spelling. Read-only. |
| `--write` | Apply the proposal to `sig/<path>.rbs`. Creates files, inserts new methods into existing class declarations, appends new class blocks to files that don't declare them yet. |
| `--check` | Run the `--write` merge without writing, print what it would change, and exit `1` if anything would change. Read-only. |

The four flags are mutually exclusive; passing two different
ones is a usage error.

`--write` is the only mode that touches the filesystem. It
operates **only** inside `configuration.signature_paths`
(default `sig/`); anything outside that tree is reported as
`skipped_outside_sig_root` without being written to.

### Keeping `sig/` current in CI

`--check` is the freshness gate. It takes the same options as
`--write` and fails exactly when that `--write` would create or
change a file, or would refuse one:

```sh
rigor sig-gen --check lib
```

```
would update sig/greeter.rbs (1 method(s))
  - def greet: (String name) -> String
  + def greet: (Symbol name) -> String
```

It exits `0` and prints `sig/ is up to date` otherwise. Under
`--format=json` the payload is `{"up_to_date": …, "results":
[…]}`, one entry per target in the `--write` JSON shape.

The gate follows `--write`, not `--diff`. A `tighter-return`
against a declaration that already exists is a proposal
`--write` declines without `--overwrite`, so it does not fail
`--check` either; a project that reviewed the proposal and
kept its wider type can still pass. `--check --overwrite`
counts it, because `--write --overwrite` would apply it. Pass
`--check` the `--params` and `--effect-envelopes` flags your
`--write` uses, or it checks a different output.

## The classification model

Every method `rigor sig-gen` considers lands in one of six
states:

| Classification | Meaning |
| --- | --- |
| `new-file` | No RBS file declares the receiver class at all. |
| `new-method` | RBS file declares the class but not this method. |
| `tighter-return` | RBS file declares the method, but the inferred return is a strict subtype of the declared return. |
| `inline-update` | `sig/` holds a copy of a method declared inline with `# @rbs` / `#:`, and the inline declaration has changed since. See [Methods declared inline](#methods-declared-inline). |
| `equivalent` | Nothing for `sig-gen` to propose: the inferred return is identical, wider or unrelated, or it is a narrowing the generator declines (a literal under a wider declaration, anything under a declared `void`). Silently skipped. |
| `skipped` | Disqualified for one of the reasons below. |

The `sig.skipped.*` reasons are:

- `sig.skipped.complex-shape` — reserved for a parameter
  shape the renderer cannot spell. Every shape a `def` can
  declare renders today (optional, rest, trailing, keyword,
  keyword-rest, `...` forwarding, `&block`), so the
  generator does not produce this reason; it stayed
  reserved when the gate that used to fire it for every
  such method was retired (#778).
- `sig.skipped.untyped-return` — the method body's last
  expression types as `Dynamic[top]`. Emitting `untyped` as
  a tightening would be noise rather than help.
- `sig.skipped.user-authored` — `--overwrite` was not set
  and the method's existing RBS declaration would have to
  be replaced.
- `sig.skipped.inline-declared` — `.rigor.yml` sets
  `sig_gen.inline_declared: skip` and the method is declared
  inline. See [Methods declared inline](#methods-declared-inline).
- `sig.skipped.inline-generic-class` — the method's class is
  generic by an inline declaration and `sig/` does not declare
  it yet. See [Classes made generic inline](#classes-made-generic-inline).
- `sig.skipped.unrenderable-rbs` — the signature Rigor
  rendered for this method does not parse as RBS. This one
  is a **bug in Rigor**, not a property of your code: every
  generated line is parsed before it is emitted, and a line
  `rbs` rejects is dropped rather than written, because an
  unparseable `.rbs` is quarantined *whole* by `rigor check`
  — one bad line would take every other type in the file
  down with it. The rest of the signatures are unaffected;
  the skipped method is reported on stderr, and it is worth
  reporting to us.

## Methods declared inline

A method you annotated with `# @rbs` or `#:` already has a
contract, written next to the code. `sig-gen` does not infer
one for it; it copies yours into `sig/`, so the generated
signature is the whole contract your gem ships:

```ruby
class Greeter
  # @rbs name: String
  # @rbs return: String
  def greet(name) = "Hello, #{name}"

  #: () -> Integer
  def count = 1

  # @rbs num: Float
  def pair(num) = [num, num.to_s]
end
```

```
$ rigor sig-gen
# lib/greeter.rb
class Greeter
  # [new]
  def greet: (String name) -> String
  # [new]
  def count: () -> Integer
  # [new]
  def pair: (Float num) -> [Float, String]
end
```

`count` is written as `Integer`, not the `1` its body proves:
the declaration is what you meant, and inference does not
override it. `pair` declares its parameter and not its return,
so the parameter is copied and the return comes from the body,
the same split [ADR-107](../adr/107-checked-types-and-typeless-comments.md)
draws between authored parameters and generated returns. An
`initialize` is always written `-> void`, whatever its body
ends with. A member annotation you wrote inline, such as
`# @rbs %a{deprecated}`, is copied with it. A method with no
annotation of its own is proposed exactly as in any other
file.

Once `sig/` holds the copy, it is the declaration `rigor
check` reads (the `.rbs` wins over the inline one for the same
member). When you later edit the inline annotation, the copy
is stale. `sig-gen` then classifies the method `inline-update`
and `--write` replaces the copy with your current inline
declaration, without `--overwrite`: what changed is what you
wrote. `--check` fails until you do, which is what makes it
worth running in CI. The update only ever adds annotations to
the copy; one you delete inline stays in `sig/` until you
delete it there too.

Only what you wrote inline drives that update. For `pair`,
that is the parameter: the return in `sig/` came from the
body, so it is held to the same rules as any inferred return.
If you widened it by hand after review (`-> Array[String]`
over a `[String, String]` the body builds), sig-gen leaves
it alone. A return the body proves strictly narrower is a
`tighter-return` proposal, applied only with `--overwrite`.
When you change the parameter annotation, the update keeps
the return `sig/` already has.

### Classes made generic inline

sig-gen does not write a class's type parameters yet. A class
declared generic inline (`# @rbs generic T`) is therefore not
opened in `sig/`: a header without its parameters would make
rbs reject the class, and every class whose signature mentions
it, with `GenericParameterMismatchError`. Its methods, and
those of classes nested in it, are skipped as
`sig.skipped.inline-generic-class`. Declare the class in
`sig/` with its parameters (`class Box[T]` ... `end`) and
sig-gen writes the members into that declaration.

### Projects that run Steep on the same annotations

If Steep reads your inline annotations (`check "lib", inline:
true` beside `signature "sig"`), a copy in `sig/` is a second
declaration of each method, and Steep rejects the class with
`DuplicatedMethodDefinition`. Tell `sig-gen` to leave those
methods out:

```yaml
sig_gen:
  inline_declared: skip
```

Every method the inline reader declares is then skipped as
`sig.skipped.inline-declared`. That includes the un-annotated
`def`s of a file that carries any annotation, because the
reader declares those too (as `untyped`), and so does rbs's
own inline parser, which Steep's `inline: true` uses. A file
with no annotation at all is not read inline by Rigor, so its
methods are still written; if Steep reads that file inline,
keep it out of the paths you give `sig-gen`.

What the setting costs: `sig/` is no longer the whole
contract. A consumer that reads only your shipped `sig/` —
Rigor or Steep in a project that depends on your gem — never
sees the skipped methods. Their inline annotations, including
a Rigor refinement written there, take effect only where the
source itself is analysed, which is your own project.

## Emitting effect annotations

If your `.rigor.yml` carries an `effects:` block, `sig-gen`
writes one more thing: `%a{pure}`, the purity annotation rbs
and Steep already understand, above the methods whose whole
footprint Rigor read and found to be nothing.

```ruby
class Label
  def render
    parts = []
    parts << "a"
    parts.join
  end
end
```

```
$ rigor sig-gen
# lib/label.rb
class Label
  # [new]
  %a{pure}
  def render: () -> String
end
```

Five conditions have to hold before an annotation is written,
and every one of them exists to keep a wrong one off the
page. An emitted annotation is not a hint — the effects opt-in reads
it back as an **envelope** and enforces it on the method and
on everything the method reaches, so a `%a{pure}` `sig-gen`
invented would put `effect.envelope-exceeded` on code that
is correct.

- The summary must be **exhaustive**: every call the method
  reaches was resolved. A summary that is not reads "these
  effects, and possibly more", which is exactly the claim an
  envelope must not make.
- The summary must be **undischarged**: nothing in the
  method's footprint may be invisible only because
  `effects.tolerated:` says to ignore it. A method whose
  whole footprint is a tolerated `telemetry` call looks
  clean to *your* project and to nobody else — not to a
  consumer reading your shipped `sig/`, and not to your own
  `--no-tolerated-effects` audit.
- Every callee must be **described by something**: a
  catalogue row, a plugin, an envelope, or a definition in
  your own project. "Every call resolved" and "every callee's
  footprint is known" are different questions. A method whose
  body is one call into a gem nobody has written a row or an
  envelope for is exhaustive and tells you nothing, so it is
  left bare rather than called pure.
- The method must not **already carry a bound of its own**.
  An annotation on the method or on its class — in `sig/` or
  as an rbs-inline `# @rbs %a{…}` — or an `effects.envelopes:`
  stanza selecting it by `namespace:` or by `match:`, is a
  contract you wrote about this body; sig-gen will not replace
  it with an inference about the same body. A bound whose
  label is misspelled counts too: it bounds nothing, but
  overwriting it would delete the annotation the
  `effect.unknown-label` report points at.
- The `≤` lane must be **empty**. A callee that states its
  own bound puts that claim in your method's declared lane
  without proving anything, so `rigor effects` shows
  `[] ≤ [io.net.http]` where the proven lane is empty. Rigor
  will not write `%a{pure}` over a claim it never proved
  away.

`--effect-envelopes` adds the labelled spelling,
`%a{rigor:v1:effect io.db, nondet.time}`, for methods that
do have a footprint. It is a separate flag because `%a{pure}`
is the ecosystem's annotation and this one is Rigor's: a
labelled envelope in your `sig/` is a Rigor-specific contract,
and you should ask for it by name.

Under `--write`, an annotation goes on the line above the
declaration it binds. A declaration that **already** carries
annotations is left byte-untouched and reported as
`sig.effect.left-unreadable`: the writer cannot tell an
annotation it wrote from one you wrote, and it has no grammar
for merging two, so it will not rewrite that region. Decide
what it should say and write it yourself.

The `sig.effect.*` reasons are:

- `sig.effect.emitted` — an annotation was rendered.
- `sig.effect.withheld-tolerated` — the footprint is only
  clean under `effects.tolerated:`.
- `sig.effect.withheld-non-exhaustive` — some call the
  method reaches could not be resolved.
- `sig.effect.withheld-unclaimed-callee` — some call it
  reaches resolved, and nothing anywhere says what that
  callee does.
- `sig.effect.withheld-declared` — the method already carries
  an authored bound, or a label survives in the `≤` lane.
- `sig.effect.left-unreadable` — the target declaration
  already carries annotations, so nothing was written there.

One limit worth knowing: annotations ride on the signature
lines `sig-gen` proposes, so a method whose declaration is
already exactly right gets none. An up-to-date `sig/` is
therefore not annotated in place; the reader for those is
`rigor effects --pure`, and writing them is still a hand
edit.

With no `effects:` block in `.rigor.yml`, none of this runs
and the output is byte-for-byte what it was before.

The three `sig.generated.*` identifiers
(`sig.generated.new-file` / `new-method` / `tighter-return`)
are emitted as JSON fields under `--format=json` so CI
gating consumers can route them. Every `skipped` row is part
of the same payload, carrying its `sig.skipped.*` identifier
as `skip_reason`, so a method missing from your `sig/` has
its reason next to the rows that did emit. In text mode a
one-line stderr summary counts the skipped methods per
reason instead; stdout stays paste-clean.

## Recording a gap the generator cannot close

`sig-gen --diff` answers "is this declaration what the
implementation proves?" for every method it can type. The
answers it cannot give are the interesting ones: a
`tighter-return` you decided not to apply, a method it
skipped, a declaration with no `def` behind it at all. Each
of those is a hand-written type, and a hand-written type
that nobody wrote down a reason for is indistinguishable
from one nobody has looked at since.

The convention Rigor uses on its own `sig/` is a line in the
member's RBS comment:

```rbs
class Registry
  # sig-gen gap: #1234 — sig-gen types the body `untyped`
  # (the ivar has no inferred field type yet), so this
  # return is hand-written until it can prove one.
  def resolve: (String name) -> Entry
end
```

A `void` return needs no marker. `sig-gen` never proposes a
value for one: `void` says the return is not part of the
contract, and no inference synthesizes it, so a `void`
declaration is authored intent the way a parameter type is
([ADR-14](../adr/14-rbs-sig-generation.md) § "The
inference-vs-RBS contradiction rule").

Neither does a declaration the body proves as a literal.
`sig-gen` will not propose `"bot"` for a `def describe: ()
-> String` whose body is the string `"bot"`: the declared
type is your abstraction over that body, and pinning the
literal would rewrite a contract every sibling class shares.
A method no `.rbs` declares is unaffected — the literal is
still the strictest thing the body proves, and that is what
gets written.

A comment rather than a `%a{…}` annotation, for three
reasons: it stays out of the `rigor:v1:` directive namespace
(`docs/type-specification/rbs-extended.md`), no engine path
reads it, and `RBS::Parser` binds it to the member, so a
check can find it on the AST instead of scanning lines. The
issue number is the load-bearing half — it points at the
engine work that would let the generator answer, which is
the [ADR-14](../adr/14-rbs-sig-generation.md) rule that a
gap pushing you toward hand-written RBS is the more valuable
signal.

Nothing in the CLI requires this. It is a convention you can
gate in your own suite: parse `sig/**/*.rbs`, run the
generator, and fail on a declaration that is neither
generated-equivalent nor marked. Rigor's own gate is
`spec/rigor/sig_gen/provenance_spec.rb`
([ADR-107](../adr/107-checked-types-and-typeless-comments.md)
G3).

One case in that list is not a marker case at all. A
declaration with no `def` behind it may simply describe a
method Ruby generates — an `attr_*`, a `Data` member, one a
class macro defines at load — or it may be left over from a
`def` that was deleted or renamed, which nothing catches,
because `rigor check` and Steep both ask whether the
implementation matches `sig/` and never the converse.
Rigor's gate separates the two by asking its own
project index and then the loaded tree
([#839](https://github.com/rigortype/rigor/issues/839)).
That check requires the code under `sig/`, so it stays a
repository gate: `sig-gen` in your project is unchanged.

## What method shapes the generator covers

Slice-by-slice (each shipped via a CHANGELOG entry — this
list is the current state):

- **Plain instance `def foo`** of any parameter shape:
  required, optional, rest, trailing, keyword, keyword-rest,
  `...` forwarding and `&block`. The parameter list mirrors
  the runtime shape with `untyped` in every position (the
  observed union under `--params=observed`), and a block
  renders as `?{ (*untyped) -> untyped }`. Both new-method
  and tighter-return paths apply.
- **Singleton-side `def self.foo`** and
  `class << self; def foo; end`. Rendered as
  `def self.foo: ...`; matched against
  `Reflection.singleton_method_definition` for existing
  RBS.
- **`attr_reader` / `attr_writer` / `attr_accessor`** with
  literal Symbol arguments. The return type is the
  accumulated ivar type from `Scope#class_ivars_for`. A
  writer stores whatever its caller passes, so an
  `attr_writer` / `attr_accessor` ivar reads untyped.
  The accessor, and any other method returning that
  ivar, is skipped even beside a concrete write such as
  `@logger = Logger.new`, unless `--params=observed`
  types the constructor parameter the ivar is assigned
  from. The
  generator emits the long-form `def name: () -> T`
  spelling so the writer's merge path applies unchanged;
  existing short-form `attr_reader name: T` declarations
  are recognised as user-authored and never produce a
  duplicate `def` insertion.

Method shapes the generator does **not** cover yet:

- `define_method(:name) { ... }`.
- Methods whose body types as `Dynamic[top]` (the body
  inference cannot prove a useful return type).

These are tracked as ADR-14 follow-ups.

## The `--params` policy and ADR-5

The `--params=POLICY` flag controls how parameter positions
are spelled in the emitted RBS. There are three policies;
two are wired today, one is reserved.

| Policy | Behaviour |
| --- | --- |
| `untyped` (default) | Every parameter is spelled `untyped`. No inference-derived parameter contract is imposed on future callers. The user retains complete authorship over parameter typing. |
| `observed` | Collect argument types from every call site under `--observe=PATH...` (defaults to the configured `test_paths:`, or whichever of `spec/` and `test/` exist), union per parameter position, erase to RBS, emit the union. With no test root to observe, or a declared root that does not exist, sig-gen says so on stderr. |
| `observed-strict` | Reserved. Will additionally widen to capability roles (`_ToStr`, `_ToS`, …) once the role catalog ships. Currently rejected with a usage error. |

The default deliberately favours `untyped` because of
[ADR-5](../adr/5-robustness-principle.md)'s clause 2: a
method's parameter contract should be the **most permissive**
shape the body's logic justifies, not the most specific
shape the current callers happen to use. Locking in
`observed` would silently freeze "what the existing specs
happen to pass" as the contract, which is the precision /
adoption trade-off the chapter introduction hinted at.

`--params=observed` is the deliberate opt-in: you are
saying *"the union of what my callers pass today IS the
parameter contract I want."* That is a correctness-
preserving widening — every existing caller still passes —
but it does narrow the contract relative to `untyped`.

## Type aliases your project declares

When a proposal's type is a union whose members are exactly
the expansion of a `type` alias declared in your own
`sig/`, the alias name is what gets emitted. For a method
on `Rigor::Type::Combinator`, sig-gen emits

```
def hash_shape_keys: (untyped) -> ::Rigor::Type::t
```

rather than the twenty-two members `Rigor::Type::t`
expands to. The name is written in its absolute form so it
cannot rebind to a nearer constant of the same spelling.

This applies wherever sig-gen renders a type, not only to
returns: `--params=observed` parameter positions, `attr_*`
accessors, and `Data` / `Struct` members all fold the same
way. The `--format=json` payload carries the folded
spelling in its `rbs` field; `inferred_return` is the
carrier the engine computed and stays expanded.

The rule is member-set equality, so a proposal missing one
arm of the alias still prints in full — the alias names a
type the method cannot return, and claiming it would be
wrong rather than merely verbose.

A wrong alias name is worse than a long union: it is an RBS
claim you did not make. Four rules keep the fold from
guessing.

**Your aliases only.** The candidates come from your
configured `signature_paths:` (or `sig/` when you
configured none) — not from gems in your bundle, not from
an `rbs collection` tree, and not from core or stdlib RBS.
Core declares `Warning::category` as `:deprecated |
:experimental | :performance`; a project that never wrote
that alias does not get it in its proposals. A loaded
plugin's own signature directory is subtracted even when
you listed it in `signature_paths:` yourself — those
aliases are the plugin's vocabulary.

**Namespace proximity.** An alias is only offered to a
method whose owner is inside the alias's own namespace, and
the nearest such alias wins — most specific first, then
declaration order by (file, line, name). Without this,
`:positive | :negative` anywhere in a codebase would pick
up any alias that happens to name that pair.

**Unambiguous alias bodies only.** Some RBS forms reach the
renderer looking like something else: an intersection can
read as one of its members, a proc type as a bare `Proc`, a
nested alias as whatever it expanded to. An alias whose
body contains one of those is skipped, because a fold into
it would put a type in your signature that the method does
not return. Only class instances, singletons, literals,
unions, optionals, tuples and the `nil` / `bool` / `bot`
bases qualify.

**Unions only, non-generic only.** A `type name = String`
alias never rewrites an ordinary `String` return, and a
generic alias (`type boxed[T] = ...`) has no fixed member
set to match.

A project that declares no aliases gets byte-for-byte the
output it got before.

## RSpec-aware observations

When the observed test roots hold an RSpec suite, the
generator recognises three RSpec-shaped binding patterns
and uses them to type receivers that would otherwise
degrade to `Dynamic[top]`:

```ruby
RSpec.describe Calc do
  subject { Calc.new }         # binds :subject → Nominal[Calc]
  let(:other) { Calc.new }     # binds :other   → Nominal[Calc]

  it "..." do
    subject.greet("Alice")     # observed: Calc#greet receives String
    other.greet("Bob")         # observed: same
    described_class.new.add(1, 2)  # observed: Calc#add receives Integer, Integer
  end
end
```

The recogniser handles `RSpec.describe Foo`, bare
`describe Foo` (no `RSpec.` receiver), `subject { … }`,
`subject(:name) { … }`, `let(:name) { … }`, `let!(:name)`,
and `described_class.new(...)`. Same-name `let` bindings
across nested scopes are last-wins; the recogniser does not
re-implement RSpec's full scope rules — the typical
one-spec-file shape is the target.

A Minitest suite under `test/` is observed too, with no
recogniser of its own: a call whose receiver types to one
class counts. A receiver assigned in `setup` is the gap —
inside a `test_*` method it reads as `Foo | nil`, and such
a call is not observed yet
([#1389](https://github.com/rigortype/rigor/issues/1389)).

The recogniser is part of the generator itself; you do not
need to install `rigor-rspec` to benefit from it. If you
already use `rigor-rspec` for diagnostics, the two run side
by side without coordination.

## Safety: what `--write` will and will not do

- **Will** create new `*.rbs` files mirroring `lib/<path>.rb`'s
  layout (basename of `configuration.paths.first` stripped,
  placed under `configuration.signature_paths.first`).
- **Will** insert new method declarations just before a
  class declaration's closing `end` keyword, preserving
  every other byte of the file verbatim.
- **Will** append a new `class Foo … end` block when the
  target file does not declare the class yet.
- **Will not** touch files outside the configured signature
  tree.
- **Will not** replace an existing method declaration
  unless `--overwrite` is set AND the candidate is a
  `tighter-return`. Without `--overwrite`, existing
  declarations are user-authored and the new method is
  silently skipped.
- **Will** replace an existing method declaration that is a
  stale copy of the method's inline declaration
  (`inline-update`), with or without `--overwrite`: what
  changed is what you wrote inline, a return inferred from
  the body keeps its `sig/` spelling, and annotations and
  comments already on the old declaration are kept.
- **Will not** touch `attr_reader` / `attr_writer` /
  `attr_accessor` declarations in existing RBS — those are
  always treated as user-authored.

The recommended workflow is `--diff` first, review, then
`--write` (or `--write --overwrite` if you decided that
the tightening is intentional).

### When tightening is *probably* incomplete inference

The strict-subtype check is a *necessary* condition for
emitting a tighter-return — it's not a sufficient signal
that the existing RBS is wrong. Slice 1's body-typing path
only inspects the implicit-return expression, so a method
like:

```ruby
def find(key)
  return nil unless @table.key?(key)
  @table[key]
end
```

types as the return of `@table[key]` alone. If the existing
RBS declares `(K) -> V | nil`, the inferred `V` looks
strictly tighter — but it's tighter for the wrong reason
(the `nil` branch is unreachable in the body-typer's eyes,
not in the runtime's). Applying it would silently delete
the `nil` arm.

**Heuristic**: when a tightening DROPS union members that
the existing RBS declares — `T | nil → T`, `false | true →
true`, `Float | Integer → Float`, `Array[T] → [T]` — treat
it as a contradiction signal, not a precision win, and
leave the existing RBS alone. The generator does not yet
classify these automatically; the `--diff` review step is
where the human gate sits.

For `rigor`'s own `sig/` tree this is the load-bearing
policy: every tighter-return that contradicts an existing
declaration is suspected incomplete inference until proven
otherwise.

## Putting it together

A typical iteration on a new file:

```sh
# 1. See what Rigor would propose.
rigor sig-gen lib/calc.rb

# 2. Run with the observed-params policy to use the test
#    roots (`test_paths:`) as a parameter-type signal.
rigor sig-gen --params=observed lib/calc.rb

# 3. Compare against the current sig/ tree.
rigor sig-gen --params=observed --diff lib/calc.rb

# 4. Apply.
rigor sig-gen --params=observed --write lib/calc.rb

# 5. Re-run rigor check to confirm no regressions.
rigor check
```

The five steps map to the five ADR-14 slices the command
is built from. If any step shows results you didn't expect,
the diagnostic the analyzer would emit for the same code is
the source of truth — `sig-gen` is a downstream consumer of
inference, not a separate analysis.

## Limits today

- A block parameter always renders as the lenient
  `?{ (*untyped) -> untyped }`; a typed block signature
  waits on the engine tracking yield shapes end-to-end.
- `define_method` and `Data.define`-specific emission are
  deferred follow-ups (`Data.define`-derived readers come
  through if a method body exists).
- The strict-subtype check uses gradual-mode acceptance
  today; the `:strict` mode reserved on
  `Inference::Acceptance` arrives in a follow-up.
- Round-trip through `RBS::Writer` is not used (it drops
  comments by upstream design); the generator's
  byte-range insertion preserves untouched declarations
  verbatim but cannot preserve comments interleaved
  *inside* a touched declaration's range.

These are the ADR-14 deferred items; the design rationale
is in [`docs/adr/14-rbs-sig-generation.md`](../adr/14-rbs-sig-generation.md).
