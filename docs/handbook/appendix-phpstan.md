# Appendix — Coming from PHPStan

PHPStan is the closest spiritual peer Rigor has in another
language. Both tools share the same priorities: stay silent on
code the analyzer cannot characterise, lean on inference rather
than mandatory annotations, and surface a small catalogue of
high-confidence diagnostics. Many of Rigor's design choices —
config-file shape, baseline diffing, severity profiles, the
`assert` family of directives — were directly informed by
PHPStan.

If you have used PHPStan, the mental model carries over almost
unchanged. This appendix maps the vocabulary.

## The five-second pitch

| Question | PHPStan | Rigor |
| --- | --- | --- |
| Where do annotations live? | PHPDoc `/** ... */` blocks | `.rbs` files alongside `.rb` |
| Default behaviour | Inference, fall back silent | Inference, fall back silent |
| "Levels" | 0 – 10 (numeric) | `lenient` / `balanced` / `strict` (named) |
| Per-rule control | `ignoreErrors:` regex, level demotion | `disabled_rules:`, `severity_overrides:` |
| Baseline | `phpstan-baseline.neon` | `rigor.baseline.json` |
| Stub format | PHP stub files | RBS files |
| Custom narrowing | Type-Specifying Extensions | Plugins (Chapter 9) |
| Custom return shape | Dynamic Return Type Extensions | Plugin `flow_contribution_for` |

The two tools agree on most of the foundational decisions. The
biggest differences are surface — Ruby's syntax and runtime
shape — not philosophy.

## Type vocabulary mapping

PHPStan and Rigor have an overlapping refinement vocabulary —
this is the closest match of any peer.

| PHPStan PHPDoc | Rigor representation | Notes |
| --- | --- | --- |
| `string` | `String` | |
| `int` | `Integer` | |
| `float` | `Float` | |
| `bool` | `bool` (`Constant<true> \| Constant<false>`) | |
| `null` | `Constant<nil>` | Ruby has only `nil`. |
| `mixed` | `Top` | The "anything" carrier. |
| `never` | `Bot` | Empty type. |
| `void` | `void` | Same. |
| `array<T>` / `T[]` | `Array[T]` | |
| `array<K, V>` | `Hash[K, V]` | Ruby splits by container kind. |
| `array{name: string, age: int}` | `HashShape{name: String, age: Integer}` | Same per-key model. |
| `array{0: int, 1: string}` (list shape) | `Tuple[Integer, String]` | Same per-position model. |
| `non-empty-string` | `non-empty-string` | **Identical name and meaning.** |
| `non-falsy-string` | `non-empty-string` | Rigor does not split out the falsy-but-nonempty case. |
| `numeric-string` | `numeric-string` | Identical. |
| `lowercase-string` | `lowercase-string` | Identical. |
| `class-string` | `Singleton[T]` | Equivalent shape. |
| `int<1, 9>` | `int<1, 9>` | **Identical syntax.** |
| `positive-int` | `positive-int` | Identical. |
| `negative-int` | `negative-int` | Identical. |
| `non-zero-int` | `non-zero-int` | Identical. |
| `non-empty-array<T>` | `non-empty-array[T]` | Identical. |
| `non-empty-list<T>` | (no separate carrier — `non-empty-array[T]` covers it) | Ruby has no list/dict split. |
| `T \| U` | `T \| U` | |
| `T & U` | `Intersection[T, U]` | |
| `literal-string` | `literal-string` | **Identical concept.** Provably built from source-code literals. |
| `'hello'` (literal type) | `Constant<"hello">` | |
| `42` (literal type) | `Constant<42>` | |

This table is the densest in the appendix because the overlap
is so close. If you are reading PHPStan's "PHPDoc Types" page
in another tab, almost every advanced refinement transfers.

## The `@phpstan-assert` family

PHPStan's assertion-narrowing PHPDoc tags map directly onto
Rigor's `RBS::Extended` directive grammar. Chapter 7 covers
the table in depth; here it is again for reference:

| PHPStan PHPDoc | Rigor RBS::Extended | Effect |
| --- | --- | --- |
| `@phpstan-assert T $x` | `%a{rigor:v1:assert: x is T}` | After return, caller's `x` is `T`. |
| `@phpstan-assert-if-true T $x` | `%a{rigor:v1:predicate-if-true: x is T}` | If method returns truthy, caller's `x` is `T`. |
| `@phpstan-assert-if-false T $x` | `%a{rigor:v1:predicate-if-false: x is T}` | If method returns falsey, caller's `x` is `T`. |
| `@phpstan-assert !T $x` | `%a{rigor:v1:assert: x is ~T}` | After return, caller's `x` is **not** `T`. |
| `@phpstan-assert =T $x` (assert-and-narrow) | (covered by `assert:`) | Same effect. |
| `@phpstan-self-out T` | `%a{rigor:v1:assert: self is T}` | `self` narrows in caller scope. |
| `@phpstan-impure` | (no analogue) | Rigor does not yet model purity for fold-through-method-call. |

