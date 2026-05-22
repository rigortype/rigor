# rigor-hanami

Tier 3 of Rigor's ecosystem plugin family. Enforces the
**Hanami::Action protocol** — every class under `app/actions/`
must define `#handle(request, response)` — and provides
`Hanami::Action::Request` / `Hanami::Action::Response` type
information into action bodies via the
[ADR-28 path-scoped method-protocol contract](../../docs/adr/28-path-scoped-protocol-contracts.md)
extension point. No `hanami` runtime dependency.

## What it checks

Given an action class:

```ruby
# app/actions/books/index.rb
module Bookshelf
  module Actions
    module Books
      class Index < Bookshelf::Action
        def handle(request, response)
          response.status = 200
          response.body = "ok"
        end
      end
    end
  end
end
```

The plugin validates:

1. **Method presence** — every class under `app/actions/**/*.rb`
   must define `#handle`. Missing definitions emit
   `missing-handle-method`.

2. **Parameter type provision** — inside the `#handle` body,
   `request` is typed `Hanami::Action::Request` and `response`
   is typed `Hanami::Action::Response`. Misuse (e.g.
   `request.no_such_method`) surfaces as a standard engine
   `call.undefined-method` diagnostic — the same as if the
   types had been declared explicitly in RBS.

Return-type conformance is **not** checked — `#handle` is void
by contract (the response is mutated in-place), so checking the
return value would generate false positives on every conditional
branch.

## Diagnostics

| Event | Severity | Rule |
| --- | --- | --- |
| action class defines no `#handle` | `:error` | `missing-handle-method` |
| `request` / `response` misuse in body | core engine diagnostic | (e.g. `call.undefined-method`) |

## Configuration

```yaml
plugins:
  - gem: rigor-hanami
    config:
      action_path: "app/actions/**/*.rb"   # default; optional
```

Override `action_path` if your project places actions elsewhere
(e.g. a custom slice layout):

```yaml
plugins:
  - gem: rigor-hanami
    config:
      action_path: "slices/main/actions/**/*.rb"
```

## How it works (ADR-28 provide-and-check)

The plugin declares one `ProtocolContract` on its manifest:

```ruby
ProtocolContract.new(
  path_glob: "app/actions/**/*.rb",
  method_name: :handle,
  param_types: [
    { index: 0, type_name: "Hanami::Action::Request" },
    { index: 1, type_name: "Hanami::Action::Response" }
  ]
  # return_type_name: nil — void; skip return-type check
)
```

**Provide half (engine-side):** when Rigor's
`Inference::MethodParameterBinder` encounters a `#handle`
definition inside a file matching `app/actions/**/*.rb`, it
substitutes `Hanami::Action::Request` for the first parameter
and `Hanami::Action::Response` for the second, instead of the
usual `Dynamic[Top]` fallback. This means type errors inside
action bodies are caught precisely.

**Check half (plugin-side):** this plugin's
`#diagnostics_for_file` hook confirms that `#handle` is defined.
