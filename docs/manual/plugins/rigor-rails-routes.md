# rigor-rails-routes

Statically interprets `config/routes.rb` with Prism (no Rails
runtime dependency), builds the route-helper table Rails would
generate, and validates every `*_path` / `*_url` call site against
it: an unknown helper is flagged (with a did-you-mean suggestion),
as is a wrong argument count. Model↔route inflection uses the real
`ActiveSupport::Inflector`, so irregular names resolve the way Rails
resolves them.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-rails-routes
```

## What it checks

Given a `config/routes.rb`, the plugin recognises every helper
Rails would generate and flags typos / arity mismatches at the call
site:

```text
file:line:col: info:  `users_path` → GET /users
file:line:col: info:  `admin_widgets_path` → GET /admin/widgets

file:line:col: error: no route helper `widgts_path` (did you mean `users_path`?)
file:line:col: error: `user_path` expects 1 argument(s), got 3
```

Both `_path` and `_url` forms are recognised.

### Recognised routing DSL

The parser covers the routing DSL real apps use (expanded across
the v0.1.11 / v0.1.12 OSS surveys against Mastodon / Redmine /
GitLab FOSS):

- `Rails.application.routes.draw do … end`, plus `draw :name` /
  `draw_all :name` partial route files.
- `resources` / `resource` (with `only:` / `except:`), nested
  resources, and `member do … end` / `collection do … end`.
- `namespace :admin do … end` and `scope` — both the positional
  form and keyword `scope(path:, as:, module:)`, with the `as:`
  prefix and dynamic path segments counted into helper arity.
- `root`, and explicit `get`/`post`/`patch`/`put`/`delete`
  routes (named via `as:`, including anonymous static routes).
- `devise_for`, `mount`, `use_doorkeeper`, `with_options`,
  `direct`, and `concern :name do … end` (definition recorded;
  the body is skipped to avoid wrong-arity false positives).

## Configuration

```yaml
plugins:
  - gem: rigor-rails-routes
    config:
      routes_file: "config/routes.rb"   # default
      helper_paths: ["app"]             # default; dirs scanned for
                                        # project-defined *_path / *_url methods
      grape_api_paths: ["lib/api", "app/api"]
                                        # default; dirs scanned for Grape API classes
```

`helper_paths` lets the plugin also register URL builders you
define yourself (e.g. a private `def callback_url` under
`app/controllers` or `app/lib`), so calls to them are not flagged
as unknown helpers.

`grape_api_paths` is where the plugin looks for Grape API classes.
If you mount one, the `grape-path-helpers` gem generates helpers
named after each route's path (`api_v4_groups_badges_path`) from
grape's *runtime* route table, which no static parser can
enumerate. The plugin reads your API's `prefix` and `version`
declarations instead and treats the namespace they open as
unknowable-but-valid, so those calls are never flagged. The `_url`
form still is: `grape-path-helpers` defines only `_path` helpers.

## What it provides

The parsed helper table is published as the `:helper_table`
cross-plugin fact (ADR-9), which `rigor-actionpack` consumes to
validate helper calls inside controllers.

### Controller roots for `rigor unused`

The same parse also yields the **controller classes** your routes
dispatch to, published as the `:reachability_roots` fact that
[`rigor unused`](../02-cli-reference.md#rigor-unused) seeds its
reachability report with.

This matters because Rails reaches a controller by *name* at request
time. Nothing in your code references `Admin::UsersController`, so
without route knowledge every controller in the app reads as
unreferenced — on Mastodon that was 233 spurious candidates.

Controller names are composed the way Rails composes them:
`resources :users` inside `namespace :admin` is
`Admin::UsersController`; a singular `resource :profile` is served by
the plural `ProfilesController`; `scope module:` and a `module:`
option on a resource extend the namespace; `to: "posts#index"`,
`controller:`, and the hashrocket `get "help" => "help#show"` form
are all read. Acronyms declared in
`config/initializers/inflections.rb` are applied, so
`scope module: :activitypub` resolves to `ActivityPub::…`.

Two properties follow from parsing rather than booting, and are the
reason to prefer this over reading a running app's route table:

- **No Rails runtime is loaded.**
- **A route under a conditional is still a root.**
  `get "/beta", to: "beta#index" if ENV["ENABLE_BETA"]` does not
  appear in a booted app's route table unless the condition happened
  to hold; both branches are visible to a static read.

**Not covered as roots** (deliberately, rather than half-covered):
controllers remapped by `devise_for … controllers:`, by
`use_doorkeeper … controllers:`, or served through a mounted Grape
API. Those mappings name controllers the plugin does not resolve, so
they may appear as `rigor unused` candidates even though they are
routed. Helper-name recognition for all three is unaffected.

## Limitations

- **Statically unfoldable route definitions.** Helpers produced by
  metaprogramming the parser can't unfold (routes built in a loop
  over runtime data, helpers injected by an engine the parser
  doesn't model) may not register, which can surface a false
  `unknown-helper`. Record those in a baseline, or
  `# rigor:disable` the line.
- **Project-custom inflections** declared in
  `config/initializers/inflections.rb` are not yet fully ingested
  (ADR-39 slice 3); the standard ActiveSupport inflections are
  covered, and `inflect.acronym` declarations are read for
  controller-class composition only.

## Plugin internals

The Prism routes-parser, the cached `:helper_table` producer, the
demo, and the contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-rails-routes/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
