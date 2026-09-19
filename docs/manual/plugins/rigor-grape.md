# rigor-grape

Types the [Grape](https://github.com/ruby-grape/grape)
endpoint-declaration DSL so calls inside `class API < Grape::API`
bodies — and inside `Grape::Entity` subclasses from
[grape-entity](https://github.com/ruby-grape/grape-entity) — resolve to
real carriers instead of `Dynamic[top]`. It reads source only, with no
`grape` runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:` (or let
bundler auto-detection pick it up when `grape` or `grape-entity` is in
`Gemfile.lock`):

```yaml
plugins:
  - rigor-grape
```

## What it types

```ruby
class ThingsAPI < Grape::API
  version "v1", using: :path
  format :json

  desc "List things"                       # Object?
  route_setting :swagger, tags: %w[things] # Object?

  params do                                # → Grape::Validations::ParamsScope
    requires :id, type: Integer            # Object?
    optional :q, type: String              # Object?
    requires :filter, type: Hash do        # nested scope re-enters ParamsScope
      requires :state, type: String
    end
    mutually_exclusive :q, :filter
  end

  namespace :things do                     # self: the API::Instance class object
    get "/:id" do                          # self: Grape::Endpoint
      params                               # Hash[untyped, untyped]
      error!("nope", 404)                  # bot
      present Thing.first, with: Entities::Thing
    end
  end
end

class Entities::Thing < Grape::Entity
  expose :id                               # Array[untyped]
  expose :name do                          # `self` stays the class object
    expose :first
  end
  format_with(:iso) { |d| d.to_s }         # Object
end
```

Recognised surfaces:

- **Class-body declarations** on `Grape::API` subclasses (including
  through intermediate source base classes): `params`, `namespace` /
  `group` / `resource` / `resources` / `segment` / `route_param` /
  `version` / `given` / `mounted`, `get`/`put`/`post`/`delete`/`head`/
  `patch`/`options`/`route`, `desc`, `route_setting`, `helpers`, `use`,
  `mount`, `rescue_from`, the format/error-format setters, callbacks
  (`before`/`after`/`before_validation`/`after_validation`), `prefix`,
  `scope`, `contract`, and friends.
- **`params` block bodies** bind `self` to
  `Grape::Validations::ParamsScope`, so `requires`, `optional`, `given`,
  `with`, `use`, and the grouping macros (`mutually_exclusive`,
  `exactly_one_of`, `at_least_one_of`, `all_or_none_of`) resolve —
  including nested `requires :x, type: Hash do ... end` bodies.
- **Namespace-family bodies** (`namespace`, `route_param`, `version`,
  `given`, `mounted`) bind `self` to the `Grape::API::Instance` class
  object, matching Grape's `instance_eval`-on-class semantics, so nested
  declarations resolve the same surface.
- **Verb bodies** bind `self` to `Grape::Endpoint`, so `params`,
  `headers`, `cookies`, `env`, `declared`, `present`, `error!`,
  `status`, `redirect`, `body`, `content_type`, `route`,
  `route_setting`, `stream`, `sendfile`, `error_response` resolve.
- **`Grape::Entity` class bodies**: `expose`, `unexpose`,
  `with_options`, `documentation`, `format_with`, `root`,
  `root_element`, `represent`, `present_collection`, `root_exposures`.
  Nested `expose` bodies keep `self` on the class object, so they
  resolve the same way.

## Deferred

- `helpers do ... end` bodies (an anonymous module is `self` —
  unnameable).
- `desc ... do ... end` documentation blocks (`DescContainer` DSL).
- Named `params :name` scopes inside `helpers` and `contract` schema
  blocks.
- Value-level typing: `present`/`declared` results against the declared
  entity or params, entity `represent` result typing.
- `Grape::Middleware` and custom-middleware DSL.

Calls on classes outside `Grape::API` / `Grape::Entity` ancestry keep
the `Dynamic` fallback, and DSL names the bundled signature does not
declare stay opaque rather than diagnosed — the declared classes are
registered as open receivers because Grape's runtime surface is
generated (`override_all_methods!`) and user base classes extend it.
