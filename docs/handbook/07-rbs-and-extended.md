# RBS and RBS::Extended

When Rigor's inference cannot prove a type, the next escape
hatch is RBS — Ruby's signature language. When RBS cannot
express the precise contract you want, `RBS::Extended` adds a
small annotation surface on top.

This chapter covers both, in the order you usually reach for
them.

## When you need RBS

You probably need to add an RBS file when:

- The method body's return type depends on an external gem
  Rigor's bundled stdlib does not cover.
- You want `call.argument-type-mismatch` to fire on
  argument-shape errors (in-source `def` does NOT enforce
  parameter contracts; only RBS-declared methods do).
- You want `def.return-type-mismatch` to fire when a body's
  inferred return drifts from the declared return.
- A future RBS-aware tool (Steep, ruby-lsp) will read the
  same file and benefit from the contract.

You probably do **not** need RBS when:

- The method is private to your project, the body is short,
  and Rigor already infers the right return type.
- The method is a wrapper around a method that already
  has a sig (Rigor walks the body and propagates).

## A first sig

In a fresh project:

```text
my-app/
├── lib/
│   └── slug.rb
└── sig/
    └── slug.rbs       # ← your sig
```

```ruby
# lib/slug.rb
class Slug
  def normalise(id)
    id.downcase.gsub(/\s+/, "-")
  end
end
```

```rbs
# sig/slug.rbs
class Slug
  def normalise: (String) -> String
end
```

Drop the `.rbs` file in `sig/` and Rigor picks it up
automatically — no `.rigor.yml` change required. The default
config has `signature_paths: [sig]`.

After that, this code:

```ruby
Slug.new.normalise(42)
```

fires `call.argument-type-mismatch`: `42` is an Integer, the
parameter is `String`.

## When the RBS shape is too wide

The Slug example's runtime always returns a non-empty,
lowercase string — but the RBS sig only says `String`. If you
want Rigor to know the narrower fact, attach an `RBS::Extended`
annotation:

```rbs
class Slug
  %a{rigor:v1:return: non-empty-lowercase-string}
  def normalise: (String) -> String
end
```

Now:

```ruby
s = Slug.new.normalise("Hello World")
# s: non-empty-lowercase-string
s.empty?     # Constant<false>  — proven
s.size       # positive-int     — proven
s == "hello-world"  # bool — equality narrowing applies
```

The `.rbs` file is **still valid RBS** — `%a{...}` is the RBS
annotation syntax. Steep / typeprof / ruby-lsp see a comment;
Rigor sees a tightening.

## The directive grammar

There are seven per-method directives, and they divide by
*when* the fact they carry becomes true: `return:` and `param:`
retype the signature itself, `predicate-if-true` /
`predicate-if-false` narrow a variable across the branches of a
condition, and `assert` / `assert-if-true` / `assert-if-false`
narrow one after the call returns. Each is one
`%a{rigor:v1:…}` annotation above the `def` it refines; they
stack, and order does not matter.

