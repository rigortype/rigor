# rigor-sinatra

Recognises Sinatra's class-level route DSL (`get` / `post` / `put`
/ `delete` / `head` / `options` / `patch` / `link` / `unlink`) on
`Sinatra::Base` subclasses and narrows the route block's `self` so
its bare helpers — `params`, `redirect`, `halt`, `session`,
`headers`, `content_type`, `erb`, `status`, `body`, … — resolve
through `Sinatra::Base`'s RBS instead of going unresolved.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-sinatra
```

## What it does

```ruby
class MyApp < Sinatra::Base
  get "/users/:id" do
    halt 404 unless params["id"]
    redirect "/users/#{params['id']}/profile"
  end
end
```

Inside the route block, `self` is narrowed to `MyApp` (which
inherits from `Sinatra::Base`), so `params` / `redirect` / `halt`
resolve through the normal RBS chain. Without the plugin the block
body is typed as `Singleton[MyApp]` and that per-block resolution is
lost.

Sinatra's own RBS needs to be available for the helpers to resolve
— through Rigor's Bundler-awareness, a vendored sig, or (in the
demo) a local stub.

## No diagnostics, no config

The plugin only recognises the route shape and narrows `self`; it
emits no diagnostics and has no config keys (the verb match table
is fixed in the manifest).

## Limitations

- **No routing diagnostics** — path-pattern uniqueness, conflict
  detection, and named-route reverse lookup are out of scope.
- **`helpers do … end`** blocks (injecting instance methods) are
  not handled (that's Tier B / C work, not this Tier A shape).
- **`configure` / `set` settings DSL** is not handled.
- **Classic-style top-level routes** — a bare `get '/x' do … end`
  with no enclosing `class < Sinatra::Base` — are deferred; the
  recognition needs the receiver's class visible at the call site.

## Plugin internals

The declarative `BlockAsMethod` manifest and the macro-substrate
`self`-narrowing it rides on are documented in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-sinatra/README.md). To
write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