Every directive Rigor's grammar ships has a PHPStan PHPDoc
analogue. If you have a PHPStan-shaped mental model for "what
narrows what after this method returns," it transfers
unchanged.

## Type-Specifying Extensions ↔ Plugins

When the assertion is recognised by **call shape** rather than
by signature — PHPStan's `TypeSpecifyingExtension` interface,
where you write a class that the framework instantiates and
asks "given this call, what narrowings does it produce?" —
Rigor's analogue is a plugin's `#flow_contribution_for` and
`#diagnostics_for_file` hooks plus the engine's
`post_return_facts` substrate.

| PHPStan extension type | Rigor analogue |
| --- | --- |
| `MethodTypeSpecifyingExtension` | Plugin's `Fact(target_kind: :parameter)` returned from `flow_contribution_for` |
| `StaticMethodTypeSpecifyingExtension` | Same, with `Fact(target_kind: :receiver-class)` |
| `FunctionTypeSpecifyingExtension` | Same, with `Fact(target_kind: :argument)` |
| `DynamicMethodReturnTypeExtension` | Plugin's `flow_contribution_for(call_node:, scope:)` |
| `DynamicStaticMethodReturnTypeExtension` | Same, varying by receiver-class branch in plugin code |
| `DynamicFunctionReturnTypeExtension` | Same, for module-level methods |

The plugin contract pinned at
[`docs/internal-spec/plugin.md`](../internal-spec/plugin.md)
gives every shape PHPStan's extension API covers, with
analogous lifecycle (manifest declaration, per-call dispatch,
fact emission). Chapter 9 has the high-level orientation; the
internal spec is the binding contract.

The `rigor-sorbet` adapter in Chapter 10 is itself a worked
example of a "Type-Specifying Extension at scale" — every
`T.must`, `T.cast`, `T.bind`, `T.assert_type!` call is
recognised by call shape, not by sig.

## Configuration

PHPStan's `phpstan.neon` and Rigor's `.rigor.yml` /
`.rigor.dist.yml` use the same shape: a single config file at
the project root, autoloaded if present, with `paths:`,
severity controls, and includes.

| PHPStan | Rigor |
| --- | --- |
| `phpstan.neon` | `.rigor.yml` |
| `phpstan.neon.dist` | `.rigor.dist.yml` |
| `paths:` | `paths:` |
| `level:` | `severity_profile:` |
| `excludePaths:` | (no analogue today — paths are explicitly listed) |
| `ignoreErrors:` (regex / pattern) | `disabled_rules:` (rule identifier or wildcard) |
| `parameters: ignoreErrors:` per-path | `# rigor:disable-file <rule>` at the file head |
| `includes:` | `includes:` |
| `phpstan-baseline.neon` | `rigor.baseline.json` |
| `phpstan analyse --generate-baseline` | `rigor check --format=json > rigor.baseline.json` |
| `phpstan analyse` | `rigor check` |
| `phpstan analyse --baseline` | `rigor diff rigor.baseline.json` |
| Path resolution: relative to declaring file | Path resolution: relative to declaring file (same rule). |

The baseline workflow is identical. Chapter 8 has the
walkthrough.

The `includes:` semantics also match PHPStan's: declaration
order, later overrides earlier, the current file's keys win
over included files. Rigor's `.rigor.yml` does NOT auto-merge
with `.rigor.dist.yml` — the override must list the dist file
explicitly under `includes:`. PHPStan has the same behaviour
when you have both `phpstan.neon` and `phpstan.neon.dist` in
play.

## Stubs ↔ RBS

PHPStan reads PHP stub files (`.stub`) for libraries that ship
no PHPDoc. Rigor reads `.rbs` files for the same purpose. The
dispatch is similar — both tools layer "stub-declared
contract beats inferred-from-body" — and both use the stub
files as the canonical place to attach refinements via
PHPDoc / `RBS::Extended` annotations.

| PHPStan | Rigor |
| --- | --- |
| `*.stub` files | `.rbs` files in `sig/` (project) and `rbs_collection.lock.yaml` (third-party) |
| PHPDoc on stubs | `RBS::Extended` `%a{rigor:v1:...}` annotations |
| `#[Override]` / `#[\Deprecated]` attributes | RBS `attr_*` and `def` declarations |
| `phpstan/extension-installer` | Bundler + `Gemfile` for plugin gems |

A practical pattern that works in both worlds: keep the stub /
RBS file authoritative for the public contract, then layer
project-specific tightenings under
`@phpstan-*` / `RBS::Extended` directives that ship alongside
the stub.

## Severity profiles vs PHPStan levels

PHPStan's levels are a numeric ladder (0 = "shapes only," 10 =
"strictest"). Rigor's profiles are named (`lenient`,
`balanced`, `strict`).

| PHPStan level | Rigor profile (rough) | Notes |
| --- | --- | --- |
| 0 – 2 | `lenient` | Most rules → `:warning`; uncertain rules drop to `:info`. |
| 3 – 6 | `balanced` (default) | Most rules → `:error`. |
| 7 – 10 | `strict` | Everything → `:error`, including `:warning` rules in `balanced`. |

