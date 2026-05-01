# Rigor

Rigor is a static analyzer for Ruby that aims to provide modern,
inference-first type checking without adding type annotations or
runtime dependencies to application code.

This first preview ships a usable end-to-end pipeline: parse Ruby
with Prism, build a flow-sensitive type-inference engine
(`Rigor::Scope#type_of`), drive a project-aware RBS environment,
and surface diagnostics through a small `rigor check` rule
catalogue.

## Status

The current branch (`impl/scope-type-of`) is a **first preview**.
The engine recognises the bulk of canonical Ruby surface — local
variables, ivars / cvars / globals (intra- and cross-method), self
typing, lexical constant lookup, predicate narrowing
(`is_a?` / `==` / `===` / `case`-`when`), block parameter binding,
closure escape, Tuple / HashShape carriers, and more. See
[docs/CURRENT_WORK.md](docs/CURRENT_WORK.md) for the full slice
trail.

## Requirements

- Nix with the `nix-command` and `flakes` features available.
- Ruby 4.0.x and Bundler 4.x, provided by the Flake development
  shell.

## Setup

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle install
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rake
```

For interactive development, enter the Flake shell first:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
```

## Quick Start

Inside the Flake shell:

```sh
# Show available subcommands.
bundle exec exe/rigor help

# Print the inferred type at FILE:LINE:COL.
bundle exec exe/rigor type-of lib/rigor/scope.rb:55:9

# Report Scope#type_of coverage across a tree.
bundle exec exe/rigor type-scan lib

# Diagnose unknown methods and wrong-arity calls on typed receivers.
bundle exec exe/rigor check lib

# Write a starter .rigor.yml.
bundle exec exe/rigor init
```

### Example diagnostics

`rigor check` reports the canonical type-check signals it can
prove against the loaded RBS environment:

```sh
$ cat /tmp/demo.rb
"hello".no_such_method        # bug: undefined method
[1, 2, 3].rotate(1, 2)        # bug: wrong number of arguments

$ bundle exec exe/rigor check /tmp/demo.rb
/tmp/demo.rb:1:9: error: undefined method `no_such_method' for "hello"
/tmp/demo.rb:2:11: error: wrong number of arguments to `rotate' on Array (given 2, expected 0..1)
```

The rule catalogue is intentionally narrow: a diagnostic fires
only when the receiver type is statically known and the method
set on that class is enumerable through RBS or in-source `def` /
`define_method` discovery. Implicit-self calls, dynamic
receivers, and constant-decl alias classes (e.g. `YAML` → `Psych`)
are skipped to avoid false positives.

## What works

The first preview engine resolves:

- **Local / instance / class / global variables** — intra-method
  bindings (`@x = 1; @x`), cross-method ivar / cvar accumulators
  (`def init; @x = 1; end; def get; @x; end`), program-wide
  globals.
- **Compound writes** — `||=`, `&&=`, `+=` and friends thread
  through scope for every variable kind.
- **`self` typing** — class- and method-body boundaries inject
  `Singleton[T]` / `Nominal[T]`; implicit-self call dispatch
  routes through the enclosing class's RBS.
- **Constant lookup** — lexical walk against `scope.self_type`,
  RBS-core, common stdlib (`pathname`, `optparse`, `json`,
  `yaml`, ...), the `prism` and `rbs` gems' RBS, in-source
  class discovery, and in-source constant value tracking
  (`BUCKETS = [:a, :b, :c]; BUCKETS.first` → `Constant[:a]`).
- **Predicate narrowing** — truthiness, `nil?`, `is_a?` /
  `kind_of?` / `instance_of?`, finite-literal equality,
  case-equality (`===`) for Class / Module / Range / Regexp,
  `case` / `when` integration.
- **Blocks** — parameter binding (incl. destructuring + numbered
  parameters), block-return-type uplift through generic methods
  (`Array#map { |n| n.to_s }` → `Array[String]`), closure escape
  classification, captured-local invalidation on escaping blocks.
- **Tuple / HashShape carriers** — shape-aware element access,
  range / start-length slices, closed / open / required / optional
  policies threaded through `Acceptance`.
- **`rigor check` first-preview rules** — undefined method on
  typed receiver, wrong number of positional arguments. Both
  consult RBS plus in-source `def` / `define_method` discovery so
  reopened classes do not produce false positives.

See [docs/CURRENT_WORK.md](docs/CURRENT_WORK.md) for the canonical
status snapshot, [docs/internal-spec/inference-engine.md](docs/internal-spec/inference-engine.md)
for the engine contract, and [docs/adr/](docs/adr/) for the
decision records.

## Project layout

- `lib/rigor` — runtime library, type model, inference engine, CLI.
- `lib/rigor/analysis` — `Runner`, `CheckRules`, `Diagnostic`,
  `FactStore`.
- `lib/rigor/inference` — `Scope`-driven typers, dispatchers, and
  narrowing.
- `sig` — RBS signatures for Rigor itself.
- `spec` — RSpec test suite (830+ examples).
- `docs/adr` — architecture decision records.
- `docs/internal-spec` — engine contracts.
- `docs/type-specification` — type-language semantics.

## Roadmap past first preview

In rough priority order (see CURRENT_WORK.md for details):

1. More `rigor check` rules (nil-call, type-incompatible writes,
   unbound locals).
2. `RBS::Extended` effect plumbing (`%a{rigor:v1:pure}`,
   mutation / escape / call-timing effects).
3. Diagnostic publication for `FallbackTracer` events.
4. Plugin contribution layer.

## License

Rigor is licensed under the Mozilla Public License Version 2.0.
See [LICENSE](LICENSE).
