# rigor-actionpack (Phase 4 — route-helper consumption)

The first **Tier 2** plugin in Rigor's Rails ecosystem family
and the first concrete consumer of the [ADR-9 cross-plugin
API](../../docs/adr/9-cross-plugin-api.md). Reads the
`:helper_table` fact published by
[`rigor-rails-routes`](../rigor-rails-routes/) and validates
every implicit-self `*_path` / `*_url` call inside files
under `controller_search_paths` (default `app/controllers`).

The full Action Pack plugin spans four phases per the
[Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md):

| Phase | Surface | Status |
| --- | --- | --- |
| 1 | Strong parameters → AR column validation | pending |
| 2 | **Filter chains** (`before_action :name`) | **landed** |
| 3 | **Render targets** (`render :show`) | **landed** |
| 4 | **Route-helper consumption** (`redirect_to user_path(@user)`) | **landed** |

Each phase composes additively under the same plugin id. This
plugin ships as Phase 4 only — the remaining phases land as
separate slices and surface their own diagnostic families
(`plugin.actionpack.permit-mismatch`,
`plugin.actionpack.missing-filter`, etc.).

## What the plugin recognises

```ruby
class UsersController
  def show
    redirect_to user_path(@user)        # ✓ recognised — info trace
    redirect_to user_post_path(@u, @p)  # ✓ recognised — arity 2
    redirect_to admin_widget_path(@w)   # ✓ recognised — namespaced
    redirect_to user_url(@user)         # ✓ _url form recognised
  end
end
```

Helper-table consultation:

```text
demo/app/controllers/users_controller.rb:6:18: info: Action Pack helper
   `users_path` → GET /users (action: index). [plugin.actionpack.helper-call]
```

Three call shapes per file:

- bare helper (`users_path`)
- positional arg (`user_path(@user, format: :json)`) — keyword
  arguments don't count against arity (matches the convention
  `rigor-rails-routes` uses to record arity).
- multiple args (`user_post_path(@user, @post)`).

`*_path` / `*_url` calls **with an explicit receiver** are
silently passed through. `Rails.application.routes.url_helpers.users_path`
and similar are framework idioms the plugin doesn't validate
(they're rare in controller code and the helper table doesn't
record any extra context for them).

## Diagnostics

| Rule | Severity | Phase | Fires when |
| --- | --- | --- | --- |
| `plugin.actionpack.helper-call` | info | 4 | A `*_path` / `*_url` call resolved against the helper table. Includes the HTTP method, generated path, and Rails action name. |
| `plugin.actionpack.unknown-helper` | error | 4 | The `*_path` / `*_url` name is not in the helper table. Includes a `DidYouMean::SpellChecker` suggestion drawn from the table. |
| `plugin.actionpack.wrong-helper-arity` | error | 4 | The call's positional-argument count doesn't match the helper's recorded arity. |
| `plugin.actionpack.filter-call` | info | 2 | A filter-DSL reference (`before_action :name`, `skip_around_action`, etc.) resolves to a defined method on the controller or its immediate parent. |
| `plugin.actionpack.unknown-filter-method` | error | 2 | A filter-DSL reference names a method not defined on the controller (or its immediate parent). Includes a `DidYouMean::SpellChecker` suggestion drawn from the controller's effective method set. |
| `plugin.actionpack.render-target` | info | 3 | An explicit `render :symbol` / `render "string"` / `render partial:` call resolved to a view template under `view_search_paths`. |
| `plugin.actionpack.missing-template` | error | 3 | An explicit `render` call's resolved view path doesn't exist as `.html.erb` or `.text.erb` under any configured `view_search_paths`. |

## Configuration

```yaml
plugins:
  - rigor-rails-routes              # producer: must be loaded
  - rigor-actionpack                # consumer
    config:
      controller_search_paths:      # default; optional
        - app/controllers
```

The `manifest(consumes: [...])` declaration tells the loader
that `rigor-actionpack` reads `:helper_table` from the
`rails-routes` plugin, so the ADR-9 topological sort guarantees
`rigor-rails-routes` runs `prepare(services)` first regardless
of `Configuration#plugins` order. The dependency is declared
`optional: true`, so a project that lists `rigor-actionpack`
without `rigor-rails-routes` still loads — Phase 4 silently
degrades to a no-op rather than emitting a load error.

## Cross-plugin API contract

The plugin reads exactly one fact per run:

```ruby
helper_table = services.fact_store.read(
  plugin_id: "rails-routes",
  name: :helper_table
)
```

The value is the Hash form `RailsRoutes::HelperTable#to_h`
returns: `{ "users_path" => { name:, arity:, path:,
http_method:, action: }, ... }`. Phase 4 doesn't subscribe to
the carrier classes themselves so it doesn't need the
`rigor-rails-routes` gem at runtime; it only needs the
publication contract.

## Limitations

- **Implicit-self only.** Explicit-receiver
  `*_path` / `*_url` calls are passed through.
- **Path filter, not class filter.** Files under
  `controller_search_paths` are checked regardless of class
  hierarchy. A non-controller file accidentally placed under
  `app/controllers/` (rare) would trigger checks. Phase 1's
  strong-parameters work needs the proper controller-class
  detection and lives there; Phase 4 keeps the cheap path
  filter.
- **Helper-table source.** Only what `rigor-rails-routes`
  publishes today is recognised. Custom inflections, scope
  blocks, mountable engines, and the `_path` / `_url` forms
  generated by `rigor-rails-routes`'s deferred slices need
  the upstream plugin to widen first; Phase 4 picks them up
  for free as the table grows.

## Demo

```sh
cd examples/rigor-actionpack/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib:$PWD/../../rigor-rails-routes/lib" \
  bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

The demo ships:

- `config/routes.rb` — the routes file `rigor-rails-routes`
  parses on load.
- `app/controllers/users_controller.rb` — clean usage; emits
  five `helper-call` info traces, no errors.
- `app/controllers/errors_controller.rb` — triggers the three
  error paths (`unknown-helper` with did-you-mean,
  `wrong-helper-arity` for arity 1 called with 0 args,
  `wrong-helper-arity` for arity 2 called with 1 arg).

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(consumes: [...])` | declares the cross-plugin dependency on `rails-routes#:helper_table` |
| `services.fact_store.read(...)` | consumes the upstream helper table |
| `Plugin::Base#diagnostics_for_file` | per-file emission hook |
| `Rigor::Analysis::Diagnostic` | builds the four diagnostic shapes |
| `DidYouMean::SpellChecker` | suggester for `unknown-helper` |
