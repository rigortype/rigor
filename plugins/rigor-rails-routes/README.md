# rigor-rails-routes

The first Tier 1 plugin in Rigor's Rails ecosystem family
(per [`docs/design/20260508-rails-plugins-roadmap.md`](../../docs/design/20260508-rails-plugins-roadmap.md)).
Statically interprets `config/routes.rb` via Prism — no
Rails runtime dependency — and validates every `*_path` /
`*_url` call site against the resulting helper table.

> **Using this plugin?** The user guide — recognised routing DSL,
> configuration (`routes_file` / `helper_paths`), and limitations —
> lives in the manual at
> [docs/manual/plugins/rigor-rails-routes.md](../../docs/manual/plugins/rigor-rails-routes.md).
> This README covers the plugin's internals and the contract
> surfaces it exercises.

## Layout

```text
plugins/rigor-rails-routes/
├── README.md
├── lib/
│   ├── rigor-rails-routes.rb
│   └── rigor/plugin/
│       ├── rails_routes.rb              ← plugin entry: manifest, hooks, fact publication
│       └── rails_routes/
│           ├── helper_table.rb          ← frozen `{helper => Entry}` value object
│           ├── routes_parser.rb         ← Prism DSL interpreter
│           └── analyzer.rb              ← per-call validation (info / error)
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── config/routes.rb                 ← real Ruby DSL
    ├── demo.rb                          ← every recognised helper
    └── errors_demo.rb                   ← typo + arity errors
```

## Running the demo

```sh
cd plugins/rigor-rails-routes/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:, produces:)` | Declares `routes_file` / `helper_paths` config + the `:helper_table` fact for downstream consumers. |
| `Plugin::Base.producer :helper_table` | Caches the parsed helper table per `config/routes.rb` digest. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads `config/routes.rb` under the trusted scope; the digest feeds the cache descriptor. |
| `Plugin::Base#prepare(services)` | Publishes the helper table to `services.fact_store` (ADR-9). |
| `node_rule` (ADR-37) | Per-call validation runs over the engine-owned walk; emits info / error diagnostics. |
| `Plugin::Inflector` (ADR-39) | Model↔route inflection via the real `ActiveSupport::Inflector`. |

## Cross-plugin fact

The plugin publishes its parsed `HelperTable` as
`(plugin_id: "rails-routes", name: :helper_table)` — a frozen
`Hash{helper_name → {arity:, path:, http_method:, action:,
name:}}`. `rigor-actionpack` consumes it (via
`services.fact_store.read`) to validate helper calls inside
controllers, where the helper table must flow across files. This
is the `manifest(produces:)` half of the ADR-9 contract.

## Future direction

- **Real-Rails alignment spec**: a future spec slice can compare
  the plugin's `HelperTable` against `rails routes -E`'s output for
  the same `config/routes.rb`, guarding against drift from
  upstream Rails' helper-name conventions.

## License

MPL-2.0, matching the parent Rigor project.
