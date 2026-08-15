# rigor-factorybot

Validates every `FactoryBot.create(:name, key: ...)` /
`.build(...)` / `.build_stubbed(...)` / `.attributes_for(...)`
/ `*_list` call against an index built from
`factory_search_paths` (default `["spec/factories",
"spec/factories.rb"]` covering both the modern multi-file
convention and the legacy single-file form). No FactoryBot
runtime dependency.

> **Using this plugin?** The user guide — recognised calls,
> diagnostics, configuration, and limitations — lives in the manual
> at
> [docs/manual/plugins/rigor-factorybot.md](../../docs/manual/plugins/rigor-factorybot.md).
> This README covers the plugin's internals.

## Phases (both landed)

| Phase | Surface |
| --- | --- |
| 1 (a) | Factory + attribute key validation (self-contained) |
| 1 (c) | AR column cross-check via `rigor-activerecord`'s `:model_index` (ADR-9 fact) |

Subsequent slices add traits, sequences, parent / child
factories, and dynamic factory names; each composes
additively under the same plugin id.

## Demo

```sh
cd plugins/rigor-factorybot/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

Demo ships `spec/factories/users.rb` (declares `:user` and
`:post`), a `demo.rb` exercising every recognised entry call, and
an `errors_demo.rb` triggering the `unknown-factory` /
`unknown-attribute` paths.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:, consumes:, produces:)` | declares the `factory_search_paths` knob (ADR-40 default), the optional `activerecord#:model_index` dependency for the AR cross-check, and the `:reachability_references` fact |
| `#prepare(services)` (ADR-9) | publishes the reachability references below |
| `Plugin::Base#io_boundary` (`read_file`) | reads `spec/factories` content under the trusted scope |
| `Plugin::Base.producer` + `#cache_for` | caches the per-run factory index (cache invalidates via `producer watch:`) |
| `node_rule` (ADR-37) | per-call validation over the engine-owned walk |
| `Plugin::Base.suggest` | did-you-mean for both `unknown-*` rules |
| `Plugin::Inflector` (ADR-39) | factory-name → model-class fallback (`camelize`) |

## Factory references for `rigor unused`

A factory names its model class by a mechanism the constant scan cannot follow: `factory :user, class: "Admin::User"` is a string, and a bare `factory :user` is FactoryBot's own constantization of the factory name. Neither leaves a constant node anywhere in the project, so without help [`rigor unused`](../../docs/manual/02-cli-reference.md#rigor-unused) reports a factoried model as dead.

The plugin publishes those model classes as the `:reachability_references` fact ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3), each carrying the `:test` role.

**References, not roots — and the distinction is the point.** Factories live in the test tree. Rooting them would make every factoried class *production*-reachable and erase ADR-102 WD8's "reachable only from tests" category for exactly the classes it is most likely to be about: a model kept alive by its factory and its spec and nothing else is the archetype of dead production code with a live test, and that is the most actionable row the report produces. Carrying the role keeps the finding — such a class leaves the candidate list, because something really does reach it, and appears under **Reachable only from test code** instead.

## License

MPL-2.0, matching the parent Rigor project.
