# Appendix — Coming from TypeScript

If your reflex when you see a static type checker is "ah, like
TypeScript," this appendix maps Rigor's vocabulary onto the
TypeScript concepts you already know. It is the shortest path
from "I get TypeScript" to "I get Rigor."

This page is not a tutorial. It is a translation table plus a
short discussion of the places where the two systems make
genuinely different choices — those are the places where your
TypeScript reflexes will mislead you.

## The five-second pitch

| Question | TypeScript | Rigor |
| --- | --- | --- |
| Where do annotations live? | In source (`x: number`) | In `.rbs` files alongside `.rb` |
| Who writes them? | The author of the code | The author OR inference |
| What is the default? | `any` (TypeScript pre-strict) / `unknown` (strict) | Inferred precisely or `Dynamic[Top]` |
| Identity of types | Structural | Nominal + structural facets |
| Cost of "I do not know yet" | A red squiggle until annotated | Silence — `Dynamic[Top]` produces no diagnostic |
| When do diagnostics fire? | Whenever a type is unsound | Only when Rigor can **prove** the unsoundness |

The two systems share their goal — flag bugs before the program
runs — and disagree on the path to it. TypeScript prefers
soundness-first authoring (every value gets a checked type, the
checker complains until it does). Rigor prefers
no-false-positives inference (the checker stays silent on
anything it cannot prove and asks for `.rbs` only where
inference cannot see further).

## Type vocabulary mapping

| TypeScript form | Rigor form | Notes |
| --- | --- | --- |
| `string` | `String` | Display drops `Nominal[]`. |
| `number` | `Integer` / `Float` / `Numeric` | TS conflates int and float; Rigor splits per Ruby's runtime. |
| `boolean` | `bool` (`Constant<true> \| Constant<false>`) | `bool` is structurally a union of two constants. |
| `null` | `nil` (`Constant<nil>`) | Ruby has only `nil`; TS distinguishes `null` and `undefined`. |
| `undefined` | (no analogue) | An unset Ruby local raises `NameError`, not "undefined". |
| `any` | `Dynamic[Top]` | The "be silent here" carrier. |
| `unknown` | `Top` | Both refuse method dispatch until narrowed; `unknown` is closer to `Top` than to `Dynamic[Top]`. |
| `never` | `Bot` | Empty type — no inhabitants. Used for unreachable branches and `T.absurd` (Sorbet) / `raise`-only bodies. |
| `void` | `void` | Same idea — caller must not consume the value. |
| `T \| U` | `T \| U` | Same shape; same display. |
| `T & U` | `Intersection[T, U]` | Less common in Rigor — refinements often replace it. |
| `"hello"` (literal type) | `Constant<"hello">` | Direct equivalent. Folding is more aggressive in Rigor. |
| `42` (literal type) | `Constant<42>` | Same. |
| `42 \| 43 \| 44` | `Constant<42> \| Constant<43> \| Constant<44>` | Same. |
| `[number, string]` (tuple) | `Tuple[Integer, String]` | Same per-position model. |
| `{ name: string; age: number }` | `HashShape{name: String, age: Integer}` | Same per-key model; Ruby uses Symbol keys idiomatically. |
| `Array<T>` / `T[]` | `Array[T]` | Same. |
| `Record<K, V>` | `Hash[K, V]` | Same. |
| `Readonly<T>` | `readonly_of[T]` (via opt-in [`rigor-typescript-utility-types`](../../examples/rigor-typescript-utility-types/) plugin) | View-level read-only marker on every entry of a `HashShape`. Does NOT prove the underlying object is frozen — ADR-13 § "Readonly". |
| `Partial<T>` / `Required<T>` | `partial_of[T]` / `required_of[T]` (same plugin) | Flips every entry's required-ness on a `HashShape`. `Partial` does NOT widen value types to `nil` — Rigor's `HashShape` distinguishes "key absent" from "key present with nil value" (ADR-13 WD on required-ness flips). |
| `Pick<T, K>` / `Omit<T, K>` | `pick_of[T, K]` / `omit_of[T, K]` (same plugin) | Restrict / remove `HashShape` entries by literal-key union; Tuple receivers project by integer index. Non-shape carriers degrade conservatively and surface `dynamic.shape.lossy-projection`. |
| Conditional types `T extends U ? A : B` | (none in core; plugin contributions) | A plugin can vary return type by argument shape. |
| `keyof T` | (none) | `HashShape` exposes its key set internally but not as a type operator. |
| `T['k']` | `T[k]` indexed access | Rigor supports literal indexed access on `HashShape` and `Tuple` (see the type spec). |
| Template literal types | `literal-string` carrier | "Provably built from literals" — see Chapter 2. |