The mapping is approximate — the rule sets are not 1:1 — but
the practical advice is the same: start with the default,
tighten over time. Chapter 8's "helpful workflow" matches the
PHPStan onboarding pattern.

## "No annotations needed" — yes, but with stubs

PHPStan and Rigor share the philosophy that **inference does
the heavy lifting**. You do not annotate every variable; you
annotate the boundary (function signatures, library stubs)
and inference propagates inward.

PHPStan's catch is that PHPDoc lives in the same file as the
PHP source. Rigor's catch is that RBS lives in `sig/`, a
parallel tree. The trade-offs are well-known:

- **Same-file PHPDoc** keeps the docs adjacent to the code
  they describe — easier to update, harder to forget.
- **Parallel `.rbs`** keeps the runtime source clean for
  developers who do not care about types — no PHPDoc clutter
  on production methods.

Rigor leans toward the parallel-file model for cultural reasons
(Ruby's tradition of compact source), but `RBS::Inline`
provides an in-file alternative for projects that want
PHPDoc-style adjacency. See ADR-1 for the rationale.

## What PHPStan has and Rigor does not

- **Generics with bounded constraints across the stub library.**
  PHPStan's generics ecosystem is more mature; RBS generics
  exist but the standard library's coverage is patchier.
- **`@phpstan-impure` and pure-by-default modelling.** Rigor
  catalogues per-method purity inside its built-in
  `data/builtins/ruby_core/` YAML, but does not yet expose a
  user-facing way to declare a method pure for fold-through.
- **Custom rules.** PHPStan's `Rule` interface lets you write a
  rule in PHP that fires on AST patterns; Rigor's plugin
  surface covers diagnostics emission via
  `#diagnostics_for_file`, but the rule shape is less polished
  than PHPStan's framework.
- **`treatPhpDocTypesAsCertain`.** PHPStan's "trust PHPDoc"
  knob has no Rigor equivalent — Rigor always trusts RBS
  declarations as authoritative.

## What Rigor has and PHPStan does not

- **Constant folding through method calls.** PHPStan does some
  constant propagation; Rigor folds aggressively through
  catalogued built-ins (`Numeric`, `String`, `Symbol`, `Array`,
  `Hash`).
- **First-class flow-sensitive narrowing on Ruby's predicate
  methods.** `s.empty?` / `n.zero?` / `n.positive?` etc. are
  recognised by name and narrow accordingly. PHPStan has the
  same idea via Type-Specifying Extensions, but Rigor ships
  the catalogue out of the box.
- **`literal-string` carrier.** Both tools have the concept,
  but Rigor's carrier composes through interpolation —
  `"#{a}#{b}"` is `literal-string` if both `a` and `b` are.
  PHPStan has `literal-string` for "literal at this position"
  but the propagation rules are different.
- **Sorbet-input adapter.** If your project happens to be
  partially-Sorbet (you migrated some files to RBS but kept
  the rest), Rigor reads both sources concurrently. PHPStan
  has nothing analogous — there is no parallel "Sorbet of
  PHP."

## A migration vignette

You are porting a PHPStan-tightened library to Ruby. The
original PHP:

```php
class Slug {
    /**
     * @phpstan-param non-empty-string $name
     * @phpstan-return non-empty-lowercase-string
     */
    public function normalise(string $name): string {
        return strtolower(preg_replace('/\s+/', '-', $name));
    }

    /**
     * @phpstan-assert non-empty-string $value
     */
    public function assertNotEmpty(string $value): void {
        if ($value === '') throw new InvalidArgumentException();
    }
}
```

The Rigor port — Ruby source unchanged from idiomatic, RBS at
the boundary:

```ruby
# lib/slug.rb
class Slug
  def normalise(name)
    name.downcase.gsub(/\s+/, "-")
  end

  def assert_not_empty(value)
    raise ArgumentError if value.empty?
  end
end
```

```rbs
# sig/slug.rbs
class Slug
  %a{rigor:v1:param: name is non-empty-string}
  %a{rigor:v1:return: non-empty-lowercase-string}
  def normalise: (String name) -> String

  %a{rigor:v1:assert: value is non-empty-string}
  def assert_not_empty: (String value) -> void
end
```

The directive grammar is structurally a translation: every
PHPStan `@phpstan-*` becomes a `%a{rigor:v1:...}` annotation on
the matching `def` line in the `.rbs` file.

## What's next

You probably do not need to read the rest of this appendix
section sequentially. Three useful pointers:

- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  has the full directive grammar, including the PHPStan-mapping
  table that this page summarises.
- [Chapter 8 — Understanding errors](08-understanding-errors.md)
  covers the rule catalogue, severity profiles, baseline
  diffing — every PHPStan onboarding analogue.
- [Chapter 9 — Plugins](09-plugins.md) for the
  Type-Specifying / Dynamic-Return analogues.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[mypy](appendix-mypy.md), and [Steep](appendix-steep.md).
