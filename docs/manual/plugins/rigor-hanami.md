# rigor-hanami

Enforces the **Hanami::Action protocol** for Hanami 3.x apps: every
class under `app/actions/**/*.rb` must define `#handle(request,
response)`, and inside those bodies Rigor types the two parameters as
`Hanami::Action::Request` / `Hanami::Action::Response` so misuse is
caught precisely. It is the reference production consumer of the
[ADR-28](https://github.com/rigortype/rigor/blob/master/docs/adr/28-path-scoped-protocol-contracts.md) path-scoped
method-protocol contract — Rigor *provides* the parameter types and the
plugin *checks* the method shape. It reads source only, with no
`hanami` runtime dependency (it ships RBS stubs for the Request /
Response / Params surface).

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-hanami
```

## What it checks

```ruby
# app/actions/books/index.rb
module Bookshelf
  module Actions
    module Books
      class Index < Bookshelf::Action
        def handle(request, response)
          response.status = 200                 # response: Hanami::Action::Response
          response.body = request.params[:q]    # request: Hanami::Action::Request
          request.no_such_method                # error: call.undefined-method
        end
      end
    end
  end
end
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.hanami.missing-handle-method` | error | a class in a matching file defines no `#handle` |
| `plugin.hanami.handle-arity-mismatch` | error | `#handle` is defined with a parameter count other than 2 |

Inside a conforming `#handle`, misuse of `request` / `response`
surfaces as the engine's own `call.undefined-method` — the same as if
the types had been declared in RBS. Return-type conformance is *not*
checked: `#handle` is void by contract (the response is mutated
in-place), so checking the return value would generate false positives
on every conditional branch. Parameter names are arbitrary (positions,
not names, are bound); only directly-defined `#handle` is checked, not
an inherited one.

## Configuration

```yaml
plugins:
  - gem: rigor-hanami
    config:
      action_path: "app/actions/**/*.rb"   # default
```

Override `action_path` for a custom slice layout, e.g.
`"slices/main/actions/**/*.rb"`. The override retargets both the
parameter-type provision and the `#handle` check.

## Limitations

- **Exact arity.** `#handle` must take exactly two parameters; optional
  or keyword-only forms are flagged as `handle-arity-mismatch`.
- **Direct definition only.** A `#handle` inherited from a base class
  (rather than defined on the class itself) is not detected.
- **Stubbed surface.** The bundled RBS covers the documented Request /
  Response / Params methods; calls outside that surface resolve against
  the stubs, not a live Hanami install.

## Plugin internals

The `ProtocolContract` declaration, the action checker, the RBS stubs,
and the ADR-28 provide-and-check split are in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-hanami/README.md). To write a
plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
