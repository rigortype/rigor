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
│           ├── acronyms.rb              ← static read of config/initializers/inflections.rb
│           ├── helper_table.rb          ← frozen `{helper => Entry}` value object + controller set
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
| `manifest(... config_schema:, produces:)` | Declares `routes_file` / `helper_paths` config + the `:helper_table` and `:reachability_roots` facts. |
| `Plugin::Base.producer :helper_table` | Caches the parsed helper table per `config/routes.rb` digest. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads `config/routes.rb` under the trusted scope; the digest feeds the cache descriptor. |
| `Plugin::Base#prepare(services)` | Publishes the helper table and the controller root set to `services.fact_store` (ADR-9 / ADR-102). |
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

## Reachability roots (ADR-102 WD3)

The second published fact is
`(plugin_id: "rails-routes", name: :reachability_roots)` — an
`Array<String>` of the controller classes the routes file dispatches
to. Its consumer is Rigor itself rather than another plugin:
`rigor unused` reads `:reachability_roots` from every loaded plugin
and seeds its mark-and-sweep with the union
([`docs/internal-spec/plugin.md`](../../docs/internal-spec/plugin.md)
documents the reserved fact name).

Composition happens in `RoutesParser::Context`: `#record_controller`
resolves a route's controller against the module chain in force
(`namespace`, `scope module:`, a `module:` option on a resource),
storing Rails' own `admin/users` path spelling; `#controller_class_names`
camelizes through `Plugin::Inflector` at the end of the parse and
respells the result through the acronyms `Acronyms.discover` read out
of `config/initializers/inflections.rb`.

Two decisions worth not re-litigating:

- **A nested resource does not inherit its parent's name.**
  `resources :users do resources :posts end` serves
  `PostsController`, which is why the module chain is a distinct
  frame key rather than being read off the helper-name prefix.
- **`only: []` is ambiguous and is disambiguated, not guessed.**
  `resource :secret, only: [] do post :rotate end` routes;
  `resources :groups, only: [] do resources :members end` does not.
  `RoutesParser#routed?` looks for an action the resource declares
  itself. Getting this wrong in the permissive direction
  over-supplies a root, which silently hides real dead code — the
  expensive direction per ADR-102 § Consequences.

**Out of scope for this slice:** controllers remapped by
`devise_for … controllers:`, `use_doorkeeper … controllers:`, or a
mounted Grape API. Helper-name recognition for all three is
unchanged; only their controller *roots* are absent.

## Future direction

- **Real-Rails alignment spec**: a future spec slice can compare
  the plugin's `HelperTable` against `rails routes -E`'s output for
  the same `config/routes.rb`, guarding against drift from
  upstream Rails' helper-name conventions.

## License

MPL-2.0, matching the parent Rigor project.
