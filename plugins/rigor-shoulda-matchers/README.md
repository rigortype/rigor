# rigor-shoulda-matchers

Rigor plugin that validates [shoulda-matchers](https://github.com/thoughtbot/shoulda-matchers)
calls against the `:model_index` cross-plugin fact
([ADR-9](../../docs/adr/9-cross-plugin-api.md)) published by
[`rigor-activerecord`](../rigor-activerecord/). It walks every
`RSpec.describe <ModelConst> do … end` block and validates the shoulda
matchers inside against the model's known columns / associations.

> **Using this plugin?** The user guide — the matcher families, the
> diagnostic catalogue, configuration, and limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-shoulda-matchers.md](../../docs/manual/plugins/rigor-shoulda-matchers.md).
> This README covers the plugin's internals.

## Cross-plugin dependency

The plugin consumes `:model_index` from `rigor-activerecord` (declared
`optional: true` on the manifest). When `rigor-activerecord` is **not**
loaded — or hasn't published an index for the analysed model — the
fact-store read returns `nil` and the plugin falls silent. The
cross-check is opt-in; both plugins must be active:

```yaml
plugins:
  - rigor-activerecord     # publishes :model_index
  - rigor-shoulda-matchers # consumes it
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... consumes:)` | Declares the optional `:model_index` dependency on `rigor-activerecord` (ADR-9). |
| `node_rule(Prism::CallNode)` + `NodeContext` (ADR-37) | Per-matcher validation; `context.ancestors` resolves the enclosing `describe <Model>` (innermost wins) to anchor the cross-check. |
| `@services.fact_store.read` | Lazily reads `:model_index`; returns `nil` (silent) when the producer isn't loaded. |
| `Plugin::Base#diagnostic` | Emits the warning at the matcher's message location. |

The analyzer's rule strings are bare (`unknown-column` /
`unknown-association` / `association-kind-mismatch`); the runner
stamps the `plugin.shoulda-matchers` provenance, so the qualified
rule ids are `plugin.shoulda-matchers.<rule>`.

## Layout

```text
plugins/rigor-shoulda-matchers/
├── README.md
├── lib/
│   ├── rigor-shoulda-matchers.rb
│   └── rigor/plugin/
│       ├── shoulda_matchers.rb               ← Plugin::ShouldaMatchers class
│       └── shoulda_matchers/
│           └── analyzer.rb                   ← describe-walker + matcher recognizer
└── demo/
    ├── .rigor.yml
    └── spec/
        └── user_spec.rb                      ← worked example
```

## License

MPL-2.0, matching the parent Rigor project.