## Narrowing — the part that feels familiar

TypeScript's flow-sensitive narrowing has direct analogues in
Rigor. The vocabulary is different; the behaviour is the same.

| TypeScript | Rigor |
| --- | --- |
| `if (x)` | `if x` — strips `false` / `nil` from the truthy edge |
| `typeof x === "string"` | `x.is_a?(String)` |
| `x instanceof Foo` | `x.is_a?(Foo)` |
| `x === null` | `x.nil?` (and `x == nil`) |
| `if (x !== null && x !== undefined)` | `if x` (Ruby has only `nil`, no `undefined`) |
| Discriminated union `switch (x.kind)` | `case x; in {kind: :foo}` or `case x.kind; when :foo` |
| User-defined type guard `function isFoo(x): x is Foo` | `%a{rigor:v1:predicate-if-true: x is Foo}` directive |
| `as` cast | (no equivalent in code) — Rigor has `T.cast` via `rigor-sorbet`, or `param:` directives |
| `x!` (non-null assertion) | (no equivalent in code) — `T.must` via `rigor-sorbet`, or `unless x.nil?` narrowing |
| `as const` | Constants fold automatically — no `as const` needed |

The biggest practical difference: in TypeScript, you reach for
`as Foo` whenever the checker disagrees with you. Rigor does
not have an in-source cast. The equivalents are:

1. **Add a guard.** `unless x.nil?; x.upcase; end` is the
   idiomatic move.
2. **Tighten an `.rbs`.** Often the underlying issue is a
   library sig that is too loose.
3. **Use the `rigor-sorbet` plugin.** Adopt `T.let` /
   `T.cast` / `T.must` if you want in-source assertions; see
   Chapter 10.

## Refinement carriers — the part that does not exist in TypeScript

TypeScript can express "string of length ≥ 1" only through
template literal types or branded types, and neither composes
well. Rigor has first-class refinement carriers — a string
that is provably non-empty, an integer that is provably
positive, an array that is provably non-empty.

| Rigor refinement | TypeScript closest | Comment |
| --- | --- | --- |
| `non-empty-string` | `\`${string}${string}\`` (template literal trick) or branded `NonEmptyString` | Awkward in TS; Rigor produces it from `unless s.empty?` automatically. |
| `positive-int` | branded `PositiveInt` | TS users tend to skip the brand — Rigor narrows from `n > 0`. |
| `int<1, 9>` | union of literal types `1 \| 2 \| 3 \| ... \| 9` | Rigor's range carrier handles arbitrary bounds without exploding. |
| `numeric-string` | (none useful) | TS has no equivalent; Rigor narrows from regex matches against numeric patterns. |
| `non-empty-array[T]` | `[T, ...T[]]` (tuple-with-rest) | TS has the encoding but few APIs use it; Rigor produces it from `unless arr.empty?`. |

If you have ever wished TypeScript had `non-empty-string` as a
keyword instead of a brand, you will appreciate this part of
Rigor.

## "No annotations needed" in practice

Take the canonical TypeScript onboarding example:

```typescript
function classify(n: number): "zero" | "positive" | "negative" {
  if (n === 0) return "zero";
  if (n > 0) return "positive";
  return "negative";
}

const result = classify(7);
// TypeScript: result: "zero" | "positive" | "negative"
```

