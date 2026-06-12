# Rigor

[![Gem Version](https://badge.fury.io/rb/rigortype.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/rigortype)
[![GitHub License](https://img.shields.io/github/license/rigortype/rigor)](https://github.com/rigortype/rigor/blob/master/LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/rigortype/rigor)

**Type-aware bug finding for Ruby — zero annotations, and a
zero-false-positive bar enforced against real codebases.** Run one
command over the code you already have, and trust every line of
output.

```sh
gem install rigortype && rigor check app lib
```

(The tool itself runs on Ruby 4.0; your project can stay on whatever
Ruby it targets — see [Get started](#get-started-in-one-prompt).)

No type annotations to write or maintain, no runtime dependency, no
changes to your code. Rigor parses Ruby with
[Prism](https://github.com/ruby/prism) and runs a flow-sensitive
inference engine that reasons about the *values* your expressions
produce — not just their classes. It catches undefined methods (and
typos) on inferred receivers, wrong argument counts, receivers that
can be `nil` on a live path, unreachable branches and `case` clauses,
and conditions that can only ever be truthy.

## Hello, Rigor

A realistic typo, caught with the receiver's *computed value* in the
message:

```ruby
# demo.rb
def slug(title)
  title.downcase.gsub(/\s+/, "-")
end

s = slug("Hello World")
s.lenght
```

```shell-session
$ rigor check demo.rb
demo.rb:7:3: error: undefined method `lenght' for "hello-world"
```

Note what the error says: not ``undefined method `lenght' for String``
but **`for "hello-world"`** — Rigor traced the value through the
method call and the `downcase.gsub` chain, with no annotations
anywhere.

Ask it what it knows at any position:

```ruby
# fact.rb
def factorial(n)
  n <= 1 ? 1 : n * factorial(n - 1)
end

answer = factorial(5)
```

```shell-session
$ rigor type-of fact.rb:6:1
type:    120
```

A recursive call with a known argument folds all the way down to its
value. The point is not arithmetic — the same machinery tracks hash
shapes through your params, string values through builder chains, and
`nil` through guard clauses in everyday application code.

## Get started in one prompt

The fastest path is to hand your AI coding agent (Claude Code, Cursor,
or any assistant that follows instructions from a URL) this prompt:

```
Install Rigor in this project by following the instructions at
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

It installs Rigor, then runs the bundled **`rigor-project-init`**
[Agent Skill](https://agentskills.io/): it walks your `Gemfile`,
proposes plugins matched to your stack (Rails, Sinatra, dry-rb, …),
lets you pick an adoption mode — **baseline** (acknowledge existing
diagnostics, work them down incrementally) or **strict**
(zero-diagnostic gate from day one) — and commits a ready-to-use
configuration. Non-English prompts (16 languages) are in the
[Rails quickstart](https://rigor.typedduck.fail/reference/manual/14-rails-quickstart/).

**Manual install** — Rigor is a tool, not a library: install it
independently, **not** in your project's `Gemfile`. It runs on Ruby
4.0 regardless of which Ruby your project targets
([`mise`](https://mise.jdx.dev/) provisions both, pinned per project):

```sh
mise use ruby@4.0
mise use gem:rigortype     # or: gem install rigortype
```

The gem is named `rigortype` (the name `rigor` was taken on RubyGems);
the executable is `rigor`. `asdf`, dev containers, and CI templates are
in the [installation guide](https://rigor.typedduck.fail/reference/manual/01-installation/)
and [CI guide](https://rigor.typedduck.fail/reference/manual/11-ci/).

### Daily commands

```sh
rigor check lib                 # find bugs (caches under .rigor/ — gitignore it)
rigor init                      # drop a starter .rigor.yml
rigor type-of lib/foo.rb:10:5   # inferred type at FILE:LINE:COL
rigor triage lib                # summarise diagnostics: distribution, hotspots
rigor sig-gen --diff lib/foo.rb # emit RBS from inference (--write to save)
```

In CI, `rigor check` auto-detects the platform and emits native output
(GitHub annotations, GitLab Code Quality, SARIF, Checkstyle, JUnit,
TeamCity).

## Three design commitments

1. **Types are facts, not wishes.** Hand-written annotations drift the
   moment they are written. Rigor infers from the code itself — every
   type is derived from what your source actually produces. When you do
   want RBS in `sig/`, [`rigor sig-gen`](https://rigor.typedduck.fail/reference/adr/14-rbs-sig-generation/)
   emits it from inference results so the written form starts in sync
   with reality.
2. **A false positive is the worst bug.** Your program works; a
   static analyzer that argues otherwise is the thing that is wrong.
   Rigor fires a diagnostic only when the receiver type is statically
   known and the evidence is conclusive — never on a value it merely
   failed to prove things about — and every precision change is gated
   on real OSS codebases (Mastodon, Redmine, GitLab FOSS) before it
   ships. You should never have to write defensive code, or a
   suppression comment, to calm the analyzer down.
3. **Programmable inference beyond unions.** A plain union
   (`Integer | nil`) is not the type story Ruby needs. Rigor tracks
   literal values, integer ranges, refinements like
   `non-empty-string`, and per-position tuple / hash shapes — and
   exposes a plugin API plus a
   [macro / DSL expansion substrate](https://rigor.typedduck.fail/reference/adr/16-macro-expansion/)
   so Rails-shape DSLs become first-class type sources.

## Works with your stack

Production plugins ship in-repo for the common frameworks and gems —
**Rails** (ActiveRecord, ActionPack, routes, i18n, jobs, mailers),
**testing** (RSpec, FactoryBot, minitest), **ecosystem** (Sidekiq,
Devise, Pundit, Sinatra, dry-rb, GraphQL), and **type-system bridges**
(`rigor-sorbet` ingests Sorbet `sig` / RBI files, so Rigor runs
alongside an existing Sorbet setup). If you already maintain RBS in
`sig/` — from Steep or by hand — Rigor reads it as a type source
out of the box. Activate plugins in `.rigor.yml`:

```yaml
paths: [lib, app]
plugins:
  - rigor-activerecord
  - rigor-actionpack
  - rigor-rspec
```

The full catalogue is in [`plugins/README.md`](plugins/README.md); the
`rigor-project-init` Skill picks the right set for you. To teach Rigor
your own DSL, the [`rigor-plugin-author`](skills/rigor-plugin-author/)
Skill authors a plugin step-by-step, and
[`rigor-baseline-reduce`](skills/rigor-baseline-reduce/) drives the
baseline down once you are running.

## Going deeper

Where a vanilla checker answers "what *class* is this?", Rigor answers
"what *subset of values* can this expression produce?" — literal
values (`Constant<"hello">`), integer ranges (`positive-int`),
refinements (`non-empty-string = String - ""`), tuple and known-key
hash shapes. Every narrower carrier erases to its base class for RBS
interop, so adopting Rigor is strictly additive. When you want to
*declare* more than RBS can say, optional `%a{rigor:v1:…}` annotations
in `sig/` files tighten types while staying a no-op for ordinary RBS
tools.

The twelve-chapter [handbook](https://rigor.typedduck.fail/reference/handbook/)
walks the whole type model; the
[type specification](https://rigor.typedduck.fail/reference/type-specification/)
and [user manual](https://rigor.typedduck.fail/reference/manual/) are
the reference companions.

## Status

Current release: **`v0.1.18`** (2026-06-11), with `v0.2.0` — the first
evaluation release — landing shortly. Rigor analyses real Ruby today:
the `0.1.x` line has been hardened against Mastodon, Redmine, and
GitLab FOSS, and the deliberately conservative rule catalogue grows
only as fast as the zero-false-positive bar allows. Release history:
[`CHANGELOG.md`](CHANGELOG.md) · forward-looking commitments:
[Roadmap](https://rigor.typedduck.fail/reference/roadmap/).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the `git clone` →
green-tests path and a map of the spec / ADR / skill documentation
contributors should read.

## License

Mozilla Public License Version 2.0. See [`LICENSE`](LICENSE).
