# Getting started

[← Handbook index](README.md) · Next: [Everyday types →](02-everyday-types.md)

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
- a few more, all listed in
  [Chapter 8 — Understanding errors](08-understanding-errors.md).

Critically, Rigor does **not** ask you to write type
annotations in your Ruby source. It infers as much as it can,
and stays silent everywhere it cannot prove a narrower type.
A diagnostic only fires when Rigor has enough static
information to be confident.

## The smallest working session

Drop into your project root and run:

```sh
bundle exec rigor check lib
```

That walks every `.rb` under `lib/` and prints diagnostics —
or `No diagnostics` when the analyzer found nothing to
complain about.

If you want to run on a single file:

```sh
bundle exec rigor check path/to/file.rb
```

If you want to see what Rigor inferred at a precise position:

```sh
bundle exec rigor type-of lib/foo.rb:10:5
```

That prints both the rich Rigor type and the conservative
RBS erasure (the type a non-Rigor RBS tool would see). It is
the fastest way to ask "what does Rigor think this expression
produces?"

## Reading a diagnostic

Rigor diagnostics look like this:

```text
lib/user.rb:42:7: error: undefined method `upcas' for "alice" [call.undefined-method]
```

| Slice | Meaning |
| --- | --- |
| `lib/user.rb:42:7` | File, 1-indexed line, 1-indexed column |
| `error` | Severity (`error` / `warning` / `info`) |
| `undefined method ...` | Human-readable message |
| `[call.undefined-method]` | The qualified rule identifier |

The qualified rule identifier is what you use in:

- `# rigor:disable call.undefined-method` (in-source
  suppression at end of line);
- the `disabled_rules:` key in `.rigor.yml`;
- the `severity_overrides:` map (to demote a rule to
  `:warning` or `:info`, or drop it entirely with `:off`).

Family wildcards work: `# rigor:disable call` suppresses every
`call.*` rule on that line. The full list of families and
rules is in [Chapter 8 — Understanding
errors](08-understanding-errors.md).

## The "no annotations" stance

Most static checkers ask the user to annotate types. Rigor
does the opposite — it looks at what your Ruby code does and
**proves** types from the values themselves. Three quick
examples:

```ruby
n = 100
m = n + 1
assert_type(m, "Constant<101>")     # arithmetic folds
```

```ruby
def kind(x)
  case x
  when Integer then :int
  when String  then :str
  end
end
assert_type(kind(7), "Constant<:int>")  # narrowing folds the case
```

```ruby
greeting = "Hello, "                 # Constant<"Hello, ">
name     = ARGV.first                # String?  (RBS-declared)
hello    = "#{greeting}#{name}!"     # literal-string carrier:
                                     # every interpolated part
                                     # is itself literal-string-
                                     # compatible, so the result
                                     # is "provably source-derived"
```

You did not write a single annotation. Rigor reasons about the
values directly.

When inference cannot prove a narrower type, the engine
returns `Dynamic[Top]` (the gradual carrier — "could be any
Ruby value") and stays silent. Rigor never invents
diagnostics it cannot prove.

## When inference is not enough

There are three escape hatches, in order of how often you
will need them:

1. **Add an `.rbs` file.** Drop a signature into `sig/` and
   Rigor picks it up automatically. This is the most common
   reason inference does not see further than the local
   `def` — the analyzer cannot reach inside an external gem
   without the gem's RBS.
2. **Tighten an existing RBS sig with `RBS::Extended`.** Add
   a `%a{rigor:v1:return: non-empty-string}` annotation
   above the method's `def ... -> ::String` line. Rigor
   sees the refinement; ordinary RBS tools see a comment.
3. **Write a plugin.** When your project has a domain DSL
   (`Lisp.eval`, `100.kilometers`, `transition_to(:foo)`)
   that no general-purpose analyzer can know about, a
   plugin teaches Rigor about it.

Chapters 7 and 9 cover these in detail. Most projects only
need (1) and (2).

## A first walk through `.rigor.yml`

`rigor init` writes a starter configuration:

```yaml
target_ruby: "3.4"

paths:
  - lib

# signature_paths: [sig]   # auto-detected when omitted

severity_profile: balanced

# severity_overrides:
#   call.argument-type-mismatch: warning

# disabled_rules: []

# plugins: []
```

The minimum useful run does not require a `.rigor.yml` at all
— `rigor check lib` works out of the box. The file is for
non-default behaviours: extra `paths`, alternative
`severity_profile`, project-wide rule disables, plugins.

## What's next

Chapter 2 introduces the carriers Rigor uses to represent
types — the part of the model that distinguishes Rigor from
ordinary RBS. After that, Chapter 3 (narrowing) makes the
carriers come alive: the carriers describe values, and
narrowing describes how those carriers change as control
flow passes through `if` / `case` / predicate methods.

[← Handbook index](README.md) · Next: [Everyday types →](02-everyday-types.md)
