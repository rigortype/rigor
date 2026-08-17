# rigor-actionpack

The first **Tier 2** plugin in Rigor's Rails ecosystem family
and the first concrete consumer of the [ADR-9 cross-plugin
API](../../docs/adr/9-cross-plugin-api.md). Across four phases it
validates controller-side Action Pack code — route-helper calls,
filter chains, render targets, and strong-parameter keys — by
reading facts that [`rigor-rails-routes`](../rigor-rails-routes/)
(`:helper_table`) and [`rigor-activerecord`](../rigor-activerecord/)
(`:model_index`) publish.

> **Using this plugin?** The user guide — what each phase checks,
> the diagnostic catalogue, configuration, and limitations — lives
> in the manual at
> [docs/manual/plugins/rigor-actionpack.md](../../docs/manual/plugins/rigor-actionpack.md).
> This README covers the plugin's internals and the cross-plugin
> contract it exercises.

## The four phases (all landed)

| Phase | Surface | Diagnostic family |
| --- | --- | --- |
| 1 | Strong parameters → AR column validation | `plugin.actionpack.permit-*` |
| 2 | Filter chains (`before_action :name`) | `plugin.actionpack.*-filter-method` |
| 3 | Render targets (`render :show`) | `plugin.actionpack.render-target` / `missing-template` |
| 4 | Route-helper consumption (`redirect_to user_path(@user)`) | `plugin.actionpack.*-helper*` |

All four compose additively under the same plugin id. Filter and
render resolution follows Rails' constant-resolution semantics
(nested-module controllers qualify to `Admin::WidgetsController` →
`admin/widgets/…`; gem-shipped parents are silenced).

## Cross-plugin API contract

The plugin reads two optional facts per run:

```ruby
helper_table = services.fact_store.read(plugin_id: "rails-routes", name: :helper_table)
model_index  = services.fact_store.read(plugin_id: "activerecord", name: :model_index)
```

`manifest(consumes: [...])` declares both with `optional: true`, so
the ADR-9 topological sort runs the producers' `prepare(services)`
first when present, and a project that omits a producer still loads
(the dependent phase degrades to a no-op). The plugin subscribes to
the published Hash shapes, not the producer's carrier classes, so
it needs only the publication contract — not the upstream gems at
runtime.

## Demo

```sh
cd plugins/rigor-actionpack/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib:$PWD/../../rigor-rails-routes/lib" \
  bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

The demo ships a `config/routes.rb` (parsed by `rigor-rails-routes`
on load), a clean controller (five `helper-call` info traces), and
an errors controller exercising the `unknown-helper` /
`wrong-helper-arity` paths.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(consumes: [...])` | declares the cross-plugin dependencies on `rails-routes#:helper_table` + `activerecord#:model_index` |
| `services.fact_store.read(...)` | consumes the upstream facts |
| `node_rule` + `NodeContext` (ADR-37) | per-call checks run over the engine-owned walk; the enclosing controller is read from the node's lexical ancestors (the nested-module qualification render/filter resolution needs) |
| `Plugin::Inflector` (ADR-39) | model / table name resolution via the real `ActiveSupport::Inflector` |
| `Plugin::Base.suggest` | did-you-mean suggestions for the `unknown-*` diagnostics |

## Effects ([ADR-103](../../docs/adr/103-effect-labels.md) WD10 / WD14)

Inert unless the project has an `effects:` block.

| Call | Labels |
| --- | --- |
| `redirect_to`, `redirect_back`, `head`, `send_data` | `mutate.self` + `rails.response.write` |
| `render`, `render_to_string`, `render_to_body` | the same, **plus a `template-not-analysed` taint** |
| `send_file` | the same, plus `io.fs.read` |
| `session[]=`, `session.delete`, `reset_session` | `mutate` + `rails.session.write` |
| `session[]` | `io` + `rails.session.read` |
| `cookies[]=` and the `signed` / `encrypted` / `permanent` jars | `mutate` + `rails.cookie.write` |
| `flash[]=`, `flash.now[]=`, `flash.alert=`, `flash.notice=` | `mutate` + `rails.flash.write` |

### `mutate.self`, not `io`

`render` and `redirect_to` do not write to a socket. They set the
response body and status on the controller instance; Rack writes it
later, outside any project method. So an envelope forbidding `io` in a
service object is not violated by a helper that calls
`render_to_string`, and that is the right answer.

### Why `render` keeps a taint

The template is not an effect unit yet
([ADR-103](../../docs/adr/103-effect-labels.md) WD11). What the
controller does is fully stated; what the view does is genuinely
unknown, and a summary that stopped at the `render` line and read
*exhaustive* would be the one misleading row in the whole Rails layer.
The taint is how it says so.

### `session[:user_id] = id`

That is `[]=` on the result of a receiver-less `session`, and nothing
types that result. The row matches the receiver **expression** as
written, scoped to classes whose project ancestry reaches
`ActionController::Base` — so a `session` method on an unrelated class
is not mistaken for this one.

### Entry-point preset

`rails-controllers` → `app/controllers/**/*.rb`.
