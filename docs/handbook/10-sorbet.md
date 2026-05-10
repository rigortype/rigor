# Coexisting with Sorbet

If your project already uses [Sorbet](https://sorbet.org/),
the [`rigor-sorbet`](../../examples/rigor-sorbet/) plugin
lets Rigor read your existing `sig` blocks, RBI files, and
`T.let` / `T.cast` / `T.must` / `T.unsafe` assertions as type
sources. You do not have to rewrite anything in RBS to start
running `rigor check` alongside `srb tc`.

This chapter is for users arriving from a Sorbet-using
project. If you have never used Sorbet, you can skip it; the
core handbook material in chapters 1–9 covers Rigor's native
RBS-based path.

## What gets translated

Given a method preceded by a `sig` block:

```ruby
class Slug
  extend T::Sig

  sig { params(name: String).returns(String) }
  def normalise(name)
    name.downcase.gsub(/\s+/, "-")
  end

  sig { returns(Integer) }
  def self.default_length
    32
  end
end
```

Rigor lifts the parsed sig at every call site, so chained
calls resolve through the analyzer's normal dispatch:

```ruby
slug = Slug.new
slug.normalise("Alice").upcase  # ✓ String#upcase resolves
Slug.default_length.even?       # ✓ Integer#even? resolves
```

No `.rbs` file required. The plugin walks every Ruby file
under `paths:` (and every `.rbi` file under `sorbet/rbi/` —
see "RBI files" below), pairs each `sig { ... }` block with
the `def` immediately following it, and contributes the
return type at the matching call sites.

## The Sorbet type vocabulary

The plugin translates the dense middle of Sorbet's type DSL.
Most everyday sigs land precisely; rare or
class-introspection-heavy forms degrade to `Dynamic[Top]`.

| Sorbet form              | Rigor representation                     |
| ------------------------ | ---------------------------------------- |
| `Integer` etc.           | `Nominal["Integer"]`                     |
| `::Foo::Bar`             | `Nominal["Foo::Bar"]`                    |
| `T.untyped`              | `Dynamic[Top]`                           |
| `T.anything`             | `Top`                                    |
| `T.noreturn`             | `Bot`                                    |
| `T.nilable(X)`           | `Union[X, Constant<nil>]`                |
| `T.any(A, B, ...)`       | `Union[A, B, ...]`                       |
| `T.all(A, B, ...)`       | `Intersection[A, B, ...]`                |
| `T::Boolean`             | `Union[Constant<true>, Constant<false>]` |
| `T::Array[E]`            | `Nominal["Array", [E]]`                  |
| `T::Hash[K, V]`          | `Nominal["Hash", [K, V]]`                |
| `T::Set[E]`              | `Nominal["Set", [E]]`                    |
| `T::Range[E]`            | `Nominal["Range", [E]]`                  |
| `T::Enumerable[E]`       | `Nominal["Enumerable", [E]]`             |
| `T::Class[T]`            | `Singleton[T-class-name]` (lossy)        |
| `T.class_of(C)`          | `Singleton[C]`                           |
| `[A, B]` (tuple in sig)  | `Tuple[A, B]`                            |
| `{a: A, b: B}`           | `HashShape{a: A, b: B}` (closed)         |

Anything outside this table — `T.proc`, `T.attached_class`,
`T.self_type`, `T.type_parameter`, `T::Struct` / `T::Enum`
subclasses — silently degrades to `Dynamic[Top]` for now.

## Inline type assertions

Sorbet's `T.let` / `T.cast` / `T.must` / `T.unsafe`
expressions are recognised at every call site, not only inside
`sig` blocks:

```ruby
counter = T.let(0, Integer)        # widens Constant<0> to Integer
counter.even?                       # ✓ Integer#even? resolves

T.cast(some_value, String).upcase   # ✓ String#upcase resolves

maybe = T.let(nil, T.nilable(Integer))
T.must(maybe).bit_length            # ✓ nil stripped → Integer
                                     #   then Integer#bit_length resolves

T.unsafe(opaque).any_method_at_all  # ✓ silenced — return is Dynamic[Top]
```

`T.must_because(expr, "explanation")` is recognised as an
alias of `T.must` — the static behaviour is identical (strip
`nil`); the second-argument string is informational only.

`T.reveal_type(expr)` returns `expr` unchanged at runtime AND
surfaces the inferred static type as a
`plugin.sorbet.reveal-type` `:info` diagnostic at the call
site, so chained calls keep working while you eyeball what
the analyzer sees:

```ruby
n = T.let(3, Integer)
T.reveal_type(n).even?  # info: T.reveal_type inferred type: Integer
                        # ✓ Integer#even? still resolves
```

`T.assert_type!(expr, T)` is `T.cast` plus a static subtype
check. The call returns the asserted type so chained calls
resolve through it; if the inferred type is provably
incompatible (`Inference::Acceptance.accepts(...)` returns
`:no`), the plugin emits `plugin.sorbet.assert-type-mismatch`
as `:error`. Gradual consistency rules apply — `Dynamic[top]`
inferred types and `:maybe`-compatible shapes are silenced
because the runtime check covers them.

```ruby
T.assert_type!("hello", Integer)  # error: provably incompatible
T.assert_type!(some_obj, String)  # silent: trust the user
```

`T.bind(self, T)` narrows `self` to `T` for the rest of the
current scope (typically a block body):

```ruby
arr.each do |x|
  T.bind(self, MyHelper)
  do_something(x)  # ✓ self is now MyHelper for the rest of this block
end
```

The narrowing is implemented via the engine's plugin-side
`post_return_facts` wiring — the same substrate any future
PHPStan-style Type-Specifying Extension plugin would use to
narrow argument variables after a custom assertion call.

`T.bind` rejects non-`self` first arguments silently (matches
Sorbet's contract — bind is self-only).

## RBI files

The plugin walks `sorbet/rbi/**/*.rbi` recursively by default
and treats each `.rbi` as Ruby source. The standard Tapioca
subdirectories (`gems/`, `annotations/`, `dsl/`, `shims/`)
all participate as a side effect of recursing into the parent
root. Override the location via `config.rbi_paths:` in
`.rigor.yml`, or set it to `[]` to opt out:

```yaml
plugins:
  - gem: rigor-sorbet
    config:
      rbi_paths: []                              # disable RBI loading
      # rbi_paths: ["sorbet/rbi", "vendor/rbi"]  # add a vendored tree
```

Project sigs (`.rb` files under `paths:`) and RBI sigs
(`.rbi` files under `rbi_paths:`) feed the same per-run
catalog, so a method declared in either source resolves the
same way at the call site.

## `# typed:` sigils

The plugin reads Sorbet's `# typed:` magic comment from the
top of each file. `# typed: ignore` files are skipped during
catalog harvest — sigs in those files are not recorded, so
the plugin contributes nothing for methods declared there.
Every other level (`false` / `true` / `strict` / `strong`)
records sigs identically; per-call-site enforcement (e.g.,
only firing `T.let` recognition in `# typed: true`+ files) is
deferred to a future slice.

Sorbet-strict's "every method must have a sig" requirement
and strong-mode's `T.untyped` rejection are intentionally NOT
mirrored. Those checks live with `srb tc`. Rigor's own
`severity_profile` setting in `.rigor.yml` covers the
analogous filtering.

## Tapioca DSL — the mixin pattern

Tapioca's standard DSL RBI shape declares sigs on a generated
module that is `include`d / `extend`ed into the host class:

```rbi
class Post
  include GeneratedAttributeMethods
  module GeneratedAttributeMethods
    sig { returns(::String) }
    def body; end
  end
end
```

The plugin records the sig under the module's qualified name
during the walk and lifts it to the host class at lookup
time. So `post.body` correctly resolves through
`Post::GeneratedAttributeMethods#body` — no manual
flattening required, and the same trick works for
hand-written shims under `sorbet/rbi/shims/` and community
annotations under `rbi-central`.

`extend M` correctly lifts `M`'s instance methods to the
extending class's singleton side, matching Ruby's runtime
behaviour:

```rbi
class Post
  extend GeneratedClassMethods
  module GeneratedClassMethods
    sig { params(id: Integer).returns(Post) }
    def find(id); end
  end
end
```

`Post.find(42)` resolves through the extended module's
instance side.

## `T.absurd` exhaustiveness

`T.absurd(x)` is Sorbet's idiom for case/when exhaustiveness:
"if I got here, the type system has lost the plot." The
plugin treats every `T.absurd` call as `Bot` (the empty
type — no possible value) AND raising, so the engine's
existing flow analysis treats code after the call as
unreachable:

```ruby
case x
when A then handle_a(x)
when B then handle_b(x)
else
  T.absurd(x)  # asserts the else branch is unreachable
end
```

When the discriminant is fully exhausted, the `T.absurd`
call sits in dead code and contributes nothing. When a case
branch is missing, the discriminant's type at the `T.absurd`
call still has admissible inhabitants, and the plugin
surfaces `plugin.sorbet.absurd-reachable` as a warning:

```text
demo.rb:42:5: warning: `T.absurd` is reachable: the discriminant did not
                       narrow to `T.noreturn`. Either add the missing case
                       branch above the `else`, or remove the `T.absurd(...)` call.
                       [plugin.sorbet.absurd-reachable]
```

The detection's accuracy follows Rigor's flow-sensitive
narrowing — `is_a?` / `kind_of?` / `nil?` work precisely;
narrowing over symbol enums is less precise as of v0.1.3,
so fully-exhausted symbol cases may emit false-positive
warnings until the engine's case narrowing improves.

## Tier ordering — what wins on conflict

When a method has both a Sorbet `sig` and an RBS sig, RBS
wins. Sorbet sigs sit at Rigor's plugin tier:

1. **Precision tiers** — constant fold, shape dispatch,
   block fold, etc.
2. **Plugin contributions** — including `rigor-sorbet`'s
   sig and assertion translations.
3. **RBS-backed dispatch** — project `sig/`,
   `RBS::Inline`, bundled stdlib.
4. **Dependency-source inference** (ADR-10's opt-in walker).
5. **User-class fallback** (`Object` / `Class` ancestors).

The contribution merger (a v0.1.0 substrate documented in
[`docs/internal-spec/flow-contribution-merger.md`](../internal-spec/flow-contribution-merger.md))
keeps RBS authoritative on conflict — the Sorbet sig is
allowed to refine but not contradict it. Users who want
their Sorbet sig to override should remove the conflicting
RBS, not the other way around. The reverse direction
(Sorbet wins) would let third-party-DSL annotations
override authored RBS, which inverts the trust model.

## Migration patterns

The plugin is designed for **gradual coexistence**, not a
forced migration. Three common shapes:

1. **Run both static checkers side by side.** `srb tc`
   keeps producing its diagnostics; `rigor check`
   produces its own. They overlap on shape errors and
   complement each other on what each finds — Sorbet
   covers `T.let` / `T.cast` / RBI more deeply; Rigor
   covers literal-string narrowing, refinement carriers,
   plugin DSLs, and dependency-source inference.
2. **Sorbet for sigs, Rigor for narrowing.** Authoritative
   sigs stay in `sig { ... }` blocks (or the
   sorbet-runtime-friendly RBI tree); Rigor reads them as
   input and adds its own narrowing on top.
3. **Sorbet → RBS over time.** New code lands as RBS;
   existing Sorbet sigs stay until the surrounding
   subsystem changes. The plugin keeps running while the
   Sorbet surface shrinks.

## What the plugin doesn't replace

Rigor's `rigor-sorbet` adapter is **input-side only**. It
reads Sorbet's syntax and translates the vocabulary; it does
not run Sorbet's type checker, doesn't ship
`sorbet-runtime`, and doesn't enforce Sorbet's runtime
guarantees. If you remove `sorbet` and `sorbet-runtime` from
your `Gemfile`, the plugin keeps reading the sigs (the
adapter's mini-interpreter doesn't load Sorbet) but `T.let` /
`T.cast` / `T.must` / `T.unsafe` calls will raise
`NameError` at runtime unless you keep at least the runtime
gem (or stub the four singleton methods on a top-level `T`
constant — the plugin's demo does this for its own
unit tests).

## Where to go next

- The full feature matrix and architectural surface live in
  [`examples/rigor-sorbet/README.md`](../../examples/rigor-sorbet/README.md).
- The design rationale + slice plan is at
  [`docs/adr/11-sorbet-input-adapter.md`](../adr/11-sorbet-input-adapter.md).
- The cross-checker triage report at
  [`docs/notes/20260503-steep-cross-check-triage.md`](../notes/20260503-steep-cross-check-triage.md)
  shows how Rigor's analyzer routinely surfaces sig drift
  that other static checkers miss — useful when comparing
  what each tool finds in practice.
