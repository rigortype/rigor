# rigor-deprecations — example Rigor plugin

The smallest worked example of the v0.1.0 plugin authoring
surface. **Under 80 lines of plugin code** — no I/O, no
cache, no engine query — and the recommended starting point
for "I want to write my own Rigor plugin."

The plugin's value is **user-extensibility**: a user extends
Rigor's lint surface for their own deprecations by editing
`.rigor.yml`, with no plugin-side code. The plugin is the
engine; the rules are pure data.

## What the plugin recognises

```text
demo.rb:13:1: warning: `User.find_by_sql` is deprecated (since v6.0; use: where(...).to_sql or sanitize_sql) [plugin.deprecations.deprecated-call]
demo.rb:16:1: warning: `silence_warnings` is deprecated (since v7.0; use: Warning[:deprecated] = false) [plugin.deprecations.deprecated-call]
demo.rb:19:1: warning: `ActiveRecord::Base.with_lock` is deprecated (use: transaction { ... }) [plugin.deprecations.deprecated-call]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| configured deprecation matched | `:warning` | `deprecated-call` |

## Configuration

```yaml
plugins:
  - gem: rigor-deprecations
    config:
      methods:
        - method: find_by_sql                  # required
          receiver: User                       # optional — restricts match
          replacement: "where(...).to_sql or sanitize_sql"
          since: "v6.0"
        - method: silence_warnings
          replacement: "Warning[:deprecated] = false"
          since: "v7.0"
        - method: with_lock
          receiver: ActiveRecord::Base
          replacement: "transaction { ... }"
```

`receiver:` matches the literal source text of the call's
receiver:

| Receiver in code | `receiver:` in config | Match? |
| --- | --- | --- |
| `User.find_by_sql(…)` | `User` | ✓ |
| `User.find_by_sql(…)` | `Account` | ✗ |
| `ActiveRecord::Base.with_lock(…)` | `ActiveRecord::Base` | ✓ |
| `silence_warnings { … }` (no receiver) | omitted | ✓ |
| `silence_warnings { … }` (no receiver) | `Kernel` | ✗ |

Omitting `receiver:` matches every call to the named method
regardless of receiver — useful for global deprecations like
`silence_warnings`.

## Layout

```
rigor-deprecations/
├── README.md
├── rigor-deprecations.gemspec
├── lib/
│   ├── rigor-deprecations.rb
│   └── rigor/plugin/deprecations.rb     ← <80 lines
└── demo/
    ├── .rigor.yml
    └── demo.rb
```

## Running the demo

```sh
cd examples/rigor-deprecations/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| `manifest(... config_schema: { "methods" => :array })` | top of `Deprecations` |
| `#init(services)` parses config rows into frozen `Entry` Structs | `Deprecations#init` |
| `#diagnostics_for_file(path:, scope:, root:)` walks Prism, matches, emits | the rest of the file |
| `Prism::Node#slice` for receiver source-text comparison | `#receiver_source` private helper |

## Why this example matters

Of the worked examples, this is the one that maps most
directly to "Rigor as a user-extensible lint engine":

- **Lisp eval** types a literal AST argument
- **Units** propagates types through local-variable flow
- **Routes** reads project config files under TrustPolicy + cache
- **Pattern** queries Rigor's own type inference
- **Statesman** does two-pass DSL analysis
- **Deprecations** lets users write rules without writing code

Once a team has the plugin gem on their `Gemfile`, adding a
new deprecation is an `.rigor.yml` patch. Compared with
authoring a custom RuboCop cop or custom Steep validator,
the latency from "we want to flag X" to "X is flagged in CI"
shrinks to a single PR with a YAML diff.

## Compared with the other examples

| | lisp-eval | units | routes | pattern | statesman | **deprecations** |
| --- | --- | --- | --- | --- | --- | --- |
| Lines of plugin code | ~200 | ~280 | ~250 | ~180 | ~210 | **~80** |
| Manifest declaration | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| AST walking | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Local-variable flow | — | ✅ | — | — | — | — |
| `IoBoundary` (slice 2) | — | — | ✅ | — | — | — |
| `cache_for` / producer (slice 6) | — | — | ✅ | — | — | — |
| Engine collaboration (`Scope#type_of`) | — | — | — | ✅ | — | — |
| Two-pass DSL analysis | — | — | — | — | ✅ | — |
| **Pure config-driven rules** | — | — | — | — | — | ✅ |

## Future direction

Two natural extensions, neither needed for the example to be
useful today:

- **Severity per entry.** A `severity:` field on each rule
  (`error` / `warning` / `info`) lets users escalate critical
  deprecations. Currently the rule emits at `:warning`.
- **Argument-shape matching.** Match only when the call's
  arguments look a specific way (`receiver: Time`,
  `method: parse`, `arg_count: 1` to flag deprecated
  single-arg `Time.parse(s)`). This intersects with the
  `rigor-pattern` example's literal-argument inspection.

## License

MPL-2.0, matching the parent Rigor project.
