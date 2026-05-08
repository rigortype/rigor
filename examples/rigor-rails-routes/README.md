# rigor-rails-routes

The first Tier 1 plugin in Rigor's Rails ecosystem family
(per [`docs/design/20260508-rails-plugins-roadmap.md`](../../docs/design/20260508-rails-plugins-roadmap.md)).
Statically interprets `config/routes.rb` via Prism — no
Rails runtime dependency — and validates every `*_path` /
`*_url` call site against the resulting helper table.

## What the plugin recognises

Given a `config/routes.rb` like:

```ruby
Rails.application.routes.draw do
  root to: "home#index"

  resources :users do
    resources :posts
  end

  resource :profile

  namespace :admin do
    resources :widgets
  end

  get "/about", to: "static#about", as: :about
end
```

…the plugin recognises every helper Rails would generate:

```text
file:line:col info: `users_path` → GET /users
file:line:col info: `user_path` → GET /users/:id
file:line:col info: `user_post_path` → GET /users/:user_id/posts/:id
file:line:col info: `admin_widgets_path` → GET /admin/widgets
file:line:col info: `about_path` → GET /about
```

…and flags typos and arity mismatches:

```text
file:line:col error: no route helper `widgts_path` (did you mean `users_path`?)
file:line:col error: `user_path` expects 1 argument(s), got 3
file:line:col error: `admin_widget_path` expects 1 argument(s), got 0
```

Both `_path` and `_url` forms are recognised.

## Recognised DSL surface (v0.1.0)

- `Rails.application.routes.draw do ... end`
- `resources :name [, only: [...] | except: [...]]`
- `resource :name` (singular, no `:id` segment, no `:index`)
- `get/post/patch/put/delete "/path", to: "...", as: :name`
- `root to: "..."` / `root "..."`
- One level of `namespace :foo do ... end`
- One level of nested `resources` (`resources :users do; resources :posts; end`)
- `member do ... end` / `collection do ... end` (descended into; explicit `as:` inside required for naming)

## Out of scope (v0.1.0)

- `scope :path:` / `scope :module:` / `scope :as:`
- Constraints (`constraints: { id: /\d+/ }`)
- Mountable engines (`mount Sidekiq::Web => "/sidekiq"`)
- Custom `direct(:name) { |obj| ... }`
- Format restrictions
- Custom inflections (`fish` ↔ `fish`, `child` ↔ `children`).
  The built-in inflector handles `posts` ↔ `post`,
  `users` ↔ `user`, `categories` ↔ `category`,
  `boxes` ↔ `box`. Edge cases need a hand-written RBS for
  the affected helper.

## Layout

```text
examples/rigor-rails-routes/
├── README.md
├── rigor-rails-routes.gemspec
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
cd examples/rigor-rails-routes/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:, produces:)` | Declares optional `routes_file` config + `:helper_table` fact for downstream consumers. |
| `Plugin::Base.producer :helper_table` | Caches the parsed helper table per `config/routes.rb` digest. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads `config/routes.rb` under the trusted scope; the digest feeds the cache descriptor. |
| `Plugin::Base#prepare(services)` | Publishes the helper table to `services.fact_store` (ADR-9) so `rigor-actionpack` Phase 4 can consume it. |
| `Plugin::Base#diagnostics_for_file` | Per-file analyser walks `*_path` / `*_url` calls and emits info / error diagnostics. |

## Cross-plugin fact

The plugin publishes its parsed `HelperTable` as
`(plugin_id: "rails-routes", name: :helper_table)`. The
fact's value is a frozen `Hash{helper_name → {arity:,
path:, http_method:, action:, name:}}` that downstream
consumers can read via `services.fact_store.read`. This
is the `manifest(produces:)` half of the ADR-9 contract;
no consumer plugin reads it yet, but the data shape is
stable for the upcoming `rigor-actionpack` Phase 4.

## Future direction

- **Tier 1A → Tier 2 dependency**: `rigor-actionpack`
  Phase 4 will consume `:helper_table` to validate
  `redirect_to user_path(@user)` calls inside controllers
  (where the helper table needs to flow across files).
- **Wider DSL surface**: `scope :path:` /
  `scope :module:` / `scope :as:` are next in line.
  Constraints / mountable engines / custom `direct` are
  later.
- **Real-Rails alignment**: a future spec slice can
  compare the plugin's `HelperTable` against
  `rails routes -E`'s output for the same
  `config/routes.rb`, ensuring no drift from upstream
  Rails' helper-name conventions.

## License

MPL-2.0, matching the parent Rigor project.
