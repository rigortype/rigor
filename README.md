# Rigor

[![Gem Version](https://badge.fury.io/rb/rigortype.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/rigortype)
[![GitHub License](https://img.shields.io/github/license/rigortype/rigor)](https://github.com/rigortype/rigor/blob/master/LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/rigortype/rigor)

**Inference-first static analysis for Ruby.** Add Rigor to your
Gemfile and run `rigor check` over your code — no annotations,
no runtime dependency on the analyzer, no DSL.

Rigor parses Ruby with [Prism](https://github.com/ruby/prism),
runs a flow-sensitive type-inference engine over each file,
consults RBS signatures and the project's own `sig/` directory
for any class it can find, and reports a small but trustworthy
catalogue of bugs (undefined methods on typed receivers, wrong
positional arity, provable `Integer / 0`, …).

The differentiator is a richer type vocabulary than ordinary
RBS expresses. Rigor reasons about *what values an expression
actually produces* — literal values, integer ranges,
refinement-type carriers, per-position tuple / hash shapes —
not just *which class an object belongs to*. See **[Beyond
`Integer` and `String`](#beyond-integer-and-string-rigors-richer-type-vocabulary)**
for the full type-model story; the short pitch is below.

When you want tighter types than RBS expresses, refine them
through the
[`RBS::Extended`](docs/type-specification/rbs-extended.md)
annotation surface — `rigor:v1:return:` /
`rigor:v1:param:` / `rigor:v1:assert` directives accept the
imported-built-in refinement names (`non-empty-string`,
`positive-int`, `non-empty-array[Integer]`, `int<5, 10>`,
`literal-string`, `non-lowercase-string`, …) without changing
the underlying RBS.

## Installation

Add the gem to your application's Gemfile (development group is
typical — Rigor is a static analyzer, not a runtime dependency):

```ruby
group :development do
  gem "rigortype", require: false
end
```

Install:

```sh
bundle install
```

Or, for a one-off install outside Bundler:

```sh
gem install rigortype
```

The gem ships an executable named `rigor` (gem name is
`rigortype` because `rigor` was already taken on RubyGems).

**Ruby version.** The gemspec requires `>= 4.0.0, < 4.1`.

## Quick start

Drop into your project root and run the canonical commands:

```sh
# Diagnose unknown methods, wrong-arity calls, and other
# rule-driven bugs across `lib/`.
bundle exec rigor check lib

# Drop a starter .rigor.yml into the project root.
bundle exec rigor init

# Print the inferred type at a precise FILE:LINE:COL position.
bundle exec rigor type-of lib/foo.rb:10:5

# Report Scope#type_of coverage across a tree (handy when
# diagnosing why a particular call site reads as `untyped`).
bundle exec rigor type-scan lib

# Emit RBS skeletons from inference results — review with
# `--diff`, write to `sig/` with `--write`. ADR-14 sig-gen.
bundle exec rigor sig-gen --print lib/foo.rb
bundle exec rigor sig-gen --diff  lib/foo.rb
bundle exec rigor sig-gen --write lib/foo.rb
```

### Sample output

```sh
$ cat /tmp/demo.rb
"hello".no_such_method        # undefined method
[1, 2, 3].rotate(1, 2)        # wrong number of arguments

$ bundle exec rigor check /tmp/demo.rb
/tmp/demo.rb:1:9: error: undefined method `no_such_method' for "hello"
/tmp/demo.rb:2:11: error: wrong number of arguments to `rotate' on Array (given 2, expected 0..1)
```

The rule catalogue is **deliberately conservative**: a
diagnostic fires only when the receiver type is statically
known and the method set on that class is enumerable through
RBS or in-source `def` / `define_method` discovery. Implicit-
self calls, dynamic receivers, and constant-decl alias classes
(e.g. `YAML` → `Psych`) are skipped to avoid false positives.

### Faster runs through the cache

Rigor caches expensive RBS work (the loaded `RBS::Environment`,
constant-type translation, class hierarchy, type-parameter
names, known-class set) under `.rigor/cache/` so the second
`rigor check` is significantly faster than the first. The cache
is keyed by your project's `.rbs` file digests + the locked
`rbs` gem version, so a signature change or a gem upgrade
invalidates exactly what it should.

```sh
# Inspect what is cached on disk and what this run did.
bundle exec rigor check --cache-stats lib

# Wipe the cache (do this if you suspect staleness).
bundle exec rigor check --clear-cache lib

# Run with caching disabled.
bundle exec rigor check --no-cache lib
```

Add `.rigor/` to your `.gitignore` — the cache is per-checkout
and contains nothing reproducible to share.

## Beyond `Integer` and `String`: Rigor's richer type vocabulary

A vanilla static checker answers "what *class* is this object?"
Rigor answers a much narrower question: "what *subset of values*
can this expression actually produce?" That distinction is the
whole point of Rigor — types like `Integer` and `String` describe
classes, but real-world code carries far more structure (a count
that's always non-negative, a name that's never empty, a flag
that's one of three Symbols). Rigor reasons about that structure
out of the box, without you writing a single annotation.

### The carrier zoo

| Carrier | What it records | Example |
| --- | --- | --- |
| **Literal types** (`Type::Constant`) | A single Ruby value | `Constant<42>`, `Constant<"hello">`, `Constant<:foo>` |
| **Integer ranges** (`Type::IntegerRange`) | A bounded integer interval `int<a, b>` | `positive-int = int<1, max>`, `int<5, 10>` |
| **Refinement types** — split into two halves: `Type::Difference` and `Type::Refined` | A base nominal minus a single value, or a base nominal restricted by a predicate | `non-empty-string = String - ""`, `lowercase-string = String & lowercase?`, `literal-string` |
| **Intersection** (`Type::Intersection`) | Composition of multiple refinements | `non-empty-lowercase-string = non-empty-string ∩ lowercase-string` |
| **Tuple / HashShape** | Heterogeneous arrays / known-key hashes that carry per-position / per-key types | `[1, "two", :three]` types as `Tuple[Constant<1>, Constant<"two">, Constant<:three>]`; `{name: "Alice", age: 30}` as `HashShape{name: Constant<"Alice">, age: Constant<30>}` |
| **Union** (`Type::Union`) | "One of these literal values" — finite enums Rigor can enumerate | `Constant<:zero> \| Constant<:small> \| Constant<:large>` |
| **`Method` binding** (`Type::BoundMethod`) | The receiver / method-name pair `Object#method(:sym)` produces, so `.call` / `.()` / `[]` recover the precise backing dispatch | `"1".method(:to_i).call` resolves to `Constant<1>` instead of `untyped` |
| **`Dynamic[T]`** | The gradual carrier — wraps a static facet with a "could be anything" admission | `Dynamic[Top]` is the conservative fallback Rigor uses when it cannot prove a narrower type |

Each refinement / range / literal carrier **erases to its base
class** for ordinary RBS interop, so importing Rigor is a
strictly additive change: a method whose RBS sig says
`-> String` keeps that contract, and Rigor's narrower inference
just sits on top.

### What this buys you in practice

```ruby
# Rigor doesn't just see "Integer", it sees "non-negative integer".
n = ARGV.size                  # int<0, max>  (non-negative-int)
m = n + 1                      # int<1, max>  (positive-int)
m.zero?                        # Constant<false>  — proven; the
                               # branch elision can drop the `else`

# String composition stays as precise as the inputs allow.
greeting = "Hello, "           # Constant<"Hello, ">
name     = ARGV.first          # String?       — RBS-declared
hello    = "Hello, #{name}!"   # literal-string — every part is
                               # literal-bearing, so the result is
                               # provably source-derived.

# Tuple-shaped destructuring stays per-position.
first, _middle, last = [10, 20, 30]
first                          # Constant<10>
last                           # Constant<30>

# Constant folding through user methods.
def is_odd(n) = n.odd?
is_odd(3)                      # Constant<true>  — folded through
                               # the body, not just typed as `bool`

# Case/when narrowing produces a literal-set Union.
label = case n
        when 0      then :zero
        when 1..9   then :small
        else             :large
        end
label                          # Constant<:zero> | Constant<:small>
                               #   | Constant<:large>

# Method bindings keep their receiver — `.method(:sym).call`
# round-trips through the original dispatch.
[:to_i, :to_f, :to_sym].map { |m| "1".method(m).call }
                       # Tuple[Constant<1>, Constant<1.0>, Constant<:"1">]
                       # — per-element fold + BoundMethod backward fold

# RBS::Extended directives let you tighten beyond what RBS expresses.
class Slug
  %a{rigor:v1:return: non-empty-string}
  def normalise: (::String id) -> ::String
end
Slug.new.normalise("foo").size  # positive-int  — provably ≥ 1
```

Rigor never invents these answers — every narrower carrier is
derived from literals in the source, control-flow narrowing
(`is_a?`, `nil?`, `==` against finite literal sets, integer
comparisons), per-class catalogues for the bundled built-ins,
or `RBS::Extended` directives the user opted into. When the
inference cannot prove a value is in a narrower carrier, it
stays at the wider one (or `Dynamic[Top]`) and Rigor stays
silent — diagnostics fire only when the narrow type is
genuinely proved.

### Where the type model is documented

- **End-user handbook** — chapter-by-chapter walkthrough of
  the type model written for Ruby programmers without prior
  static-typing background:
  [`docs/handbook/`](docs/handbook/README.md). Start here if
  you want a guided tour of how Rigor sees your code rather
  than a spec deep-dive.
- One-page mental model:
  [`docs/types.md`](docs/types.md).
- Binding spec corpus:
  [`docs/type-specification/`](docs/type-specification/README.md).
- Imported refinement names (kebab-case catalogue):
  [`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md).
- The `RBS::Extended` annotation grammar that opens this
  vocabulary up to your own RBS:
  [`docs/type-specification/rbs-extended.md`](docs/type-specification/rbs-extended.md).

## How Rigor finds your types

Rigor consults, in order:

1. **In-source RBS.** If your project has a `sig/` directory,
   Rigor auto-loads it. `rigor init` writes a `.rigor.yml`
   that points at `sig/` by default.
2. **Bundled RBS core + stdlib.** Pathname, OptParse, JSON,
   YAML, etc. ship with the analyzer.
3. **Gem RBS.** RBS files vendored with installed gems
   (Prism's own `.rbs`, the `rbs` gem's, …).
4. **In-source class discovery.** When no RBS is available,
   Rigor walks `def` / `define_method` / `attr_*` /
   `Data.define(*Symbol)` so user-defined methods on a class
   are recognised.
5. **Opt-in gem-source inference (ADR-10).** Gems listed
   under `dependencies.source_inference:` in `.rigor.yml`
   have their `lib/` walked the same way project source is,
   so methods on those gems' classes resolve even without
   RBS. Inferred returns crossing the gem boundary are
   wrapped in `Dynamic[T]` so the call site retains the
   provenance — RBS / RBS::Inline / generated stubs / plugin
   contracts always win on conflict. Default behaviour is
   unchanged: gems not listed stay at the
   RBS-or-`Dynamic[Top]` boundary.

If a type cannot be proved, the engine returns `Dynamic[Top]`
(Rigor's gradual carrier) and stays silent — Rigor never invents
diagnostics it cannot prove.

## Refining types through `RBS::Extended`

When the RBS-declared type is too wide, attach a
`%a{rigor:v1:…}` annotation to the relevant method in your
`sig/` file. The annotation is a no-op for ordinary RBS tools
and a tightening signal for Rigor.

```rbs
class Slug
  # The runtime always returns a non-empty string. The override
  # tightens the call-site result to non-empty-string and tells
  # the body's `assert_type` that `id` cannot be "".
  %a{rigor:v1:return: non-empty-string}
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (::String id) -> ::String
end
```

Right-hand side accepts:

- **RBS class names** — `String`, `::Foo::Bar` (with optional
  `~T` negation for `assert` / `predicate-if-*`).
- **Imported-built-in refinement names** (kebab-case):
  - Point-removal — `non-empty-string`, `non-zero-int`,
    `non-empty-array[T]`, `non-empty-hash[K, V]`.
  - IntegerRange aliases — `positive-int`, `non-negative-int`,
    `negative-int`, `non-positive-int`, `int<min, max>`.
  - Predicate refinements — `lowercase-string`,
    `uppercase-string`, `numeric-string`, `decimal-int-string`,
    `octal-int-string`, `hex-int-string`.
  - Paired complements (`~T`-symmetric) —
    `non-lowercase-string`, `non-uppercase-string`,
    `non-numeric-string`. Writing `~lowercase-string` narrows
    `String` to `non-lowercase-string` instead of the generic
    `Difference[String, lowercase-string]` fallback.
  - Composed shapes — `non-empty-lowercase-string`,
    `non-empty-uppercase-string`, `non-empty-literal-string`.
  - Flow-tracked source-literal — `literal-string`. Rigor lifts
    `"hi #{name}!"`, `"a" + literal_str`, and `literal_str * 3`
    to `literal-string` when every operand is itself
    literal-bearing.

The full directive table is in
[`docs/type-specification/rbs-extended.md`](docs/type-specification/rbs-extended.md);
the catalogue of refinement names is in
[`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md).

### Example: argument-type-mismatch caught at the call site

```rbs
# sig/normaliser.rbs
class Normaliser
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (::String id) -> ::String
end
```

```ruby
# app/normaliser.rb
class Normaliser
  def normalise(id)
    id.upcase
  end
end

n = Normaliser.new
n.normalise("hello")   # OK
n.normalise("")        # rigor flags: argument type mismatch
```

`rigor check` reports the second call as an
`argument-type-mismatch` because the literal `""` does not
satisfy `non-empty-string`. Inside the method body, Rigor also
sees `id` as `non-empty-string` (so `id.empty?` reduces to
`Constant[false]` and `id.size` reduces to `positive-int`).

## What rigor sees today

- **Local / instance / class / global variables** —
  intra-method bindings, cross-method ivar / cvar
  accumulators, program-wide globals, and compound writes
  (`||=`, `&&=`, `+=`).
- **`self` typing and constant lookup** — class and method
  body boundaries inject `Singleton[T]` / `Nominal[T]`;
  lexical constant resolution walks RBS-core, common stdlib,
  in-source class discovery, and in-source constant-value
  tracking (`BUCKETS = [:a, :b]; BUCKETS.first` →
  `Constant[:a]`).
- **Predicate narrowing** — truthiness, `nil?`, `is_a?` /
  `kind_of?` / `instance_of?`, finite-literal equality,
  case-equality (`===`) for Class / Module / Range / Regexp,
  `case` / `when` integration. Paired-complement narrowing for
  Refined predicates (`~lowercase-string` →
  `non-lowercase-string`).
- **Tuple / HashShape carriers** — shape-aware element access,
  range / start-length slices, closed / open / required /
  optional policies, per-element block fold over
  `map`, `select`, `filter_map`, `flat_map`, `find` /
  `find_index`, `count`, `any?` / `all?` / `none?`, `zip`.
  `&:symbol` block-pass on these methods is treated as
  `{ |x| x.symbol }` and dispatches against the element type
  so `Hash#transform_values(&:freeze)` returns `Hash[K, V]`
  instead of `Enumerator[...]`.
- **Constant folding** — aggressive arithmetic / string /
  Symbol / Tuple-shaped `divmod` folding, cartesian fold over
  `Union[Constant…]`, integer-range arithmetic
  (`positive-int + 1` → `int<2, max>`), branch elision on
  provably-truthy / falsey predicates,
  `Constant<String>#%` format-string fold against
  `Tuple` / `HashShape` arguments.
- **Built-in catalogues** — Numeric / Integer / Float, String /
  Symbol, Array, Hash, IO, File, Range, Set, Time, Date /
  DateTime, Comparable, Enumerable, Rational, Complex,
  Pathname, Random, Struct (+ `Data`), Encoding, Regexp /
  MatchData, Proc / Method / UnboundMethod, Exception. Each
  catalog drives the fold dispatcher with per-class blocklists
  for indirect mutators.
- **Refinement carriers** — `Type::Difference`,
  `Type::Refined`, `Type::Intersection` provide the
  imported-built-in catalogue end-to-end through
  `Builtins::ImportedRefinements`. The parser accepts Symbol
  / String literals and `|`-unions at type-arg position
  (`pick_of[Shape, :a | :b]`, `Pick[T, "name" | "email"]`).
- **`Method` carrier (`Type::BoundMethod`)** —
  `Object#method(:sym)` lifts into a binding carrier so
  `.call` / `.()` / `[]` recover the precise dispatch
  (`"1".method(:to_i).call` resolves to `Constant<1>`).
  Reflective Method members (`#owner` / `#name` / `#arity`)
  still resolve via the Method RBS sig.
- **`RBS::Extended` directive routes** — `return:`, `param:`
  (call-site + body-side), `assert:` /
  `predicate-if-(true|false)` accept refinement payloads, and
  roll up into a single `Rigor::FlowContribution` bundle per
  method (the v0.1.0 plugin contribution merger reads bundles
  directly).
- **Opt-in gem-source inference (ADR-10)** — gems listed under
  `dependencies.source_inference:` have their `lib/` walked.
  Per-gem budget, per-gem-version cache slice,
  `dynamic.dependency-source.*` diagnostic family covering
  gem-not-found / budget-exceeded / config-conflict /
  boundary-cross (the last surfaces RBS+gem-source overlap
  on `mode: :full` gems for audit).

The full per-release surface lives in
[`CHANGELOG.md`](CHANGELOG.md). The internal contracts the
analyzer guarantees live under
[`docs/internal-spec/`](docs/internal-spec/).

## Plugins

`v0.1.0` introduced the extension API; `v0.1.x` rounds it out
with the [ADR-9](docs/adr/9-cross-plugin-api.md) cross-plugin
fact channel (one plugin publishes a fact like `:model_index`,
another consumes it), [ADR-11](docs/adr/11-sorbet-input-adapter.md)
Sorbet ingestion, [ADR-13](docs/adr/13-typenode-resolver-plugin.md)
plugin-supplied type-vocabulary resolvers, and
[ADR-16](docs/adr/16-macro-expansion.md) macro / DSL expansion
substrate (declarative Tier A block-as-method / Tier B
trait-inlining-registry / Tier C heredoc-template / Tier D
external-file inclusion). **Twenty-four worked examples** ship
under [`examples/`](examples/) — each is a fully-shaped plugin
gem with a runnable demo and an end-to-end integration spec.

**Plugin-contract teaching examples** (focus on a single
extension-point):

- [`rigor-deprecations`](examples/rigor-deprecations/) —
  smallest possible plugin (~80 lines); config-driven rules.
- [`rigor-lisp-eval`](examples/rigor-lisp-eval/) — typing literal
  AST arguments at a method call.
- [`rigor-statesman`](examples/rigor-statesman/) — two-pass DSL
  analysis (collect declarations, then validate references).
- [`rigor-pattern`](examples/rigor-pattern/) — plugin →
  analyzer collaboration via `Scope#type_of` and the
  literal-string carrier.
- [`rigor-units`](examples/rigor-units/) — local-variable flow
  tracking through arithmetic.
- [`rigor-routes`](examples/rigor-routes/) — `Plugin::IoBoundary`
  reads under `TrustPolicy` plus cache producers.
- [`rigor-typescript-utility-types`](examples/rigor-typescript-utility-types/)
  — `Plugin::TypeNodeResolver` chain wiring TS-canonical names
  (`Pick` / `Omit` / `Partial` / `Required` / `Readonly`) onto
  Rigor's shape-projection type functions.

**Macro expansion substrate consumers** (ADR-16 — declarative
manifest entries, no walker code):

- [`rigor-sinatra`](examples/rigor-sinatra/) — **Tier A**
  block-as-method. Recognises Sinatra's nine class-level HTTP
  verb methods and narrows the route block's `self_type` so
  bare `params` / `redirect` / `halt` resolve through
  `Sinatra::Base`'s RBS.
- [`rigor-dry-struct`](examples/rigor-dry-struct/) — **Tier C**
  heredoc-template. Synthesises a reader on every `Dry::Struct`
  subclass for each `attribute :name, T` / `attribute? :name, T`
  call.
- [`rigor-devise`](examples/rigor-devise/) — **Tier B**
  trait-inlining registry mirroring `lib/devise/modules.rb`.
  Each `devise :strategy_a, :strategy_b` call explodes the
  included module's RBS instance methods onto the calling model
  class (Devise's `user.valid_password?` returns the module's
  authored `bool`).

**Rails ecosystem plugins** (Tier 1 + Tier 2 + Tier 3 + Sorbet):

- Tier 1: [`rigor-rails-routes`](examples/rigor-rails-routes/),
  [`rigor-rails-i18n`](examples/rigor-rails-i18n/),
  [`rigor-actionmailer`](examples/rigor-actionmailer/),
  [`rigor-activejob`](examples/rigor-activejob/).
- Tier 2: [`rigor-actionpack`](examples/rigor-actionpack/)
  (4 phases — routes / filters / renders / strong-params),
  [`rigor-factorybot`](examples/rigor-factorybot/),
  [`rigor-activerecord`](examples/rigor-activerecord/) —
  publishes `:model_index` via ADR-9 for the other two
  to consume.
- Tier 3: [`rigor-pundit`](examples/rigor-pundit/),
  [`rigor-sidekiq`](examples/rigor-sidekiq/),
  [`rigor-rspec`](examples/rigor-rspec/),
  [`rigor-actioncable`](examples/rigor-actioncable/).
- Parallel: [`rigor-sorbet`](examples/rigor-sorbet/) — ingests
  Sorbet `sig` / `T.let` / `T.cast` / `T.must` / `T.bind` /
  `T.assert_type!` / `T.reveal_type` / `T.absurd` and RBI
  files as type sources.

[`examples/README.md`](examples/README.md) is the plugin
authoring landing page — comparison table, recommended reading
order, and the architectural map of which surface each example
exercises. The binding contract for the plugin API lives in
[`docs/adr/2-extension-api.md`](docs/adr/2-extension-api.md);
the slice-by-slice normative specs are under
[`docs/internal-spec/plugin*.md`](docs/internal-spec/); the
sibling ADRs that extend it ride the same surface
([ADR-9](docs/adr/9-cross-plugin-api.md) cross-plugin facts,
[ADR-11](docs/adr/11-sorbet-input-adapter.md) Sorbet adapter,
[ADR-13](docs/adr/13-typenode-resolver-plugin.md) TypeNode
resolver).

## Configuration

`rigor init` writes a starter `.rigor.yml`:

```sh
bundle exec rigor init           # fails if .rigor.yml exists
bundle exec rigor init --force   # overwrite
```

Common knobs the file exposes:

- `paths` — directories `rigor check` and `rigor type-scan`
  scan when no path is given (defaults to `lib`).
- `target_ruby` — minimum Ruby version your project targets.
- `libraries` — extra stdlib libraries to load on top of the
  bundled defaults (e.g. `["csv", "set"]`).
- `signature_paths` — explicit list of `sig/`-style directories.
  Leave unset (or `null`) to auto-detect `<root>/sig`. Use `[]`
  to disable project-RBS loading entirely.
- `disable` — rule identifiers to silence project-wide. Shipped
  rules: `undefined-method`, `wrong-arity`,
  `argument-type-mismatch`, `possible-nil-receiver`,
  `dump-type`, `assert-type`, `always-raises`. In-source
  `# rigor:disable <rule>` end-of-line comments silence
  per-line; `# rigor:disable all` suppresses every rule.

## Status

Current released version: **`v0.1.4`**. The analyzer is usable
on real Ruby code today; the rule catalogue is deliberately
narrow — Rigor's stance is to surface zero false positives
while the inference surface stabilises. Forward-looking commitments
(in-flight cycle + queued work) live in
[`docs/ROADMAP.md`](docs/ROADMAP.md); the release-by-release
"what shipped" record is [`CHANGELOG.md`](CHANGELOG.md).

`v0.1.4` (released 2026-05-14) delivered:

- **[ADR-10](docs/adr/10-dependency-source-inference.md) closed
  end-to-end** — opt-in gem-source inference, per-gem budget,
  cache slice, and the `dynamic.dependency-source.boundary-cross`
  `:info` diagnostic that surfaces RBS / gem-source overlap
  under `mode: :full`.
- **[ADR-11](docs/adr/11-sorbet-input-adapter.md) primary surface
  + per-call-site assertion gating** — `rigor-sorbet` ingests
  Sorbet `sig { ... }` blocks, `T.let` / `T.cast` / `T.must` /
  `T.bind` / `T.assert_type!` / `T.reveal_type` / `T.absurd`,
  and RBI files. Per-call-site `enforce_sigil` gates assertion
  recognisers by the caller file's `# typed:` sigil.
- **[ADR-13](docs/adr/13-typenode-resolver-plugin.md) plugin
  TypeNode resolver + TypeScript-utility-type adapter** —
  `Plugin::TypeNodeResolver` extension point + five
  Rigor-canonical shape-projection type functions
  (`pick_of` / `omit_of` / `partial_of` / `required_of` /
  `readonly_of`) + the opt-in `rigor-typescript-utility-types`
  plugin mapping TS spellings onto the core functions.
  `Pick[T, :a | :b]` round-trips through the directive grammar.
- **[ADR-14](docs/adr/14-rbs-sig-generation.md) — `rigor sig-gen`
  CLI** — emits RBS from inference results across five
  classifications (`new-file` / `new-method` / `tighter-return`
  / `equivalent` / `skipped`); `--params=untyped` default,
  `--params=observed` opt-in via `--observe=PATH`.
- **`Method` carrier (`Type::BoundMethod`)** —
  `Object#method(:sym).call` / `.()` / `[]` round-trip with
  full precision instead of collapsing to `untyped`.
- **Rails ecosystem (Tier 1 + Tier 2)** — `rigor-rails-routes`,
  `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`,
  `rigor-actionpack` (4 phases), `rigor-factorybot`, and
  `rigor-activerecord` publishing `:model_index` via the
  ADR-9 cross-plugin fact channel.

Twenty-four worked plugin examples now ship under
[`examples/`](examples/) — see
[`examples/README.md`](examples/README.md) for the comparison
table. The current `[Unreleased]` cycle on `master` (release
pending) also delivered the [ADR-16](docs/adr/16-macro-expansion.md)
macro / DSL expansion substrate (four-tier declarative
manifest contract + engine integration + Tier B/C precision
promotion); see `CHANGELOG.md` `[Unreleased]` for the full
landing notes.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the minimal
`git clone` → green-tests path and a map of the spec / ADR /
skill documentation contributors should know about.

## License

Mozilla Public License Version 2.0. See [`LICENSE`](LICENSE).
</content>
</invoke>