The exhaustive table — every directive, its payload syntax, and
what the `<type>` slot accepts (RBS class names, refinement
payloads, the parameterised and bounded forms, and where `~T`
negation is and is not allowed) — is
[manual — RBS::Extended annotations](../manual/16-rbs-extended-annotations.md#per-method-directives);
the normative rules for conflicts, merging and provenance are
[`docs/type-specification/rbs-extended.md`](https://github.com/rigortype/rigor/blob/master/docs/type-specification/rbs-extended.md).
The rest of this chapter works through the directives one
example at a time.

## Refinement names

The full catalogue is in
[`docs/type-specification/imported-built-in-types.md`](https://github.com/rigortype/rigor/blob/master/docs/type-specification/imported-built-in-types.md).
A short reference:

| Family | Names |
| --- | --- |
| Empty / non-empty | `non-empty-string`, `non-empty-array[T]`, `non-empty-hash[K, V]` |
| Integer ranges | `positive-int`, `non-negative-int`, `negative-int`, `non-positive-int`, `non-zero-int`, `int<min, max>` |
| String predicates | `lowercase-string`, `uppercase-string`, `numeric-string`, `decimal-int-string`, `octal-int-string`, `hex-int-string`, `literal-string` |
| Paired complements | `non-lowercase-string`, `non-uppercase-string`, `non-numeric-string` |
| Composed | `non-empty-lowercase-string`, `non-empty-uppercase-string`, `non-empty-literal-string` |
| Shape projections | `pick_of[T, K]`, `omit_of[T, K]`, `partial_of[T]`, `required_of[T]`, `readonly_of[T]` — derive new `HashShape` / `Tuple` carriers from existing ones. See [chapter 4 § "Deriving new shapes"](04-tuples-and-shapes.md#deriving-new-shapes--pick_of--omit_of--partial_of--required_of--readonly_of). |

## Declaring conformance — `conforms-to`

The directives above attach to a `def`. One more attaches to a
`class` / `module` declaration and asserts that the whole class
satisfies a named structural interface:

```rbs
%a{rigor:v1:conforms-to _RewindableStream}
class MyBuffer
  def read: (Integer) -> String
  def rewind: () -> void
end
```

If `MyBuffer` is missing a method the `_RewindableStream`
interface requires, Rigor reports
`rbs_extended.unsatisfied-conformance`; a class that satisfies
the interface is silent.

The reason to reach for this is that Rigor already checks
structural compatibility *implicitly*, wherever a value flows
into a position that needs a structural interface — so a class
nobody currently passes anywhere is never checked at all.
`conforms-to` turns the contract into a design assertion that
holds whether or not a call site exercises it, which is what a
library wants when the structural shape is the point. It is
purely additive: nothing that type-checked before stops doing
so because you added it. The stacking and diagnostic semantics
are in
[manual — `conforms-to`](../manual/16-rbs-extended-annotations.md#conforms-to--a-checked-structural-contract).

## Bounding what a method *does* — effect envelopes

Every directive so far describes what a method returns. One
describes what it *does*:

```rbs
class UserRepository
  %a{rigor:v1:effect io.db}
  def find: (Integer) -> User

  %a{pure}
  def slug: (String) -> String
end
```

`%a{rigor:v1:effect io.db}` says "this method may touch the
database, and nothing else the vocabulary names". `%a{pure}`
says "nothing at all" — it is rbs' own purity annotation, the
one Steep already reads, so Rigor honours the spelling that
exists rather than inventing a synonym. Both tolerate mutating
objects the method itself allocated and never let out, so a
`%a{pure}` method may still build and fill a local array.

The payload is a comma-separated list of bare labels
(`%a{rigor:v1:effect io.db, nondet.time}`), from the vocabulary
in
[effect-labels.md](https://github.com/rigortype/rigor/blob/master/docs/type-specification/effect-labels.md).
Write the annotation on a `class` or `module` declaration
instead and it applies to every method of that class —
reopenings and `attr_writer`-generated methods included, but
never to subclasses. A method that carries its own envelope
keeps it; nearest wins.

The bound covers the method's whole *code*, including what it
calls. A `find` declared `io.db` that reaches an HTTP request
through a helper exceeds its envelope, and Rigor says so — on
the Ruby `def`, naming the route it took:

```text
lib/user_repository.rb:12: warning: Method UserRepository#find
performs io.net.http (Net::HTTP.get via PaymentGateway#charge),
but is declared %a{rigor:v1:effect io.db} at sig/repo.rbs:3,
so io.net.http exceeds the envelope.
```

Two things it will not do. It never reports an effect it only
*suspects*: a call Rigor could not resolve makes the summary
read "and possibly more", and possibly is not a finding. And
none of this happens unless you asked for it — the check needs
an `effects:` block in `.rigor.yml`, so an `%a{pure}` already
sitting in your signatures for Steep's benefit stays inert
until you opt in. Set `effects.check: false` to keep the
`rigor effects` report and its snapshot while silencing the
diagnostic. Inert is not the same as unmentioned: annotations
with no `effects:` block earn one
[`effect.annotations-unchecked`](../manual/04-diagnostics.md#rule-effect-annotations-unchecked)
`:info` per run, so a bound nobody checks never goes unnoticed.

Misspell a label and the annotation does not narrow to the part
Rigor recognised — the **whole** tag reads as unbounded, so a
typo can never turn into findings on correct code. That would
be a silent loss of a contract you thought you had, so where
the spelling is evidently meant to be a label Rigor says so:
[`effect.unknown-label`](../manual/04-diagnostics.md#rule-effect-unknown-label),
at the line you wrote it on, naming the nearest real label.
A word that resembles nothing in the vocabulary stays silent —
you may be opening a root of your own.

The whole feature — the label vocabulary, the committed effect
snapshot, and `rigor effects` itself — is
[ADR-103](https://github.com/rigortype/rigor/blob/master/docs/adr/103-effect-labels.md); start with
[`rigor effects`](../manual/02-cli-reference.md#rigor-effects).

## Worked example: an assertion gate

```rbs
class Validator
  %a{rigor:v1:assert x is non-empty-string}
  def assert_non_empty: (String x) -> void
end
```

```ruby
def configure(host)
  Validator.new.assert_non_empty(host)
  # host: non-empty-string after this call
  host.size   # positive-int — proven
end
```

The runtime side is whatever `assert_non_empty` does (raise
on empty, log, ...) — Rigor only reads the directive.

## Worked example: asserting a negative

An assertion payload can be negated with `~T`, which is how you
model the "this is definitely not nil any more" helper every
codebase grows:

```rbs
# sig/asserts.rbs
class Asserts
  %a{rigor:v1:assert x is ~nil}
  def self.not_nil: (untyped x) -> void
end
```

```ruby
# lib/configure.rb
def configure(maybe)
  Asserts.not_nil(maybe)
  # maybe: (~nil), so .upcase resolves on the narrowed type
  maybe.upcase
end
```

The target can also be the receiver itself — name it with
`self`, and the fact lands on the object the method was called
on:

```rbs
class Connection
  %a{rigor:v1:assert self is Connected}
  def assert_connected!: () -> void
end
```

If PHPDoc's `@phpstan-assert` family is your mental model for
all of this, the reading is nearly one-for-one; the mapping
table is in
[appendix: Coming from PHPStan](appendix-phpstan.md#the-phpstan-assert-family).

## Worked example: a type predicate

```rbs
class Range
  %a{rigor:v1:predicate-if-true value is Integer}
  def integer?: (untyped value) -> bool
end
```

```ruby
def double_if_int(value)
  if (1..10).integer?(value)
    # value: Integer  in the truthy branch
    value * 2
  else
    value
  end
end
```

This is the supported way to teach Rigor about a custom
type-predicate method that the engine's built-in `is_a?` /
`nil?` rules cannot recognise.

## Worked example: parameter override

```rbs
class Slug
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (String id) -> String
end
```

This has two effects:

1. **Call-site checking.** `Slug.new.normalise("")` is now a
   `call.argument-type-mismatch` because `Constant<"">` does
   not satisfy `non-empty-string`.
2. **Body-side narrowing.** Inside the method body of
   `normalise`, the parameter `id` is `non-empty-string`. So
   `id.empty?` reduces to `Constant<false>` and `id.size`
   reduces to `positive-int`.

## When you need a parameter override the runtime cannot enforce

Sometimes the runtime function does NOT raise on bad input —
it returns nil, returns a default, or swallows the error.
Rigor's `param:` directive still tightens the call-site
contract:

```rbs
class FileLoader
  %a{rigor:v1:param: path is non-empty-string}
  def load: (String path) -> String?
end
```

`FileLoader.new.load("")` fires `call.argument-type-mismatch`
even though at runtime `load` would fail gracefully. The
directive expresses **what callers should pass**, not what
the body enforces.

## Where annotations belong

Put `RBS::Extended` annotations on the same `def` they refine,
inside the same `.rbs` file. Group them above the method:

```rbs
class Slug
  %a{rigor:v1:return: non-empty-string}
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (String id) -> String
end
```

You can also write them **in a `.rb` file**, as rbs-inline
`# @rbs %a{…}` comments:

```rb
# rbs_inline: enabled

class Slug
  # @rbs %a{rigor:v1:return: non-empty-string}
  # @rbs id: String
  # @rbs return: String
  def normalise(id) = id.strip
end
```

`%a{}` is *rbs-inline's own* grammar, not a Rigor dialect, and
the annotation reaches Rigor through the ordinary path: the
rbs-inline writer copies it verbatim onto the signature it
generates, and that signature joins the same RBS environment
your `sig/` tree lands in. So this is not a per-directive
feature — every `RBS::Extended` directive is read from the same
annotation object whichever buffer it arrived in — the effect
envelopes above (`%a{pure}`, `%a{rigor:v1:effect …}`) included.
Reading them requires the rbs-inline library, which Rigor
ingests by default when it is installed
([ADR-93](https://github.com/rigortype/rigor/blob/master/docs/adr/93-default-rbs-inline-ingestion.md)).

What Rigor does **not** offer is a Rigor-only comment dialect —
there is no `# rigor:effect` directive and no file pragma. The
`# rigor:` comment family stays suppression-only (`disable`,
`disable-file`). Application code never has to carry
Rigor-specific syntax ([ADR-0](https://github.com/rigortype/rigor/blob/master/docs/adr/0-concept.md)); an
upstream annotation form you may use if you want one is a
different thing from a requirement.

## Inline RBS in Ruby source — the `rigor-rbs-inline` plugin

A separate, opt-in plugin lets you write method types directly
above the `def` in your Ruby file, using the
[rbs-inline](https://github.com/soutaro/rbs-inline) comment
vocabulary upstream defines:

```rb
# rbs_inline: enabled

class AscDesc
  # @rbs asc_or_desc: :asc | :desc
  def ascdesc(asc_or_desc)
    asc_or_desc
  end
end

AscDesc.new.ascdesc(:bad)
# => error: argument type mismatch at parameter `asc_or_desc' of
#    `ascdesc' on AscDesc: expected :asc | :desc, got :bad
```

The `# @rbs name: T` doc-style annotation, the `#: () -> T`
inline method-type comment, `# @rbs return: T`, attribute `#:`
casts, `# @rbs @ivar: T`, `# @rbs override`, and `# @rbs!` raw
RBS embedding all work — anything upstream rbs-inline accepts
flows through to Rigor's RBS environment as if you had hand-
written the equivalent `.rbs` file.

This is **not** RBS::Extended. The `# @rbs` comments are
upstream rbs-inline's grammar; the plugin transcribes them to
ordinary RBS at env build. RBS::Extended `%a{rigor:v1:…}`
directives, by contrast, are Rigor-only annotations that live
in `.rbs` files (see the rest of this chapter for those).

To enable it, add the plugin gem to your bundle and list it:

```yaml
# .rigor.yml
plugins:
  - rigor-rbs-inline
```

Per file, opt in with the upstream `# rbs_inline: enabled`
magic comment at the top — files without it are unaffected.

Notes:

- The core `rigortype` analyzer stays zero-runtime-dependency
  (ADR-0). The `rbs-inline` upstream library is a dependency
  of the plugin gem, not of the core, so projects that don't
  opt in pay nothing.
- A bare top-level `def` produces no RBS output through
  upstream rbs-inline. Wrap method definitions in a class or
  module when you need the annotation to take effect.
- A failed rbs-inline parse surfaces as a
  `source-rbs-synthesis-failed` `:info` diagnostic; the file
  falls back to no inline-RBS contribution and analysis
  continues.

Full plugin documentation, configuration options (including
the `require_magic_comment: false` host-context override the
browser playground uses), and the caching contract:
[`plugins/rigor-rbs-inline/README.md`](https://github.com/rigortype/rigor/blob/master/plugins/rigor-rbs-inline/README.md).

## Falling back to `untyped`

When a method's signature involves a type RBS cannot express,
the conservative thing to do is `untyped`:

```rbs
def deserialize: (String) -> untyped
```

`untyped` is a contract-free hatch — every method exists on
it, every argument shape is acceptable. Rigor's diagnostics
stay silent on `untyped` receivers. Use it for legitimately
dynamic boundaries (deserialisation, `eval`, plugin entry
points). The static analysis you lose is made up by the
honesty of admitting "this could be anything."

## When RBS cannot help — the plugin escape hatch

When a method's behaviour depends on the **shape of its
arguments at runtime** (`Lisp.eval([:+, 1, 2])` returns
Integer, but `Lisp.eval([:<, 1, 2])` returns bool), no RBS sig
can express the relationship. That is what plugins are for —
see [Chapter 9](09-plugins.md) and the
[examples/](https://github.com/rigortype/rigor/blob/master/examples/README.md) directory.

## What's next

Chapter 8 is about reading a diagnostic — what each rule
family claims, why one fires when you did not expect it, and
which layer to reach for when you want it quieter.
