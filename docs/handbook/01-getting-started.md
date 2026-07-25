# Getting started

By the end of this chapter you will be able to:

- get `rigor` onto your `PATH` (the fast AI-assisted way, or
  by hand);
- run `rigor check` and read the diagnostics it prints;
- understand the "no annotations needed" stance that sets
  Rigor apart from most checkers, and the escape hatches for
  when inference falls short.

It is the only chapter you must read top to bottom. The rest
of the handbook is reference you can dip into later.

## Installing Rigor

Rigor is a tool, not a library — like a linter or a compiler, it
analyses your project but is not part of its runtime. **Do not add
it to your application's `Gemfile`.** Install it on its own and
point it at your project.

Rigor itself runs on Ruby 4.0, independently of the Ruby your own
code targets. The [`target_ruby:` config key](#the-config-file)
tells Rigor which Ruby *your* project runs.

### The fast path: let an AI agent set it up

If you work with an AI coding agent (Claude Code or any assistant
that supports [Agent Skills](https://agentskills.io/)), hand it
this prompt:

```
Install Rigor in this project by following the instructions at
https://raw.githubusercontent.com/rigortype/rigor/refs/heads/master/docs/install.md
```

The agent detects your environment, installs Rigor, then runs the
**`rigor-project-init` skill** — which walks your `Gemfile`,
proposes a plugin set matched to your framework, picks an adoption
mode, and writes `.rigor.dist.yml` for you. No manual YAML editing.
This is the recommended path; the [config file](#the-config-file)
section below shows what the skill produces so you can read and
tweak it afterwards.

The same prompt is available in sixteen languages in the
[Rails quickstart](../manual/14-rails-quickstart.md#step-1--install-ruby-40-and-rigor-common-to-both-paths).

### The manual path: mise

If you prefer to drive the setup yourself, the recommended runtime
version manager is [`mise`](https://mise.jdx.dev/), which
provisions both Ruby 4.0 and Rigor:

```sh
mise use ruby@4.0
mise use gem:rigortype
```

With mise activated in your shell, `rigor` is on your `PATH`. The
gem is named `rigortype` (the name `rigor` was taken on RubyGems);
the executable it installs is `rigor`. If you already have Ruby
4.0, `gem install rigortype` works too.

For shell activation and shims, `asdf`, and developing inside a
container, see [Installing Rigor](../manual/01-installation.md);
for continuous integration, see
[Running Rigor in CI](../manual/11-ci.md).

## What does `rigor check` look at?

Rigor reads your `.rb` files, runs a flow-sensitive type
inference engine over each one, consults any `sig/*.rbs`
declarations available to your project, and reports a small
catalogue of bugs:

- methods called on the wrong receiver class;
- methods called with the wrong number of arguments;
- arithmetic that can be proved to raise (`5 / 0`);
- arguments whose type does not satisfy a refined parameter
  contract;
- a few more, all catalogued in
  [manual — Diagnostics](../manual/04-diagnostics.md) and
  explained in
  [Chapter 8 — Understanding errors](08-understanding-errors.md).

Rigor does **not** ask you to write type annotations in
your Ruby source. It infers as much as it can, and stays
silent everywhere it cannot prove a narrower type.
A diagnostic only fires when Rigor has enough static
information to be confident.

Where a *signature* does appear in this book — like
`def foo: (String) -> Integer` — that is **RBS**, Ruby's standard
signature language; read it as "takes a `String`, returns an
`Integer`." You write none of it to get started; Rigor consumes
whatever RBS your gems and the standard library already ship.
[Chapter 7](07-rbs-and-extended.md) covers RBS in full — if you
have never seen it, skim that chapter first.

## The smallest working session

Drop into your project root and run:

```sh
rigor check lib
```

That walks every `.rb` under `lib/`. When the analyzer finds
nothing to complain about, it prints `No diagnostics` and
exits `0`:

```text
No diagnostics
```

When it does find something, each diagnostic is one line. Given
this file:

```ruby
# lib/demo.rb
"hello".no_such_method        # typo'd method name
[1, 2, 3].rotate(1, 2)        # too many arguments
```

`rigor check lib/demo.rb` prints:

```text
lib/demo.rb:1:9: error: undefined method `no_such_method' for "hello" [call.undefined-method]
lib/demo.rb:2:11: error: wrong number of arguments to `rotate' on Array (given 2, expected 0..1) [call.wrong-arity]
```

To run on a single file, pass the file instead of a directory:

```sh
rigor check path/to/file.rb
```

And to ask what Rigor inferred at one precise position:

```sh
rigor type-of lib/foo.rb:10:5
```

That prints both the rich Rigor type and the conservative
RBS erasure (the type a non-Rigor RBS tool would see). It is
the fastest way to ask "what does Rigor think this expression
produces?"

## Reading a diagnostic

Take the first line from the run above:

```text
lib/demo.rb:1:9: error: undefined method `no_such_method' for "hello" [call.undefined-method]
```

| Slice | Meaning |
| --- | --- |
| `lib/demo.rb:1:9` | File, 1-indexed line, 1-indexed column |
| `error` | Severity (`error` / `warning` / `info`) |
| `undefined method ...` | Human-readable message |
| `[call.undefined-method]` | The qualified rule identifier |

The qualified rule identifier is the handle you use to silence,
demote, or look up a rule. The quickest is an in-source comment
on the offending line:

```ruby
"hello".no_such_method  # rigor:disable call.undefined-method
```

The same identifier also drives the `disable:` and
`severity_overrides:` config keys, and family wildcards work
(`# rigor:disable call` suppresses every `call.*` rule on that
line). The full list of families and rules is in
[manual — Diagnostics](../manual/04-diagnostics.md);
[Chapter 8 — Understanding errors](08-understanding-errors.md)
is where to read about choosing between the suppression
mechanisms.

## The "no annotations" stance

Most static checkers ask the user to annotate types. Rigor
does the opposite: it looks at what your Ruby code does and
**proves** types from the values themselves. Three quick
examples:

```ruby
n = 100
m = n + 1
assert_type("101", m)     # arithmetic folds
```

```ruby
def kind(x)
  case x
  when Integer then :int
  when String  then :str
  end
end
assert_type(":int | :str | nil", kind(7))  # union of all case branches
```

```ruby
greeting = "Hello, "                 # Constant<"Hello, ">
name     = ARGV.first                # String?  (String or nil — RBS-declared)
hello    = "#{greeting}#{name}!"     # literal-string carrier:
                                     # every interpolated part
                                     # is itself literal-string-
                                     # compatible, so the result
                                     # is "provably source-derived"
```

You did not write a single annotation. Rigor reasons about the
values directly.

> The `assert_type(...)` line is Rigor's introspection helper,
> not a runtime check — it pins the inferred type at that point
> so you can compare the prose to the analyzer's actual output.
> See [How to read this handbook](README.md#how-to-read-this-handbook)
> for the full snippet convention.

When inference cannot prove a narrower type, the engine
returns `Dynamic[top]` (the gradual carrier — "could be any
Ruby value") and stays silent. Rigor never invents
diagnostics it cannot prove.

## When inference is not enough

*First read? Skip this section.* Out of the box, inference plus
any RBS your gems already ship covers most code, and the next
chapters teach you to read what it produces. Come back here when
Rigor resolves something to `Dynamic[top]` that you wish it knew
more about. For most projects only escape hatches (1) and (2)
ever come up.

There are five escape hatches, in rough order of how often you
will need them:

1. **Add an `.rbs` file.** Drop a signature into `sig/` and
   Rigor picks it up automatically. This is the most common
   reason inference does not see further than the local
   `def` — by default the analyzer treats every external gem
   as `Dynamic[top]` unless the gem ships RBS or you
   opt in to gem-source inference per (4) below.
2. **Tighten an existing RBS sig with `RBS::Extended`.** Add
   a `%a{rigor:v1:return: non-empty-string}` annotation
   above the method's `def ... -> ::String` line. Rigor
   sees the refinement; ordinary RBS tools see a comment.
3. **Write a plugin.** When your project has a domain DSL
   (`Lisp.eval`, `100.kilometers`, `transition_to(:foo)`)
   that no general-purpose analyzer can know about, a
   plugin teaches Rigor about it.
4. **Opt in to gem-source inference.** When a no-RBS gem's
   methods would otherwise resolve to `Dynamic[top]`, list
   the gem under `dependencies.source_inference:` in
   `.rigor.dist.yml` and Rigor will walk its `lib/` the same way
   it walks project source. Returns are wrapped in
   `Dynamic[T]` so the call site retains the provenance.
   See [ADR-10](../adr/10-dependency-source-inference.md)
   for the trade-offs (per-gem opt-in by design — broad
   defaults would inflate budgets and make `bundle update`
   noisy).
5. **Use the `rigor-sorbet` adapter.** If your project
   already uses [Sorbet](https://sorbet.org/), Rigor can
   read your existing `sig { ... }` blocks, RBI files, and
   `T.let` / `T.cast` / `T.must` / `T.unsafe` assertions
   as type sources without rewriting anything. See
   [Chapter 10](10-sorbet.md) for the migration patterns
   and the translation table.

Chapters 7 and 9 cover (1)–(3) in detail; chapter 10 covers
(5).

## The config file

The minimum useful run needs no config file at all —
`rigor check lib` works out of the box. A config file is for
non-default behaviours: extra `paths`, an alternative
`severity_profile`, project-wide rule disables, plugins.

If you used the [AI-assisted setup](#the-fast-path-let-an-ai-agent-set-it-up),
the `rigor-project-init` skill already wrote one for you. To
write a starter by hand, `rigor init` emits `.rigor.dist.yml`
— the project default that gets committed, with `target_ruby`,
`paths`, and a `severity_profile` filled in and the rest
commented out. That is all most projects need; the key
reference, the JSON-schema editor integration, and `includes:`
composition are in
[Configuration](../manual/03-configuration.md).

Two things are worth knowing up front, because they surprise
people. `target_ruby` is *your project's* Ruby, not the 4.0
Rigor itself runs on — those are independent on purpose. And
when a developer keeps a local `.rigor.yml`, it is the *sole*
source of config for their runs (the two files are never merged
automatically), so to extend the shared default it must list it
under `includes:`.

## What's next

Chapter 2 introduces the carriers Rigor uses to represent
types — the part of the model that distinguishes Rigor from
ordinary RBS. After that, Chapter 3 (narrowing) makes the
carriers come alive: the carriers describe values, and
narrowing describes how those carriers change as control
flow passes through `if` / `case` / predicate methods.
