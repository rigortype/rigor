# Rigor

[![Gem Version](https://badge.fury.io/rb/rigortype.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/rigortype)
![GitHub License](https://img.shields.io/github/license/rigortype/rigor)

**Inference-first static analysis for Ruby.** Add Rigor to your
Gemfile and run `rigor check` over your code — no annotations,
no runtime dependency on the analyzer, no DSL.

Rigor parses Ruby with [Prism](https://github.com/ruby/prism),
runs a flow-sensitive type-inference engine over each file,
consults RBS signatures and the project's own `sig/` directory
for any class it can find, and reports a small but trustworthy
catalogue of bugs (undefined methods on typed receivers, wrong
positional arity, provable `Integer / 0`, …).

When you want tighter types than RBS expresses, refine them
through the
[`RBS::Extended`](docs/type-specification/rbs-extended.md)
annotation surface — `rigor:v1:return:` /
`rigor:v1:param:` / `rigor:v1:assert` directives accept the
imported-built-in refinement names (`non-empty-string`,
`positive-int`, `non-empty-array[Integer]`, `int<5, 10>`, …)
without changing the underlying RBS.

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

## First analysis

Drop into your project root and run the canonical commands:

```sh
# Diagnose unknown methods, wrong-arity calls, and other
# rule-driven bugs across `lib/`.
bundle exec rigor check lib

# Print the inferred type at a precise FILE:LINE:COL position.
bundle exec rigor type-of lib/foo.rb:10:5

# Report Scope#type_of coverage across a tree (handy when
# diagnosing why a particular call site reads as `untyped`).
bundle exec rigor type-scan lib

# Drop a starter .rigor.yml into the project root.
bundle exec rigor init
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
   Rigor walks `def` / `define_method` / `attr_*` so
   user-defined methods on a class are recognised.

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
  - Composed shapes — `non-empty-lowercase-string`,
    `non-empty-uppercase-string`.

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
  `case` / `when` integration.
- **Tuple / HashShape carriers** — shape-aware element access,
  range / start-length slices, closed / open / required /
  optional policies.
- **Constant folding** — aggressive arithmetic / string /
  Symbol / Tuple-shaped `divmod` folding, cartesian fold over
  `Union[Constant…]`, integer-range arithmetic
  (`positive-int + 1` → `int<2, max>`), branch elision on
  provably-truthy / falsey predicates.
- **Built-in catalogues** — Numeric, String, Symbol, Array,
  IO, File, Hash, Range, Set, Time. Each catalog drives the
  fold dispatcher with per-class blocklists for indirect
  mutators.
- **Refinement carriers** — `Type::Difference`,
  `Type::Refined`, `Type::Intersection` provide the
  imported-built-in catalogue end-to-end through
  `Builtins::ImportedRefinements`.
- **`RBS::Extended` directive routes** — `return:`, `param:`
  (call-site + body-side), `assert:` /
  `predicate-if-(true|false)` accept refinement payloads.

The full per-release surface lives in
[`CHANGELOG.md`](CHANGELOG.md). The internal contracts the
analyzer guarantees live under
[`docs/internal-spec/`](docs/internal-spec/).

## Configuration

`rigor init` writes a starter `.rigor.yml`:

```sh
bundle exec rigor init           # fails if .rigor.yml exists
bundle exec rigor init --force   # overwrite
```

The configuration is intentionally small in v0.0.x; see the
generated file for the available knobs.

## Status

Current release: **`v0.0.4`** (the fourth preview). The
analyzer is usable on real Ruby code today but the rule
catalogue is deliberately narrow — Rigor's stance is to surface
zero false positives while the inference surface stabilises.
The roadmap is tracked in
[`docs/MILESTONES.md`](docs/MILESTONES.md); release-by-release
detail lives in [`CHANGELOG.md`](CHANGELOG.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the minimal
`git clone` → green-tests path and a map of the spec / ADR /
skill documentation contributors should know about.

## License

Mozilla Public License Version 2.0. See [`LICENSE`](LICENSE).
