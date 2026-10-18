# Inspecting inferred types

Rigor's analysis is invisible by default — it only speaks up to
report a diagnostic. When you want to *see* what type the
engine assigns an expression, there are six tools: two source
helpers and four CLI commands.

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
trailing `#=>` comment (the xmpfilter / seeing_is_believing
convention):

```ruby
two = 1 + 1   #=> 2
name = gets   #=> String | nil
```

It is the fastest way to survey a file. The annotation is
idempotent — re-running replaces the previous `#=>` comment
(including hand-written ones, and the pre-v0.2.0
`#=> dump_type:` spelling) rather than stacking it. Output is
syntax-highlighted for a tty — through
[`bat`](https://github.com/sharkdp/bat) when it is found on
`PATH` (`--no-bat` opts out), otherwise via the built-in
colorizer; `--no-color` (and the `NO_COLOR` environment
variable) disable the colour.

## `rigor type-of` — exact positions or a whole line

When you need a few expression types — typically while chasing
down why a diagnostic did or did not fire — query the exact
positions together so Rigor loads the project and each source
file once:

```sh
rigor type-of lib/example.rb:12:8 lib/example.rb:12:14
```

Leave off the column to avoid counting it by hand. Rigor prints
a table of the first 40 expressions starting on the line,
outermost first at each 1-based column, and marks a truncated
table:

```sh
rigor type-of lib/example.rb:12
```

`--format=json` emits a machine-readable result for tooling: one
result stays a flat object, while several results use a `results`
array. Line queries add `line_enumerations` metadata with the
shown and total expression counts. An exact position is the same
query the editor integration answers on hover.

Inside a `rescue` or `ensure` clause, `type-of` and hover can
disagree with `rigor check`. `check` reads a variable that the
`begin` body assigns as untyped there, because the clause may run
after the body raised partway through. `type-of` shows the value
the variable had before the `begin`. In
`conn = nil; begin; conn = open_conn; work; rescue; conn.close; end`,
`type-of` reports `conn` as `nil` and `check` reports nothing.

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

## `rigor lens` — a file's declarations and where their types come from

`rigor lens` lists every class, module, method and attribute a
file declares, with the type each one has and where that type
came from: `sig/`, an inline `#:` / `@rbs` comment, a plugin, a
library, or Rigor's inference from the body. It is experimental:
the command and its `lens/v0` JSON may still change.

```sh
rigor lens lib/shop.rb                    # text, for reading
rigor lens --format=json lib/*.rb         # one JSON document
```

```text
lib/shop.rb  xxh3-64:845f7426b6acfe12  (2 omitted)
  4:7c90  class Shop
  8:e37e  Shop#label: (::Integer n) -> ::String  [contract inline]
  14:ce93  Shop#total: () -> Integer  [single_site inferred]
  16:182b  Shop#fetch  [contested; also lib/legacy_shop.rb:2]
  omitted constant Shop::LIMIT (line 5)
```

The answer is the one `rigor check` reaches. A lens runs the
same incremental analysis as `rigor check --incremental` and
shares its cache, so the first run costs a full check and later
runs reuse it. The diagnostics it reports for a file are the
ones `check` reports.

- A method Ruby could take from more than one definition (the
  same method defined in two files) is `contested`. Rigor does
  not guess which one runs, so it prints no signature for it.
- A declaration this version does not model yet (a constant, an
  `alias`, a `define_method`) is listed as omitted, never
  dropped.
- `LINE:HASH` is an anchor: it changes when the declaration or
  the type comments above it change, and not when prose
  comments do.

The JSON document is specified in
[the lens output contract](../internal-spec/lens.md).

## Which to reach for

| You want… | Use |
| --- | --- |
| One expression's type, from the shell | `rigor type-of` |
| A file's declarations, their types and where each came from | `rigor lens` |
| Every line of a file surveyed | `rigor annotate` |
| The derivation replayed step by step | `rigor trace` |
| A type printed mid-analysis, in context | `dump_type` |
| A type *asserted* and regression-checked | `assert_type` |
