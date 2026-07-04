# rigor-web — example Rigor plugin

Reference example for the **ADR-28 path-scoped method-protocol
contract** extension point. Where the earlier examples react to
*call sites* (`rigor-routes`, `rigor-pattern`) or *literals*
(`rigor-lisp-eval`), `rigor-web` reacts to a *directory
convention*: it enforces a behavioural protocol on every class
defined under a path glob, with no opt-in on the class itself.

## The framework being checked: RigWeb

`demo/lib/rig_web.rb` is a deliberately tiny routing layer:

```ruby
router = RigWeb.new
router.get("/", [HomeController, :get])
router.get("/hello", [HelloController, :get])

response = router.routes(request)
```

RigWeb asks nothing structural of a controller — no base class,
no `include`. The only requirement is behavioural:

> a controller action takes a `Rack::Request` and returns a
> `Rack::Response`.

That requirement is a convention. Nothing in the controller
*source* records it, so nothing checks it. `rigor-web` closes
that gap.

## The contract

The plugin declares one `Rigor::Plugin::ProtocolContract` on its
manifest:

```ruby
Rigor::Plugin::ProtocolContract.new(
  path_glob: "lib/controller/**/*.rb",
  method_name: :get,
  param_types: [{ index: 0, type_name: "Rack::Request" }],
  return_type_name: "Rack::Response"
)
```

Read it as: *every class defined in a file matching
`lib/controller/**/*.rb` must define `#get`; its first parameter
is a `Rack::Request`; its body must return a `Rack::Response`.*

## provide-and-check

The contract drives two distinct behaviours:

- **provide** (engine-side) — when the inference engine binds the
  parameter list of a matching `#get`,
  `Inference::MethodParameterBinder` substitutes `Rack::Request`
  for the usual `Dynamic[Top]` fallback. The controller body is
  then analysed *as if* the parameter were a real request, so a
  typo like `request.path_inf0` surfaces as an ordinary core
  `call.undefined-method` diagnostic — `rigor-web` never has to
  check for that itself.
- **check** (plugin-side) — the plugin's `node_rule(Prism::ClassNode)`
  rule confirms each controller class defines `#get` and that its
  inferred return type conforms to `Rack::Response`.

## What the plugin recognises

```text
lib/controller/home_controller.rb   — clean
lib/controller/hello_controller.rb  — clean
```

A controller that violates the protocol:

```ruby
# lib/controller/broken_controller.rb
class BrokenController
  # returns a String, not a Rack::Response
  def get(request)
    "plain text body"
  end
end
```

```text
broken_controller.rb:3:7: error: `get` must return a Rack::Response —
  inferred String("plain text body") [plugin.web.protocol-return-mismatch]
```

A controller that omits `#get` entirely:

```text
silent_controller.rb:2:7: error: `SilentController` must define instance
  method `get` — required of every class under `lib/controller/**/*.rb`
  [plugin.web.missing-protocol-method]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| controller class defines no `#get` | `:error` | `missing-protocol-method` |
| `#get`'s inferred return type is not a `Rack::Response` | `:error` | `protocol-return-mismatch` |

A `#get` whose return type the engine cannot pin down
(`Dynamic[Top]`) stays silent — the plugin defers to runtime
rather than frighten code that may well be correct.

## Configuration

The convention path is overridable per project:

```yaml
plugins:
  - gem: rigor-web
    config:
      controller_path: "app/controllers/**/*.rb"
```

## RBS for Rack

The contract names `Rack::Request` / `Rack::Response`. The plugin
ships a minimal RBS for that slice of Rack under `sig/` and
declares `signature_paths: ["sig"]` on its manifest (ADR-25), so
the analysed project resolves the type names without depending on
the rack gem.

## Layout

```
rigor-web/
├── README.md
├── rigor-web.gemspec
├── sig/
│   └── rack.rbs                    ← minimal Rack::Request / Rack::Response RBS
├── lib/
│   ├── rigor-web.rb
│   └── rigor/plugin/
│       ├── web.rb                  ← manifest, contract, config override, hook
│       └── web/
│           └── protocol_checker.rb ← the check half: presence + return-type
└── demo/
    ├── .rigor.dist.yml             ← `paths:` lists lib/
    └── lib/
        ├── rig_web.rb              ← the RigWeb framework
        ├── app.rb                  ← route wiring
        └── controller/
            ├── home_controller.rb  ← protocol-conforming
            └── hello_controller.rb ← protocol-conforming
```

## Running the demo

```sh
cd demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo controllers all conform, so the run is clean. Add a
controller under `demo/lib/controller/` that omits `#get` or
returns the wrong type to see the diagnostics above.
