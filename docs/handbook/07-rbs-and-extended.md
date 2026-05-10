# RBS and `RBS::Extended`

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
- The method is just a wrapper around a method that already
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

`RBS::Extended` lives at
[`docs/type-specification/rbs-extended.md`](../type-specification/rbs-extended.md).
The five directives:

| Directive | Says |
| --- | --- |
| `%a{rigor:v1:return: <type>}` | Tighten the method's return type. |
| `%a{rigor:v1:param: <name> is <type>}` | Tighten a parameter's accepted type at the call site, AND narrow the local in the body. |
| `%a{rigor:v1:assert: <name> is <type>}` | After this method returns, the named local in the caller's scope is `<type>`. |
| `%a{rigor:v1:predicate-if-true: <name> is <type>}` | When this method returns truthy, the named local in the caller's scope is `<type>`. (Symmetric `predicate-if-false`.) |
| `%a{rigor:v1:assertion-on: <name>}` | Mark the method as an assertion gate — the body's last expression's type becomes a fact about `<name>`. |

The `<type>` slot accepts:

- **RBS class names** — `String`, `Integer`, `::Foo::Bar`.
- **Imported refinement names** —
  `non-empty-string`, `lowercase-string`, `numeric-string`,
  `int<5, 10>`, `non-empty-array[Integer]`, `literal-string`,
  …
- **Negation `~T`** — `~lowercase-string` means
  "non-lowercase-string."

## Refinement names

The full catalogue is in
[`docs/type-specification/imported-built-in-types.md`](../type-specification/imported-built-in-types.md).
A short reference:

| Family | Names |
| --- | --- |
| Empty / non-empty | `non-empty-string`, `non-empty-array[T]`, `non-empty-hash[K, V]` |
| Integer ranges | `positive-int`, `non-negative-int`, `negative-int`, `non-positive-int`, `non-zero-int`, `int<min, max>` |
| String predicates | `lowercase-string`, `uppercase-string`, `numeric-string`, `decimal-int-string`, `octal-int-string`, `hex-int-string`, `literal-string` |
| Paired complements | `non-lowercase-string`, `non-uppercase-string`, `non-numeric-string` |
| Composed | `non-empty-lowercase-string`, `non-empty-uppercase-string`, `non-empty-literal-string` |

## Worked example: an assertion gate

```rbs
class Validator
  %a{rigor:v1:assert: x is non-empty-string}
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

## Worked example: a type predicate

```rbs
class Range
  %a{rigor:v1:predicate-if-true: value is Integer}
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

You **cannot** put them inside a `.rb` file. The directives
only fire when read from RBS — that is a design choice (see
ADR-5, the robustness principle: strict on returns, lenient
on parameters).

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

## Coming from PHPStan? The `@phpstan-assert` family

If you are familiar with PHPStan's PHPDoc annotations,
Rigor's `RBS::Extended` directives map directly onto the
post-return / conditional narrowing primitives PHPStan calls
"asserts" and "type-specifying functions." The behaviour is
identical:

> "After this method returns, the named argument is `T`."

That is `@phpstan-assert` in PHPStan and
`%a{rigor:v1:assert:}` in Rigor.

| PHPStan PHPDoc | Rigor RBS::Extended | Effect |
| --- | --- | --- |
| `@phpstan-assert T $x` | `%a{rigor:v1:assert: x is T}` | After this method returns normally, the caller's `x` is `T`. |
| `@phpstan-assert-if-true T $x` | `%a{rigor:v1:predicate-if-true: x is T}` | If this method returns truthy, the caller's `x` is `T`. |
| `@phpstan-assert-if-false T $x` | `%a{rigor:v1:predicate-if-false: x is T}` | If this method returns falsey, the caller's `x` is `T`. |
| `@phpstan-assert !T $x` | `%a{rigor:v1:assert: x is ~T}` | After this method returns, the caller's `x` is **not** `T` (negation form). |
| `@phpstan-assert-if-true !T $x` | `%a{rigor:v1:predicate-if-true: x is ~T}` | Conditional negation. Symmetric with `predicate-if-false`. |

Worked example — the canonical "assertNotNull" pattern from
PHPStan's docs:

```rbs
# sig/asserts.rbs
class Asserts
  %a{rigor:v1:assert: x is ~nil}
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

Self-targeted forms are supported too — the PHPStan
analogue would be a method on `$this` that narrows
`$this`. Use `target self`:

```rbs
class Connection
  %a{rigor:v1:assert: self is Connected}
  def assert_connected!: () -> void
end
```

Rigor's directive grammar covers what PHPStan ships in the
`@phpstan-assert*` family. The directives **only fire from
RBS** (per ADR-5: strict on returns, lenient on parameters);
in PHPStan-land you can also write `@phpstan-assert` in
PHPDoc directly above the function — Rigor's equivalent is
the same RBS file's `def` line.

If you need plugin-side equivalents (when the assertion is
recognised by **call shape** rather than by sig — PHPStan's
"Type-Specifying Extensions"), see
[Chapter 9](09-plugins.md). The plugin contract surfaces
the same `Fact(target_kind: :self)` and
`Fact(target_kind: :parameter)` carriers that the directives
use, so a plugin author writes the equivalent of a PHPStan
`StaticMethodTypeSpecifyingExtension` from Ruby.

## When RBS cannot help — the plugin escape hatch

When a method's behaviour depends on the **shape of its
arguments at runtime** (`Lisp.eval([:+, 1, 2])` returns
Integer, but `Lisp.eval([:<, 1, 2])` returns bool), no RBS sig
can express the relationship. That is what plugins are for —
see [Chapter 9](09-plugins.md) and the
[examples/](../../examples/README.md) directory.

## What's next

Chapter 8 covers the rule catalogue — what each diagnostic
means, when it fires, and how to suppress it when it is wrong
or noisy.
