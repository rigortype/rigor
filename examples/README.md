# Rigor plugin walkthroughs

Six **tutorial walkthroughs** that exercise the
[Rigor plugin contract](../docs/adr/2-extension-api.md) over
deliberately simplified, virtual use cases. Each walkthrough
spotlights a single architectural surface so plugin authors
can read the smallest possible code that demonstrates one
slice of the contract at a time.

This is **not** the inventory of plugins you would install in
production — those live under [`plugins/`](../plugins/) and
target real gems / frameworks (Rails, RSpec, dry-rb, Sorbet,
Devise, Sidekiq, etc.). See [`plugins/README.md`](../plugins/README.md)
for the production catalogue.

## When to read these

- You are **authoring** a Rigor plugin and want a small, focused
  reference for one specific contract surface.
- You are **learning** the plugin contract (manifest /
  diagnostic emission / cache producers / cross-plugin facts)
  and want a runnable, minimal example for each slice.
- You are **modifying** the plugin contract itself and want
  small fixtures that survive every contract change.

For "I want to analyse my Rails project" or "I want type
narrowing through my factory_bot calls," go to
[`plugins/`](../plugins/) instead.

## The six walkthroughs

| Walkthrough | Headline facet | LoC | I/O | Cache | Engine query |
| --- | --- | --- | --- | --- | --- |
| [`rigor-deprecations`](rigor-deprecations/) | **Config-driven rules** (smallest possible plugin) | ~80 | — | — | — |
| [`rigor-lisp-eval`](rigor-lisp-eval/) | **Literal AST typing** (interpret a Lisp expression) | ~200 | — | — | — |
| [`rigor-pattern`](rigor-pattern/) | **Engine collaboration** via `Scope#type_of` + literal-string carrier | ~180 | — | — | ✅ |
| [`rigor-units`](rigor-units/) | **Local-variable flow tracking** through arithmetic | ~280 | — | — | — |
| [`rigor-routes`](rigor-routes/) | **`IoBoundary` + cache producer** (slice 2 + slice 6) | ~250 | YAML | ✅ | — |
| [`rigor-web`](rigor-web/) | **Path-scoped protocol contract** (ADR-28 provide-and-check) | ~210 | — | — | ✅ |

The walkthroughs intentionally use virtual / fictional
domains — physical units of measure, a tiny Lisp evaluator,
a custom YAML route table — rather than real frameworks, so
the contract surface stays visible without library-specific
domain code crowding the read.

## Recommended reading order

| Your goal | Read in this order |
| --- | --- |
| **Author your first plugin (under 100 lines)** | `rigor-deprecations` |
| **Inspect a method call's literal arguments** | `rigor-lisp-eval` → `rigor-pattern` |
| **Track types through a series of statements** | `rigor-units` |
| **Read a project file under `TrustPolicy` + cache the parse** | `rigor-routes` |
| **Enforce a directory-scoped protocol on user classes** | `rigor-web` |
| **Internalise the architecture** | deprecations → lisp-eval → pattern → units → routes → web |

Then move to [`plugins/`](../plugins/) for the production
plugins layered on top of this contract.

## What each walkthrough exercises (architectural map)

| Surface | Where it lives | Walkthroughs that use it |
| --- | --- | --- |
| `Rigor::Plugin::Base.manifest(...)` | manifest declaration | all six |
| `config_schema` (`:string` / `:array` / `:hash`) | manifest body | deprecations / lisp-eval / pattern / web |
| `#init(services)` config plumbing | init hook | lisp-eval / pattern / routes / web |
| `#diagnostics_for_file(path:, scope:, root:)` | slice-5 emission hook | all six |
| `dynamic_return(receivers:, methods:) { \|call_node, scope\| }` | return-type contribution (successor to removed `flow_contribution_for`) | lisp-eval / pattern / units |
| `Plugin::IoBoundary#read_file` (slice 2) | sandboxed file reads | routes |
| `Plugin::TrustPolicy.allowed_read_roots` (slice 2) | declarative read-root policy | routes |
| `Plugin::Base.producer` DSL (slice 6) | cached producer declaration | routes |
| `Plugin::Base#cache_for` callable (slice 6) | cache round-trip wrapper | routes |
| `Scope#type_of(node)` | engine query for an inferred type | **pattern** / **web** |
| `Type::Combinator.literal_string_compatible?` | literal-string predicate | **pattern** |
| `Type::Constant#value` | exact-value extraction | **pattern** |
| Local-variable binding map across statements | pattern, not API | **units** |
| `protocol_contracts:` manifest field (ADR-28) | path-scoped protocol declaration | **web** |
| `signature_paths:` manifest field (ADR-25) | plugin-shipped RBS | **web** |

The production [`plugins/`](../plugins/) entries combine
these surfaces in larger, more realistic shapes — see
[`plugins/README.md`](../plugins/README.md) for the
architectural map at production scale (cross-plugin facts via
ADR-9, ADR-16 macro expansion substrate consumers, etc.).

## Running a walkthrough

Every walkthrough follows the same shape:

```sh
cd examples/<walkthrough-name>/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The `RUBYLIB` prefix puts the walkthrough's `lib/` on the
load path so `Kernel.require("rigor-<id>")` from the plugin
loader resolves to the in-repo source. The demo's `.rigor.yml`
points at the plugin id (and any plugin-specific config); the
demo's `demo.rb` is the user-side code under analysis.

Some demos ship a sibling `errors_demo.rb` listing
intentionally ill-typed code that exercises the plugin's
`:error` paths. Those files would `NoMethodError` / similar
at runtime — analyse them with `rigor check`, do not
`ruby` them.

`rigor-routes` additionally demonstrates the cache surface; run

```sh
cd examples/rigor-routes/demo
RUBYLIB=$PWD/../lib bundle exec rigor check --cache-stats
```

twice to see `plugin.routes.route_table: 0 hits, 1 miss, 1 write`
on the first run and `1 hit, 0 misses, 0 writes` on the second.

## Where the plugin contract is documented

These walkthroughs are the executable counterpart of the spec
corpus. Cross-references:

- **ADR-2 — Extension API** ([`docs/adr/2-extension-api.md`](../docs/adr/2-extension-api.md))
  is the binding design document for the plugin contract.
- **`docs/internal-spec/plugin.md`** — slice-1 normative
  surface (registration, manifest, services, registry).
- **`docs/internal-spec/plugin-trust.md`** — slice-2 normative
  surface (`TrustPolicy`, `IoBoundary`).
- **`docs/internal-spec/flow-contribution-merger.md`** — slice-3
  contribution merger.
- **`docs/internal-spec/plugin-cache-producers.md`** — slice-6
  cache-producer surface (`producer` DSL, `cache_for`).
- **`spec/rigor/public_api_drift_spec.rb`** pins every public
  namespace these walkthroughs touch.

## Integration tests

Each walkthrough has an end-to-end integration spec under
[`spec/integration/examples/`](../spec/integration/examples/)
that pins its behaviour. The shared `PluginHelpers` module
lives at
[`spec/integration/support/plugin_helpers.rb`](../spec/integration/support/plugin_helpers.rb)
and is auto-included for both walkthrough and production
plugin specs.

## License

Each walkthrough is MPL-2.0, matching the parent Rigor
project. The sources are intended as reference material —
fork freely.
