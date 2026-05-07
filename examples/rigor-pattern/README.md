# rigor-pattern — example Rigor plugin

Reference example for **plugin → analyzer collaboration**.
Where the earlier examples reimplement what they need (Lisp's
type interpreter, units' dimension tracker, routes' YAML
parse), `rigor-pattern` **asks Rigor's type system** whether
each `validate(:name, value)` call's `value` argument is
provably a literal string, and runs the configured regex
against the literal value at lint time.

The key surfaces:

| Surface | Used in this plugin |
| --- | --- |
| `Scope#type_of(node)` | Per-call query against the analyzer's inference engine |
| `Type::Combinator.literal_string_compatible?(type)` | Predicate the v0.0.9 literal-string carrier publishes |
| `Type::Constant#value` | Exact-value extraction when the type is a `Constant<String>` |

What this means in practice: when the user writes
`validate(:email, "user" + "@example.com")`, the plugin does
**not** walk the `+` call manually. Rigor's
`LiteralStringFolding` tier already lifts all-Constant
concatenation chains into a `Constant<"user@example.com">`,
and the plugin reads that fact back through `type_of`.

## What the plugin recognises

```text
demo.rb:18:18: info: literal "user@example.com" matches :email [plugin.pattern.literal-match]
demo.rb:19:18: error: literal "not-an-email" does not match :email (\A[^\s@]+@[^\s@]+\z) [plugin.pattern.literal-mismatch]
demo.rb:25:18: info: literal "user@example.com" matches :email [plugin.pattern.literal-match]   ← from "user" + "@example.com"
demo.rb:28:1:  error: no pattern named :zip in plugin config (declared: :email, :uuid) [plugin.pattern.unknown-pattern]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| literal arg matches the named pattern | `:info` | `literal-match` |
| literal arg does NOT match the named pattern | `:error` | `literal-mismatch` |
| arg is provably literal-string but exact value unknown | `:info` | `literal-unknown` |
| call site references an unknown pattern name | `:error` | `unknown-pattern` |

Calls whose `value` argument is **not** provably a literal
(e.g. `validate(:email, params[:email])`) stay silent — the
plugin defers to runtime for those.

## Configuration

```yaml
plugins:
  - gem: rigor-pattern
    config:
      method_name: validate     # default; optional
      patterns:
        email: '\A[^\s@]+@[^\s@]+\z'
        uuid:  '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
```

`config_schema` declares `patterns:` as `:hash`, so the plugin
manifest validation accepts arbitrary nested keys.
Each value is compiled to a `Regexp` once during `#init`;
syntactically-invalid regexes raise from `init` and surface as
`:plugin_loader load-error` diagnostics through the runner's
loader-failure isolation path.

## Layout

```
rigor-pattern/
├── README.md
├── rigor-pattern.gemspec
├── lib/
│   ├── rigor-pattern.rb
│   └── rigor/plugin/pattern.rb     ← manifest, init, hook, walker
└── demo/
    ├── .rigor.yml                  ← plugin config with patterns:
    ├── demo.rb                     ← validate(...) calls
    └── lib/validators.rb           ← runtime: validate(name, value)
```

## Running the demo

```sh
cd examples/rigor-pattern/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

## Why this surface matters

A plugin that wants to reason about literal strings has two
choices: (1) walk the AST and reimplement string folding, or
(2) ask Rigor's already-proven inference engine. Option (2)
inherits every literal-string improvement Rigor lands going
forward — interpolation folding, `String#format`, `String#%`,
`Array#join`, etc. — without changes to the plugin.

This is the architectural template for plugins that **consume**
analyzer-inferred facts rather than **produce** them. Other
candidates: integer-range queries, refined-string predicates,
and (once it lands) plugin return-type contributions composing
through `FlowContribution::Merger`.

## Compared with the other examples

| | lisp-eval | units | routes | **pattern** |
| --- | --- | --- | --- | --- |
| AST walking | ✅ | ✅ | ✅ | ✅ |
| Local-variable flow | — | ✅ | — | — |
| `IoBoundary` (slice 2) | — | — | ✅ | — |
| `cache_for` / producer (slice 6) | — | — | ✅ | — |
| `Scope#type_of` engine query | — | — | — | ✅ |
| `literal_string_compatible?` predicate | — | — | — | ✅ |
| Rich `config_schema` (`:hash`) | — | — | — | ✅ |

## Future direction — lightweight HKT

As of v0.1.2 the plugin already supplies a return type at the
call site through `#flow_contribution_for`: on a successful
match the runtime `validate` returns the value argument, so
the plugin contributes the argument's type (typically
`Constant<String>`) as the call site's return type. Mismatches
keep the existing `literal-mismatch` `:error` diagnostic and
stay at the RBS-level untyped — propagating `bot` would silence
the diagnostic-driven feedback the README centres on.

The remaining open surface is **lightweight HKT** — the
type-level computation that lets the same predicate live on
the RBS sig itself:

```rbs
def validate: [N : Symbol, V <: literal-string]
  (N, V) -> (matches[N, V] ? V : bot)
```

With that lands, the regex check moves out of the plugin and
into a Rigor-side type function, the runtime `validate` keeps
its `raise` behaviour, and the analyzer proves at the call
site that the input is statically known to satisfy the pattern
without consulting the plugin.

## License

MPL-2.0, matching the parent Rigor project.