The Rigor equivalent — no annotations:

```ruby
def classify(n)
  return :zero     if n.zero?
  return :positive if n.positive?
  :negative
end

result = classify(7)
assert_type(result, "Constant<:zero> | Constant<:positive> | Constant<:negative>")
```

Both checkers infer the same precise union. The TypeScript
version requires the parameter type and return type as
authored annotations; the Rigor version requires neither.

When you DO need to write a sig — at module boundaries, when
the body is too dynamic, when you want to enforce parameter
shapes — that goes into `sig/<file>.rbs`, not into the `.rb`
source. That separation is deliberate (see ADR-1 and ADR-5).

## Generics

TypeScript's generics are central to its standard library;
Rigor's generics are RBS's, which are more conservative. RBS
supports class-level type parameters and method-level type
parameters with bounded constraints, but does not yet support
inferred call-site instantiation as routinely as TypeScript.

| TypeScript | Rigor (via RBS) |
| --- | --- |
| `function id<T>(x: T): T` | `def id: [T] (T) -> T` |
| `Array<T>` | `Array[T]` |
| `Map<K, V>` | `Hash[K, V]` |
| `Promise<T>` | (no analogue — Ruby has no built-in Promise) |
| `Pick<T, K>` / `Omit<T, K>` / `Partial<T>` / `Required<T>` / `Readonly<T>` | Opt-in [`rigor-typescript-utility-types`](../../examples/rigor-typescript-utility-types/) plugin maps each onto `pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of` over `HashShape` (and `pick_of` / `omit_of` over `Tuple`). |
| Conditional types | (no analogue — would need a plugin) |

Rigor reads RBS generics through its dispatcher and instantiates
parameters at the call site when the receiver carries enough
information. The display is identical to RBS — `Array[Integer]`
shows as `Array[Integer]`.

## Nullability

TypeScript's `strictNullChecks` makes `null` and `undefined`
their own types. You spell nullable as `T | null | undefined`.

Ruby has `nil` and only `nil`. The RBS shorthand is `T?`,
which expands to `T | nil`. Rigor's narrowing handles `nil`
exactly the way TypeScript handles `null`:

```ruby
def length(s)              # s: String?  (RBS-declared)
  return 0 if s.nil?
  s.length                 # s: String — nil stripped by .nil? check
end
```

The TypeScript equivalent reads identically:

```typescript
function length(s: string | null): number {
  if (s === null) return 0;
  return s.length;
}
```

## Severity, suppression, and "strict mode"

| TypeScript | Rigor |
| --- | --- |
| `tsconfig.json` `strict: true` | `severity_profile: strict` |
| `tsconfig.json` `noImplicitAny` | (no analogue — Rigor never demands annotations) |
| `tsconfig.json` `strictNullChecks` | Always-on in Rigor |
| `// @ts-ignore` | `# rigor:disable <rule>` |
| `// @ts-expect-error` | (no analogue today) |
| `// @ts-nocheck` | `# rigor:disable-file all` |
| `tsc --noEmit` | `bundle exec rigor check lib` |

## What TypeScript has and Rigor does not

Be honest about what you give up:

- **Conditional types.** `T extends U ? A : B` has no core
  Rigor analogue. A plugin can vary return type by argument
  shape (see Chapter 9), but you write Ruby code for the
  variation, not type-level expressions.
- **Mapped types.** `Pick`, `Omit`, `Partial`, `Required`, and
  `Readonly` ship as opt-in plugin-supplied vocabulary via
  [`rigor-typescript-utility-types`](../../examples/rigor-typescript-utility-types/),
  which maps them onto the Rigor-canonical `pick_of` / `omit_of`
  / `partial_of` / `required_of` / `readonly_of` shape-projection
  type functions on `HashShape` (and `pick_of` / `omit_of` on
  `Tuple`). Template literal manipulation and other mapped-type
  variants (`Uppercase<S>` / `Lowercase<S>` / `Capitalize<S>`)
  remain outside Rigor's surface.
