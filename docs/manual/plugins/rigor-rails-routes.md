# rigor-rails-routes

Statically interprets `config/routes.rb` with Prism — no Rails
runtime dependency — builds the route-helper table Rails would
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
```

`helper_paths` lets the plugin also register URL builders you
define yourself (e.g. a private `def callback_url` under
`app/controllers` or `app/lib`), so calls to them are not flagged
as unknown helpers.

## What it provides

The parsed helper table is published as the `:helper_table`
cross-plugin fact (ADR-9), which `rigor-actionpack` consumes to
validate helper calls inside controllers.

## Limitations

- **Statically unfoldable route definitions.** Helpers produced by
  metaprogramming the parser can't unfold (routes built in a loop
  over runtime data, helpers injected by an engine the parser
  doesn't model) may not register, which can surface a false
  `unknown-helper`. Record those in a baseline, or
  `# rigor:disable` the line.
- **Project-custom inflections** declared in
  `config/initializers/inflections.rb` are not yet ingested
  (ADR-39 slice 3); the standard ActiveSupport inflections are
  covered.

## Plugin internals

The Prism routes-parser, the cached `:helper_table` producer, the
demo, and the contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-rails-routes/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
