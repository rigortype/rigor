# Rigor

[![Gem Version](https://badge.fury.io/rb/rigortype.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/rigortype)
[![GitHub License](https://img.shields.io/github/license/rigortype/rigor)](https://github.com/rigortype/rigor/blob/master/LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/rigortype/rigor)

**Inference-first static analysis for Ruby.** Run `rigor check` over your
code — no annotations, no runtime dependency, no DSL.

Rigor parses Ruby with [Prism](https://github.com/ruby/prism), runs a
flow-sensitive type-inference engine over each file, and reports a small
but trustworthy catalogue of bugs: undefined methods on typed receivers,
wrong-argument-count calls, provable divisions by zero, and more.

**Your team never needs to write type annotations** — Rigor derives
everything from the code itself. An AI Skill gets a project running in
minutes with a configuration tailored to its stack. When you want to go
deeper — tighter checks, framework-aware analysis, your own refinements —
Rigor's type system is remarkably powerful, and a Skill takes you there
step-by-step.

**Three design commitments drive Rigor.**

1. **Types are facts, not wishes.** Hand-written annotations drift the
   moment they are written. Rigor infers from the code itself — every
   type is derived from what your source actually produces. When you do
   want RBS in `sig/`, [`rigor sig-gen`](https://rigor.typedduck.fail/reference/adr/14-rbs-sig-generation/)
   emits it from inference results so the written form starts in sync
   with reality.
2. **Your specs are types.** Do you really need to write type
   annotations? Your `spec/` is already type information. RSpec
   `expect(x).to be_a(T)` / `eq(literal)` assertions contribute
   narrowing facts from that point forward; `subject` / `let` bindings
   propagate the SUT's type into downstream `it` bodies; factory
   definitions in `spec/factories/` feed attribute shapes back into
   `rigor-activerecord` and `rigor-factorybot`'s cross-plugin channels.
   The test suite you already have becomes a live type oracle.
3. **Programmable inference beyond unions.** A plain union
   (`Integer | nil`) is not the type story Ruby needs. Rigor reasons
   about *what values an expression actually produces* — literal values,
   integer ranges, refinement carriers, per-position tuple / hash shapes
   — and exposes a plugin API plus a
   [macro / DSL expansion substrate](https://rigor.typedduck.fail/reference/adr/16-macro-expansion/)
   so Rails-shape DSLs become first-class type sources.

## Installation

Rigor is a tool, not a library — install it independently, **not** in
your project's `Gemfile`. It runs on Ruby 4.0, regardless of which Ruby
version your project targets.

**Using an AI coding agent?** Hand it this prompt and it will detect
your environment, install Rigor, and kick off the project-init Skill
automatically:

```
Install Rigor in this project by following the instructions at
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

Prefer to set up in your language? Find prompts for Japanese, Chinese,
Korean, Portuguese, Spanish, French, German, Italian, Vietnamese, Thai,
Indonesian, Polish, Ukrainian, Russian, Romanian, and Turkish at
[docs/manual/14-rails-quickstart.md](docs/manual/14-rails-quickstart.md#step-1--install-ruby-40-and-rigor-common-to-both-paths)
(or the [online version](https://rigor.typedduck.fail/reference/manual/14-rails-quickstart/)).

**Manual install** — the recommended path uses
[`mise`](https://mise.jdx.dev/), which provisions both Ruby 4.0 and
Rigor pinned per project:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

If you already have Ruby 4.0 available, `gem install rigortype` works too.
The gem is named `rigortype` (the name `rigor` was taken on RubyGems);
the executable it installs is `rigor`.

Full options — `asdf`, dev containers, CI workflow template — are in the
[installation guide](https://rigor.typedduck.fail/reference/manual/01-installation/)
and [CI guide](https://rigor.typedduck.fail/reference/manual/11-ci/).

## Getting started with AI Skills

The fastest path from zero to a running Rigor setup is the
**`rigor-project-init` Skill** — an AI agent skill bundled under
[`skills/`](skills/) that detects your stack, recommends the right plugins,
and writes `.rigor.dist.yml` for you:

```
# In Claude Code or any AI assistant that supports Agent Skills:
Use the rigor-project-init skill
```

The Skill walks your `Gemfile`, proposes a plugin set matched to your
framework (Rails, Sinatra, dry-rb, …), lets you choose an adoption mode —
**baseline** (acknowledge existing diagnostics and work them down
incrementally) or **strict** (zero-diagnostic gate from day one) — then
commits a ready-to-use configuration. No manual YAML editing required.

Two companion Skills continue the journey once you are up and running:

| Skill | Use when |
| --- | --- |
| [`rigor-baseline-reduce`](skills/rigor-baseline-reduce/) | Reducing an existing baseline: `rigor triage` prioritisation → site-by-site classification → fix / `# rigor:disable` / open a Rigor issue |
| [`rigor-plugin-author`](skills/rigor-plugin-author/) | Teaching Rigor about a project-specific DSL or framework — authors the plugin gem or project-private plugin |

All three Skills follow the [agentskills.io](https://agentskills.io/)
convention and work with any AI assistant that discovers skills in your
project directory.

## Quick start

```sh
# Check lib/ for bugs.
rigor check lib

# Drop a starter .rigor.yml.
rigor init

# Print the inferred type at a precise FILE:LINE:COL position.
rigor type-of lib/foo.rb:10:5

# Summarise the diagnostic stream: distribution, hotspots, heuristic hints.
rigor triage lib

# Emit RBS from inference results — review with --diff, write with --write.
rigor sig-gen --diff  lib/foo.rb
rigor sig-gen --write lib/foo.rb
```

### Sample output

```sh
$ cat /tmp/demo.rb
"hello".no_such_method        # undefined method
[1, 2, 3].rotate(1, 2)        # wrong number of arguments

$ rigor check /tmp/demo.rb
/tmp/demo.rb:1:9: error: undefined method `no_such_method' for "hello"
/tmp/demo.rb:2:11: error: wrong number of arguments to `rotate' on Array (given 2, expected 0..1)
```

Diagnostics fire only when the receiver type is statically known and the
evidence is conclusive — Rigor never surfaces a warning it cannot prove.

### Faster runs through the cache

Rigor caches RBS work (loaded environment, type translation, class
hierarchy) under `.rigor/cache/` — the second `rigor check` is
significantly faster than the first. Add `.rigor/` to your `.gitignore`.

```sh
rigor check --cache-stats lib   # inspect cache hit/miss
rigor check --clear-cache lib   # wipe if you suspect staleness
```

## The type vocabulary

A vanilla type checker answers "what *class* is this object?" Rigor
answers "what *subset of values* can this expression produce?" — tracking
literal values, integer ranges, refinement carriers, and structural shapes
through the whole analysis, without a single annotation.

| Carrier | What it records | Example |
| --- | --- | --- |
| **Literal** (`Constant`) | A single Ruby value | `Constant<42>`, `Constant<"hello">`, `Constant<:foo>` |
| **Integer range** | A bounded interval | `positive-int = int<1, max>`, `int<5, 10>` |
| **Refinement** | Base type minus a point, or restricted by a predicate | `non-empty-string = String - ""`, `lowercase-string` |
| **Tuple / HashShape** | Heterogeneous arrays / known-key hashes | `[1, "two"]` → `Tuple[Constant<1>, Constant<"two">]` |
| **Union** | Finite enumerable set of literals | `Constant<:zero> \| Constant<:small> \| Constant<:large>` |
| **`Dynamic[T]`** | Gradual carrier — "could be anything" | `Dynamic[Top]` when proof is unavailable |

Every narrower carrier **erases to its base class** for RBS interop, so
importing Rigor is a strictly additive change.

The full type model — constant folding, `Method` bindings, LightweightHKT,
`RBS::Extended` directives — is in the
[handbook](https://rigor.typedduck.fail/reference/handbook/) and
[type specification](https://rigor.typedduck.fail/reference/type-specification/).

### Unlocking tighter types with `RBS::Extended`

When you *want* to express more than RBS allows, attach a
`%a{rigor:v1:…}` annotation in your `sig/` file. The annotation is a
no-op for ordinary RBS tools; Rigor uses it to tighten call-site and
body types.

```rbs
class Slug
  %a{rigor:v1:return: non-empty-string}
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (::String id) -> ::String
end
```

This is entirely optional — Rigor runs without any annotations.
The directive grammar and the full refinement-name catalogue are in
[`RBS::Extended`](https://rigor.typedduck.fail/reference/type-specification/rbs-extended/)
and [imported built-in types](https://rigor.typedduck.fail/reference/type-specification/imported-built-in-types/).

## Plugins

Production plugins ship under [`plugins/`](plugins/) for the most common
Ruby frameworks and gems. Activate them in `.rigor.yml`:

```yaml
plugins:
  - rigor-activerecord
  - rigor-actionpack
  - rigor-rspec
```

**Rails ecosystem** — [`rigor-rails-routes`](plugins/rigor-rails-routes/),
[`rigor-rails-i18n`](plugins/rigor-rails-i18n/),
[`rigor-activerecord`](plugins/rigor-activerecord/),
[`rigor-actionpack`](plugins/rigor-actionpack/),
[`rigor-actionmailer`](plugins/rigor-actionmailer/),
[`rigor-activejob`](plugins/rigor-activejob/),
[`rigor-factorybot`](plugins/rigor-factorybot/),
[`rigor-pundit`](plugins/rigor-pundit/),
[`rigor-sidekiq`](plugins/rigor-sidekiq/).

**Other frameworks** — [`rigor-sinatra`](plugins/rigor-sinatra/),
[`rigor-devise`](plugins/rigor-devise/),
[`rigor-dry-struct`](plugins/rigor-dry-struct/),
[`rigor-rspec`](plugins/rigor-rspec/),
[`rigor-actioncable`](plugins/rigor-actioncable/).

**Type-system extensions** — [`rigor-sorbet`](plugins/rigor-sorbet/)
(ingests Sorbet `sig` / `T.let` / RBI files),
[`rigor-statesman`](plugins/rigor-statesman/),
[`rigor-typescript-utility-types`](plugins/rigor-typescript-utility-types/).

See [`plugins/README.md`](plugins/README.md) for the full catalogue. To
write a plugin for your own DSL or framework, use the
[`rigor-plugin-author`](skills/rigor-plugin-author/) Skill described above.
Plugin-contract walkthroughs (simplified virtual use cases spotlighting
one extension surface each) are under [`examples/`](examples/).

## Configuration

`rigor init` writes a starter `.rigor.yml`. Most projects only need a
handful of lines:

```yaml
paths: [lib, app]
target_ruby: "3.3"
plugins:
  - rigor-activerecord
  - rigor-actionpack
baseline: .rigor-baseline.yml   # when using baseline adoption mode
```

Common knobs: `disable` (rule IDs to silence project-wide),
`signature_paths` (additional `sig/`-style directories),
`dependencies.source_inference` (opt-in gem-source walk for gems
without RBS). The `rigor-project-init` Skill writes and populates all
of this for you. Full reference on the
[website](https://rigor.typedduck.fail/).

In-source suppression: `# rigor:disable <rule>` silences a single line;
`# rigor:disable all` suppresses every rule on that line.

## Status

Current released version: **`v0.1.8`** (2026-05-21). The analyzer is
usable on real Ruby code today; the rule catalogue is deliberately
conservative — Rigor's stance is to surface zero false positives while
the inference surface stabilises.

Release history: [`CHANGELOG.md`](CHANGELOG.md). Forward-looking
commitments: [Roadmap](https://rigor.typedduck.fail/reference/roadmap/).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the `git clone` →
green-tests path and a map of the spec / ADR / skill documentation
contributors should read.

## License

Mozilla Public License Version 2.0. See [`LICENSE`](LICENSE).