- **Type-level computation.** TypeScript's type system is
  Turing-complete; Rigor's deliberately is not. This is a
  feature, not a limitation — the analyzer has to be fast
  on real Ruby projects.
- **Inferred return type from method body in source.** `tsc`
  infers return types from a function's body and exposes them
  to callers. Rigor does the same for in-source `def`, but
  RBS-declared methods bind their callers to the declared
  return — a deliberate boundary-discipline choice (see ADR-5,
  the robustness principle).
- **Editor IntelliSense parity.** TypeScript's tooling has 20
  years of investment behind it. Rigor's editor integration is
  young; today the analyzer ships diagnostics and `rigor
  type-of`, and editor integration via LSP is on the roadmap.

## What Rigor has and TypeScript does not

The other direction:

- **First-class refinements.** `non-empty-string`,
  `positive-int`, `numeric-string`, etc. — values restricted
  by predicate, narrowed automatically.
- **Constant folding through method calls.** `"foo".upcase` is
  `Constant<"FOO">`, not just `string`. Rigor catalogues which
  built-in methods are pure and folds through them.
- **No-false-positives stance.** Rigor stays silent on
  `Dynamic[Top]` receivers rather than complaining. You will
  never see a Rigor diagnostic where the right answer is "well,
  technically the checker cannot know."
- **No annotation tax.** You can run `rigor check` on a Ruby
  project that has zero `.rbs` files and get useful diagnostics
  from inference alone. Adding `.rbs` files is incremental;
  every file you skip is `Dynamic[Top]` at the boundary, not a
  diagnostic.
- **Severity-aware adoption.** TypeScript's "all or nothing"
  feel (you flip `strict` and a thousand errors appear) is
  smoothed by Rigor's `lenient` / `balanced` / `strict`
  profiles plus per-rule overrides plus baseline diffing.

## A migration vignette

You are porting a TypeScript module to Ruby. The original
function:

```typescript
function pick<K extends keyof T, T extends object>(obj: T, keys: K[]): Pick<T, K> {
  const out = {} as Pick<T, K>;
  for (const k of keys) {
    if (k in obj) out[k] = obj[k];
  }
  return out;
}
```

The Rigor approach:

```ruby
# lib/utils.rb
def pick(obj, keys)
  keys.each_with_object({}) do |k, out|
    out[k] = obj[k] if obj.key?(k)
  end
end
```

```rbs
# sig/utils.rbs
def pick: [K, V] (Hash[K, V] obj, Array[K] keys) -> Hash[K, V]
```

The RBS sig stays generic. If you want `Pick<T, K>`'s exact-
key-set tracking back, opt into the
[`rigor-typescript-utility-types`](../../examples/rigor-typescript-utility-types/)
plugin and annotate the return type with the `Pick` spelling:

```rbs
# sig/utils.rbs
%a{rigor:v1:return: Pick[T, K]}
def pick: [K, V] (Hash[K, V] obj, Array[K] keys) -> Hash[K, V]
```

The plugin's `TypeNodeResolver` translates `Pick[T, K]` into
the canonical `pick_of[T, K]` projection. Either way the call
site stays precise where it matters: a Hash literal at the
call site is a `HashShape` regardless of the signature, and
the per-key types survive through `obj.key?(k)` narrowing.

## What's next

You probably do not need to read the rest of this appendix
section sequentially. Three useful pointers:

- [Chapter 2 — Everyday types](02-everyday-types.md) for the
  carrier zoo if you have not seen the refinements before.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar (how you teach Rigor about a
  custom type predicate).
- [Chapter 10 — Coexisting with Sorbet](10-sorbet.md) if your
  project is in fact already using Sorbet — `T.let`, `T.cast`,
  and `T.must` have direct equivalents and the migration is
  smoother than starting from scratch.

If you want to compare against another tool, the sibling
appendix pages cover [PHPStan](appendix-phpstan.md),
[mypy](appendix-mypy.md), and [Steep](appendix-steep.md).
