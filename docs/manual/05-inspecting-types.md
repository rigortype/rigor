# Inspecting inferred types

Rigor's analysis is invisible by default — it only speaks up to
report a diagnostic. When you want to *see* what type the
engine assigns an expression, there are four tools: two source
helpers and two CLI commands.

## `dump_type` — print a type from source

`dump_type(expr)` makes Rigor emit an `info`-severity
`dump.type` diagnostic showing the inferred type of `expr`. At
runtime it is a no-op that returns `expr` unchanged, so it is
safe to leave in or sprinkle freely while debugging.

```ruby
require "rigor/testing"
include Rigor::Testing

dump_type(1 + 2)   # rigor reports: dump.type — Constant<3>
```

Rigor recognises the call when it is written as `dump_type(…)`
after `include Rigor::Testing`, or fully qualified as
`Rigor::Testing.dump_type(…)` / `Rigor.dump_type(…)`.

## `assert_type` — pin a type in source

`assert_type("TypeString", expr)` compares `expr`'s inferred
type against the literal type string. On a mismatch Rigor
emits an `error`-severity `assert.type-mismatch` diagnostic; on
a match it stays silent. Like `dump_type`, it returns `expr`
unchanged at runtime.

```ruby
assert_type("Constant<3>", 1 + 2)   # silent — matches
assert_type("Integer",     1 + 2)   # assert.type-mismatch
```

The type string is matched against the engine's short display
form. `assert_type` is how the handbook's examples stay honest,
and it doubles as a regression check you can keep in a
project's own test sources.

## `rigor annotate` — types in the margin

`rigor annotate FILE` reprints a whole file with every line
tagged by the type of the expression it evaluates to, as a
trailing `#=> dump_type:` comment:

```ruby
two = 1 + 1   #=> dump_type: 2
name = gets   #=> dump_type: String | nil
```

It is the fastest way to survey a file. The annotation is
idempotent — re-running replaces the previous comment rather
than stacking it. Output is syntax-highlighted for a tty;
`--no-color` (and the `NO_COLOR` environment variable) disable
the colour.

## `rigor type-of` — one position

When you only need one expression's type — typically while
chasing down why a diagnostic did or did not fire — query a
single position:

```sh
rigor type-of lib/example.rb:12:8
```

`--format=json` emits a machine-readable result for tooling.
This is the same query the editor integration answers on
hover.

## `rigor trace` — watch the inference happen

Where `annotate` and `type-of` show the *answer*, `rigor trace
FILE` shows the *derivation*: it re-runs the engine over the
file and replays the recorded inference events as a
step-through terminal animation — the moment a local enters the
scope, the moment two branch types merge into a union, the
moment a method call resolves (or fail-softens to
`Dynamic[top]`).

```sh
rigor trace lib/example.rb            # step on key press
rigor trace --delay=0.5 lib/example.rb # autoplay
rigor trace --format=json lib/example.rb # raw event stream
```

`--verbose` adds an enter/result frame for every expression the
typer visits; the default keeps only the three teachable event
kinds. The JSON stream is stable enough to build course
material or figures from.

## Which to reach for

| You want… | Use |
| --- | --- |
| One expression's type, from the shell | `rigor type-of` |
| Every line of a file surveyed | `rigor annotate` |
| The derivation replayed step by step | `rigor trace` |
| A type printed mid-analysis, in context | `dump_type` |
| A type *asserted* and regression-checked | `assert_type` |
