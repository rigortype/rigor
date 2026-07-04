# rigor-hanami

Tier 3 of Rigor's ecosystem plugin family. Enforces the
**Hanami::Action protocol** — every class under `app/actions/` must
define `#handle(request, response)` — and provides
`Hanami::Action::Request` / `Hanami::Action::Response` type information
into action bodies via the
[ADR-28 path-scoped method-protocol contract](../../docs/adr/28-path-scoped-protocol-contracts.md)
extension point. No `hanami` runtime dependency (it ships RBS stubs).

> **Using this plugin?** The user guide — what it checks, the
> diagnostic catalogue, configuration, and limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-hanami.md](../../docs/manual/plugins/rigor-hanami.md).
> This README covers the plugin's internals.

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
`Inference::MethodParameterBinder` encounters a `#handle` definition
inside a file matching the glob, it substitutes
`Hanami::Action::Request` for the first parameter and
`Hanami::Action::Response` for the second, instead of the usual
`Dynamic[Top]` fallback — so type errors inside action bodies are
caught precisely as core `call.undefined-method` diagnostics.

**Check half (plugin-side):** the plugin's `node_rule(Prism::ClassNode)`
rule confirms each class in a matching file defines `#handle` with exactly
two parameters, emitting `missing-handle-method` / `handle-arity-mismatch`.

The `action_path` config key is folded into the contract set at `init`
(via `with_path_glob`) and surfaced through the `#protocol_contracts`
override, so an override reaches both the provide and check halves
(ADR-28 WD5).

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... protocol_contracts:)` (ADR-28) | The load-bearing surface — declares the `#handle` parameter-type contract scoped to `app/actions/**/*.rb`. |
| `manifest(... config_schema:)` | The `action_path` glob override (static fallback to the manifest glob in `init`). |
| `manifest(... signature_paths: ["sig"])` (ADR-25) | Loads the bundled `sig/hanami_action.rbs` stubs for Request / Response / Params. |
| `#protocol_contracts` override | Folds the per-project `action_path` into the contract set so the override reaches the engine's provide tier. |
| `node_rule(Prism::ClassNode)` | The ADR-28 check half — delegates to `ActionChecker#check_class`. |

## RBS stubs

`sig/hanami_action.rbs` covers the documented `Hanami::Action::Request`
/ `Response` / `Params` surface, self-contained (no `Rack::Request` /
`Rack::Response` inheritance), so the plugin works whether or not Rack
RBS is present in the analysed project.

## License

MPL-2.0, matching the parent Rigor project.
