# rigor-rspec-rails

Rigor plugin that validates [rspec-rails](https://github.com/rspec/rspec-rails)
**behavioral** matchers whose arguments are statically checkable.
Sibling to `rigor-rspec` and `rigor-minitest`, but a different shape:
instead of narrowing a local's static type, it emits domain-specific
diagnostics on matcher argument typos / out-of-range values.

> **Using this plugin?** The user guide — the recognised matcher, the
> diagnostic catalogue, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-rspec-rails.md](../../docs/manual/plugins/rigor-rspec-rails.md).
> This README covers the plugin's internals.

## Why this is a separate plugin from rigor-rspec

`rigor-rspec` handles the **type-narrowing** matchers — `be_a` /
`be_kind_of` / `be_nil` / `eq(literal)` — that refine a local's static
type so downstream calls in the same `it` body resolve at the narrowed
type.

`rigor-rspec-rails` handles the **behavioral** matchers — ones that
assert runtime state (HTTP status, rendered template, route shape)
without narrowing a type. The two plugins activate independently in
`.rigor.yml` and compose.

## The status-symbol authority (ADR-39)

The accepted HTTP status symbols come from the **real**
`Rack::Utils::SYMBOL_TO_STATUS_CODE` (the same authority
`have_http_status` resolves through), read at analysis time rather than
vendored — so a newly-added Rack status symbol is never mistaken for a
typo ([ADR-39](../../docs/adr/39-plugin-target-library-invocation.md):
depend on the target library's real facts, never an approximation).
When Rack cannot be loaded the plugin **declines** to flag any symbol
(reduced coverage, never a false `unknown-symbol`). Rails' eight
status-group aliases are a small, stable constant set kept in
`lib/rigor/plugin/rspec_rails/http_status_codes.rb`.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call validation of every `have_http_status(...)` over the engine-owned walk. |
| `Plugin::Base#diagnostic` (`location: node.message_loc`) | Points the diagnostic at the matcher name, not the receiver-spanning whole call. |
| Target-library invocation (ADR-39) | Lazy `require "rack/utils"` with a graceful no-flag fallback when Rack is absent. |
| `Plugin::Base.suggest` | Did-you-mean suggestion for the `unknown-symbol` diagnostic. |

## Why this plugin supplies no `rigor unused` roots

It was considered for the reachability report ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3) and **deliberately contributes nothing**, for the reason [`rigor-rspec`'s README](../rigor-rspec/README.md#why-this-plugin-supplies-no-rigor-unused-roots) sets out in full: a spec's constant reference is already recorded by the ordinary scan, and rooting it would strip the `:test` role that makes "reachable only from tests" a reportable answer (ADR-102 WD8).

## Deferred matchers (rspec-rails surface)

Queued for follow-up slices — each needs cross-plugin coordination or
overlaps with an existing rigor diagnostic:

- **`render_template(...)`** — overlaps `rigor-actionpack`'s
  render-target validation. A future slice would coordinate to avoid
  double-firing.
- **`route_to(...)` / `redirect_to(...)` / `be_routable`** — need the
  routes table from `rigor-rails-routes` (`:helper_table`, ADR-9).
- **`have_enqueued_job(JobClass)` / `have_enqueued_mail(MailerClass)`** —
  class-existence overlaps with the engine's `inference.unresolved-constant`.
- **`have_received(:method)`** — overlaps `call.undefined-method`.
- **`match_response_schema(...)`** (rswag / OpenAPI) — a separate plugin
  consuming the project's OpenAPI definitions.

## Layout

```text
plugins/rigor-rspec-rails/
├── README.md
├── lib/
│   ├── rigor-rspec-rails.rb
│   └── rigor/plugin/
│       ├── rspec_rails.rb                       ← Plugin::RspecRails class
│       └── rspec_rails/
│           ├── http_status_codes.rb             ← Rack lookup + Rails alias constant
│           └── have_http_status_analyzer.rb     ← recognizer + diagnostic builder
└── demo/
    ├── .rigor.yml
    └── spec/
        └── http_status_spec.rb                  ← every diagnostic + clean cases
```

## License

MPL-2.0, matching the parent Rigor project.
