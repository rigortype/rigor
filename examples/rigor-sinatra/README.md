# rigor-sinatra — example Rigor plugin

ADR-16 **Tier A** worked target: recognises Sinatra's class-level
route DSL (`get`, `post`, `put`, `delete`, `head`, `options`,
`patch`, `link`, `unlink`) and narrows the block body's `self` so
its bare identifiers (`params`, `redirect`, `halt`, `session`,
`headers`, `content_type`, `body`, `status`, `erb`, …) resolve
through `Sinatra::Base`'s RBS via rigor's normal inference path.

This plugin is the **first worked consumer of the macro expansion
substrate** (ADR-16 slice 1c). Its body is purely declarative —
the entire manifest is a `Plugin::Macro::BlockAsMethod` entry:

```ruby
class Sinatra < Rigor::Plugin::Base
  manifest(
    id: "sinatra",
    version: "0.1.0",
    block_as_methods: [
      Rigor::Plugin::Macro::BlockAsMethod.new(
        receiver_constraint: "Sinatra::Base",
        verbs: %i[get post put delete head options patch link unlink]
      )
    ]
  )
end
```

No `diagnostics_for_file`, no AST walker, no plugin-side state.
The substrate handles the recognition and the `self_type`
narrowing; the plugin only declares **which DSL call shapes to
treat as block-as-method**.

## What the plugin does

For source like

```ruby
class MyApp < Sinatra::Base
  get "/users/:id" do
    halt 404 unless params["id"]
    redirect "/users/#{params['id']}/profile"
  end
end
```

the substrate hooks into `Rigor::Inference::ExpressionTyper`'s
block-entry path. When it sees `<X>.get(path) do ... end` and `<X>`
is or inherits from `Sinatra::Base`, the block's `Scope#self_type`
is narrowed to `Nominal[MyApp]` for the duration of body typing.
Inside the block, `params` / `redirect` / `halt` resolve through
the normal RBS chain because `self : Nominal[MyApp]` and `MyApp <
Sinatra::Base`.

## Floor / ceiling per ADR-16 WD13

The v0.1.x deliverable is the **floor**: the substrate-affected
block body parses cleanly and its identifiers resolve. The plugin
ships nothing beyond the declarative manifest — no method-body
analysis, no per-verb parameter typing, no routing diagnostics.
Those are roadmap (ceiling) targets and are out of scope for slice
1c.

## What the plugin does NOT do (yet)

- **Routing diagnostics.** Path-pattern uniqueness, conflict
  detection, named-route reverse lookup, route-table publication
  via ADR-9's cross-plugin fact-store — none of these are in slice
  1c's scope.
- **Custom helpers.** `helpers do ... end` blocks that inject
  module methods into the app's instance namespace are Tier C /
  Tier B work, not Tier A.
- **Configure / settings.** `configure do ... end` and `set
  :session_secret, "..."` are settings DSL, not route DSL —
  handled by separate substrate entries when demand surfaces.
- **Classic-style top-level routes.** A bare `get '/path' do ...
  end` at the top of a script (no enclosing `class < Sinatra::Base`)
  is Sinatra's classic-mode pattern. Tier A as currently wired
  requires the receiver's class to be visible at the call site;
  the classic style is deferred until demand justifies the extra
  match shape.

## Configuration

```yaml
plugins:
  - rigor-sinatra
```

No plugin-specific config keys. The match table is fixed at the
manifest level — the nine Sinatra HTTP verb methods, against any
class inheriting from `Sinatra::Base`.

## Running the demo

The demo provides a minimal `Sinatra::Base` RBS stub locally
(`demo/sig/sinatra.rbs`). A real project depending on `sinatra`
would consume the upstream gem's own RBS through rigor's
Bundler-awareness path or a vendored sig under
`data/vendored_gem_sigs/`.

```sh
cd demo
cp .rigor.dist.yml .rigor.yml
RUBYLIB=$PWD/../lib bundle exec rigor check
```

Rigor reports `No diagnostics` — the floor commitment. Each call
inside the `get` / `post` / `delete` blocks resolves through
Sinatra::Base's RBS; if you remove the plugin from `.rigor.yml`
the block bodies fall back to `Singleton[MyApp]` typing and the
analyzer loses the per-block resolution path.

## Related

- ADR-16 (`docs/adr/16-macro-expansion.md`) — the substrate
  contract.
- `Rigor::Plugin::Macro::BlockAsMethod`
  (`lib/rigor/plugin/macro/block_as_method.rb`) — the value class
  the manifest entries instantiate.
- `Rigor::Inference::MacroBlockSelfType`
  (`lib/rigor/inference/macro_block_self_type.rb`) — the engine
  hook the substrate ships in slice 1b.
