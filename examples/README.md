# Rigor plugin examples

Twenty-six entries — twenty-five worked plugins of the **v0.1.0
plugin authoring surface** plus one RBS-only bundle
(`rigor-activesupport-core-ext`). `rigor-sinatra`,
`rigor-dry-struct`, and `rigor-devise` are the first worked
consumers of the **ADR-16 macro expansion substrate** — their
bodies are purely declarative `Plugin::Macro::*` manifest
entries (Tier A, Tier C, and Tier B respectively), with no
walker code. `rigor-dry-types` + `rigor-dry-schema` form the
**dry-rb foundation pair** per [ADR-12](../docs/adr/12-dry-rb-packaging.md):
dry-types publishes the alias table; dry-schema reads it for
constant-reference resolution and publishes its own schema
table.

(The earlier "eighteen worked examples" paragraph reflected the
state on 2026-05-11; subsequent additions are listed in the tables
below.)

Eighteen worked examples of the **v0.1.0 plugin authoring
surface**. Each one is a fully-shaped plugin gem (manifest
+ `lib/` + gemspec) with a runnable demo (`demo/.rigor.yml`,
`demo/demo.rb`, runtime, optional sigs) and an end-to-end
integration spec under
[`spec/integration/examples/`](../spec/integration/examples/).

The first eight examples illustrate the v0.1.0 plugin
contract itself (one architectural surface per plugin).
The nine Rails ecosystem plugins (`rigor-rails-*` /
`rigor-action*` / `rigor-active*` / `rigor-pundit` /
`rigor-sidekiq` / `rigor-rspec`) are working drafts of the
[Rails ecosystem family](../docs/design/20260508-rails-plugins-roadmap.md)
— they layer on top of the same contract but ship as a
distinct readable group. `rigor-actionpack` is the first
**Tier 2** entry and the first concrete consumer of
ADR-9's cross-plugin fact store.

### Plugin-contract examples

| Example | Headline facet | LoC | I/O | Cache | Engine query | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| [`rigor-deprecations`](rigor-deprecations/) | **Config-driven rules** (smallest possible plugin) | ~80 | — | — | — | 10 |
| [`rigor-lisp-eval`](rigor-lisp-eval/) | **Literal AST typing** (interpret a Lisp expression) | ~200 | — | — | — | 9 |
| [`rigor-statesman`](rigor-statesman/) | **Two-pass DSL analysis** (collect → validate) | ~210 | — | — | — | 7 |
| [`rigor-pattern`](rigor-pattern/) | **Engine collaboration** via `Scope#type_of` + literal-string carrier | ~180 | — | — | ✅ | 12 |
| [`rigor-units`](rigor-units/) | **Local-variable flow tracking** through arithmetic | ~280 | — | — | — | 16 |
| [`rigor-routes`](rigor-routes/) | **`IoBoundary` + cache producer** (slice 2 + slice 6) | ~250 | YAML | ✅ | — | 13 |
| [`rigor-activerecord`](rigor-activerecord/) | **Most architecturally complete** — DSL interpretation + multi-file IoBoundary + chained cache producers + two-pass discover-then-validate | ~700 | Ruby (`db/schema.rb` + `app/models/*.rb`) | ✅ ✅ | — | 14 |
| [`rigor-sorbet`](rigor-sorbet/) | **External type DSL adapter** — reads inline `sig { params(...).returns(T) }` blocks and contributes return types via `flow_contribution_for` | ~900 | Ruby (`sig` blocks across `paths:`) | ✅ | — | 30+ |
| [`rigor-typescript-utility-types`](rigor-typescript-utility-types/) | **Type-language vocabulary extension** via `Plugin::TypeNodeResolver` (ADR-13) — maps `Pick<T, K>` / `Omit<T, K>` / `Partial<T>` / `Required<T>` / `Readonly<T>` onto the Rigor-canonical shape-projection type functions | ~150 | — | — | — | 14 |
| [`rigor-sinatra`](rigor-sinatra/) | **Macro expansion substrate, Tier A** (ADR-16) — declarative `Plugin::Macro::BlockAsMethod` manifest entry narrows the block body's `self_type` for `get` / `post` / `put` / `delete` / `head` / `options` / `patch` / `link` / `unlink` against `Sinatra::Base` subclasses. First worked consumer of the macro expansion substrate; the plugin body is purely declarative — no walker, no `diagnostics_for_file`. | ~60 | — | — | — | 2 |
| [`rigor-dry-struct`](rigor-dry-struct/) | **Macro expansion substrate, Tier C** (ADR-16) — declarative `Plugin::Macro::HeredocTemplate` manifest entry synthesises an instance reader on every `Dry::Struct` subclass for each `attribute :name, T` / `attribute? :name, T` call. First worked consumer of `HeredocTemplate`; per WD13 the floor ships `Dynamic[T]` returns + cross-file dispatch resolution. | ~70 | — | — | — | 2 |
| [`rigor-devise`](rigor-devise/) | **Macro expansion substrate, Tier B** (ADR-16) — declarative `Plugin::Macro::TraitRegistry` manifest entry mirroring Devise's `lib/devise/modules.rb` symbol → module table. The substrate's pre-pass explodes each `devise :strategy_a, :strategy_b` call's included modules' RBS instance methods onto the calling AR model. First worked consumer of `TraitRegistry`; floor ships `Dynamic[T]` returns + cross-file dispatch resolution. | ~110 | — | — | — | 2 |
| [`rigor-dry-types`](rigor-dry-types/) | **dry-rb foundation plugin (ADR-12 Tier A)** — recognises `module X; include Dry.Types(); end` and publishes the `{X::String => "String", X::Integer => "Integer", …}` table as the `:dry_type_aliases` cross-plugin fact (ADR-9). Foundation gem for the `rigor-dry-*` family; consumed by `rigor-dry-struct` / `rigor-dry-validation` / `rigor-dry-schema`. Slices 1-4 ship the full alias coverage: canonical + four nested coercion categories + user-authored compositions + transitive composition references with cycle detection. | ~250 | Project source (`paths:` `.rb` files) | — | — | 10 |
| [`rigor-dry-schema`](rigor-dry-schema/) | **dry-rb schema plugin (ADR-12 Tier A)** — recognises `Foo = Dry::Schema.{Params,JSON,define} { ... }` assignments and publishes the per-schema `{required: {key => underlying_class}, optional: {…}}` table as the `:dry_schema_table` cross-plugin fact (ADR-9). Maps `required(:k).filled(:string)` / `required(:k).value(:integer)` / `optional(:k).maybe(:string)` predicate rows to underlying classes; resolves `value(Types::Email)` user-authored references through `:dry_type_aliases` published by `rigor-dry-types`. Floor for the future `rigor-dry-validation` plugin per [the slicing plan](../docs/design/20260517-dry-validation-slicing.md). | ~250 | Project source (`paths:` `.rb` files) | — | — | 9 |

### Rails ecosystem family

| Example | Tier | Headline facet | I/O | Cache | Tests |
| --- | --- | --- | --- | --- | --- |
| [`rigor-rails-routes`](rigor-rails-routes/) | 1A | Real `config/routes.rb` parser + `_path` / `_url` helper validation; **publishes `:helper_table` as an ADR-9 fact** | Ruby (`config/routes.rb`) | ✅ | 11 |
| [`rigor-rails-i18n`](rigor-rails-i18n/) | 1B | `config/locales/*.yml` → `t('key.path')` validation (key existence, per-locale coverage, interpolation matching) | YAML | ✅ | 11 |
| [`rigor-actionmailer`](rigor-actionmailer/) | 1C | Mailer call shape + view template existence | Ruby (`app/mailers/`) + view templates | ✅ | 11 |
| [`rigor-activejob`](rigor-activejob/) | 1D | Job `perform_later` / `perform_now` / `perform` argument arity | Ruby (`app/jobs/`) | ✅ | 9 |
| [`rigor-pundit`](rigor-pundit/) | 3B | Policy class + predicate method validation for `authorize(record, :action)`; receiver-type lookup via `Scope#type_of` | Ruby (`app/policies/`) | ✅ | 12 |
| [`rigor-sidekiq`](rigor-sidekiq/) | 3C | Sidekiq worker `perform_async` / `perform_in` / `perform_at` argument shape; schedule-aware arity model | Ruby (`app/workers/`, `app/sidekiq/`) | ✅ | 11 |
| [`rigor-actioncable`](rigor-actioncable/) | 3F | ActionCable channel discovery + `<Channel>.broadcast_to` / `ActionCable.server.broadcast(stream)` validation, with dynamic-stream suppression | Ruby (`app/channels/`) | ✅ | 9 |
| [`rigor-rspec`](rigor-rspec/) | 3A | Duplicate `let` / `subject` + self-referencing let detection (deliberately minimal — mock-target validation + let-typo deferred) | — | — | 11 |
| [`rigor-actionpack`](rigor-actionpack/) | 2 | **Phase 4** — route-helper consumption (first concrete ADR-9 consumer); **Phase 2** — filter chain validation (`before_action :name` against the controller's effective method set, including one level of inheritance); **Phase 3** — render-target validation (`render :show` → `app/views/<controller_path>/show.html.erb`) | Ruby (`app/controllers/`) + view templates | ✅ | 21 |
| [`rigor-factorybot`](rigor-factorybot/) | 2 | **Phase 1 (a)** — self-contained validation of `FactoryBot.create(:name, key: ...)` / `.build` / `.attributes_for` / `*_list` against a per-run factory index built from `spec/factories/`. Phase 1 (c) AR column cross-check is queued | Ruby (`spec/factories/`) | ✅ | 10 |
| [`rigor-activestorage`](rigor-activestorage/) | 3E | `has_one_attached :avatar` / `has_many_attached :photos` macro discovery on AR models + return-type narrowing to `Nominal[ActiveStorage::Attached::One]` / `::Many` via `flow_contribution_for` (instance navigation tier) | Ruby (`app/models/`) | ✅ | 11 |

### RBS-only community bundles

Not "plugins" in the v0.1.0 plugin-contract sense (no `Rigor::Plugin::Base`
subclass, no `manifest(...)`); shipped instead as opt-in `sig/`
directories that the user wires into `.rigor.yml`'s `signature_paths:`.

| Bundle | Scope | Coverage |
| --- | --- | --- |
| [`rigor-activesupport-core-ext`](rigor-activesupport-core-ext/) | Top ~50 ActiveSupport `core_ext` selectors that dominated the nine-project Rails survey (`docs/notes/20260515-real-world-rails-survey.md`). | `Integer`/`Float` Duration & Bytes multipliers; `Time`/`Date`/`DateTime` calculations; `String` inflections / filters / `#exclude?`; `Array.wrap` + `Array#to_sentence` / `#in_groups_of` / `#compact_blank` / `#exclude?` / `Enumerable#index_with` / `#index_by` / `#pluck` / `#pick`; `Hash#deep_dup` / `#deep_merge` / `#symbolize_keys` family / `Hash.from_xml` / `#compact_blank` / `#reverse_merge`; `Object#blank?` / `#present?` / `#presence` / `#try`. Measured impact: total diagnostics across the nine survey projects 12,502 → 3,071 (−75%). |

All twenty rely on **slice 5**
(`Plugin::Base#diagnostics_for_file`) to surface
diagnostics. The "headline facet" column names the
*additional* surface each example spotlights — that is the
column to read when you have a specific question about how
to use one part of the plugin contract.

## Recommended reading order

Pick the path that matches what you are trying to learn:

| Your goal | Read in this order |
| --- | --- |
| **Author your first plugin (under 100 lines)** | `rigor-deprecations` |
| **Inspect a method call's literal arguments** | `rigor-lisp-eval` → `rigor-pattern` |
| **Track types through a series of statements** | `rigor-units` |
| **Validate references to declarations from earlier in the same file** | `rigor-statesman` |
| **Read a project file (`config/routes.rb` style) under TrustPolicy + cache the parse** | `rigor-routes` |
| **Combine DSL interpretation, multi-file IoBoundary, chained cache producers, two-pass analysis** | `rigor-activerecord` |
| **Adapt an external type DSL (Sorbet sig / T.let) into Rigor's narrowing engine** | `rigor-sorbet` |
| **Author a Rails ecosystem plugin (Tier 1)** | `rigor-activejob` (smallest) → `rigor-rails-i18n` → `rigor-actionmailer` → `rigor-rails-routes` (largest, publishes ADR-9 fact) |
| **Validate against an inferred-type catalog (Pundit-style)** | `rigor-pundit` — uses `Scope#type_of` to map records to policy classes |
| **Discover via mixin (`include`) instead of inheritance** | `rigor-sidekiq` — direct-`include` match against marker modules; same arity model as `rigor-activejob` |
| **Walk DSL calls inside method bodies (not just at class level)** | `rigor-actioncable` — `stream_from "..."` lives inside `def subscribed`, requiring a recursive descent for registration discovery |
| **Build a nested-scope tree per file (DSL with describe/context)** | `rigor-rspec` — `ScopeWalker` collects `describe` / `context` blocks; declarations are scope-local |
| **Read every example to internalise the architecture** | deprecations → lisp-eval → statesman → pattern → units → routes → activerecord → sorbet → activejob → rails-i18n → actionmailer → rails-routes → pundit → sidekiq → actioncable → rspec |

The recommended-for-everyone path runs from the smallest
plugin (`rigor-deprecations`, ~80 lines, pure data → rules) up
through the most architecturally complete one (`rigor-routes`,
which exercises every v0.1.0 slice). The Rails ecosystem
plugins layer on top of that contract — start with
`rigor-activejob` if your interest is "validate a Rails-style
DSL"; start with `rigor-rails-routes` if your interest is
"publish a fact for downstream plugins to consume".

## What each example exercises (architectural map)

| Surface | Where it lives | Examples that use it |
| --- | --- | --- |
| `Rigor::Plugin::Base.manifest(...)` | manifest declaration | all eighteen |
| `config_schema` (`:string` / `:array` / `:hash` kinds) | manifest body | deprecations / lisp-eval / pattern / statesman / activejob / rails-i18n / rails-routes / actionmailer / pundit / sidekiq / actioncable |
| `manifest(produces: [:fact_name])` (ADR-9 cross-plugin) | fact publication | **rails-routes** |
| `manifest(consumes: [...])` (ADR-9 cross-plugin) | fact consumption + topo-sort dependency | **actionpack** |
| `services.fact_store.read(plugin_id:, name:)` | cross-plugin consumer hook | **actionpack** |
| `#init(services)` config plumbing | init hook | lisp-eval / pattern / statesman / routes / sorbet / seven Rails ecosystem plugins (excludes rspec — no config) |
| `#prepare(services)` (ADR-9 fact publish) | post-init service handoff | **rails-routes** |
| `#diagnostics_for_file(path:, scope:, root:)` | slice-5 emission hook | all eighteen |
| `#flow_contribution_for(node, scope)` | return-type contribution | lisp-eval / pattern / units / activerecord / sorbet |
| `Rigor::Analysis::Diagnostic` construction | diagnostic emission | all eighteen |
| `source_family: "plugin.<id>"` auto-stamp | runner-side, never set by plugin | all eighteen |
| `Plugin::IoBoundary#read_file` (slice 2) | sandboxed file reads | routes / activerecord / sorbet / seven Rails ecosystem plugins (excludes rspec — per-file only) |
| `Plugin::TrustPolicy.allowed_read_roots` (slice 2) | declarative read-root policy | every IoBoundary user above (transitively) |
| `Plugin::Base.producer` DSL (slice 6) | cached producer declaration | routes / activerecord / sorbet / seven Rails ecosystem plugins (excludes rspec) |
| `Plugin::Base#cache_for` callable (slice 6) | cache round-trip wrapper | routes / activerecord / sorbet / seven Rails ecosystem plugins (excludes rspec) |
| `Scope#type_of(node)` | engine query for an expression's inferred type | **pattern** / sorbet (receiver resolution) / **pundit** (record-type → policy-class lookup) |
| `Type::Combinator.literal_string_compatible?` | engine-side literal-string predicate | **pattern** |
| `Type::Constant#value` | exact-value extraction | **pattern** |
| `Type::Nominal#class_name` | mapping inferred type to a class-name string | sorbet / **pundit** |
| Two-pass walk (collect → validate) | pattern, not API | **statesman** / actionmailer / activejob / rails-i18n / pundit / sidekiq / actioncable / rspec |
| Local-variable binding map across statements | pattern, not API | **units** |
| Mixin (`include M`) discovery vs. superclass discovery | pattern, not API | **sidekiq** (mixin) vs. activejob / actionmailer (superclass) |
| Recursive method-body walk for nested DSL calls | pattern, not API | **actioncable** (`stream_from` inside `def subscribed`) |
| Nested-scope tree (describe / context) | pattern, not API | **rspec** (`ScopeWalker`) |
| Did-you-mean on multiple axes | pattern, not API | rails-routes (helper names) / rails-i18n (keys) / pundit (class + method) / actioncable (channel + stream) |

The unmarked surfaces — return-type contributions, custom
node-scoped `Rule<TNode>`, plugin-author logging — are queued
for later v0.1.x slices. Future-direction notes live at the
head of each example's `lib/rigor/plugin/<id>.rb` and in the
relevant README section.

## Running an example

Every example follows the same shape:

```sh
cd examples/<plugin-name>/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The `RUBYLIB` prefix puts the plugin's `lib/` on the load path
so `Kernel.require("rigor-<plugin-name>")` from the plugin
loader resolves to the in-repo source. The demo's `.rigor.yml`
points at the plugin id (and any plugin-specific config); the
demo's `demo.rb` is the user-side code under analysis.

Some demos ship a sibling `errors_demo.rb` listing intentionally
ill-typed code that exercises the plugin's `:error` paths. Those
files would `NoMethodError` / similar at runtime — analyse them
with `rigor check`, do not `ruby` them.

`rigor-routes` additionally demonstrates the cache surface; run

```sh
cd examples/rigor-routes/demo
RUBYLIB=$PWD/../lib bundle exec rigor check --cache-stats
```

twice to see `plugin.routes.route_table: 0 hits, 1 miss, 1 write`
on the first run and `1 hit, 0 misses, 0 writes` on the second.

## Where the plugin contract is documented

These examples are the executable counterpart of the spec
corpus. Cross-references:

- **ADR-2 — Extension API** ([`docs/adr/2-extension-api.md`](../docs/adr/2-extension-api.md))
  is the binding design document for the plugin contract.
- **`docs/internal-spec/plugin.md`** — slice-1 normative
  surface (registration, manifest, services, registry).
- **`docs/internal-spec/plugin-trust.md`** — slice-2 normative
  surface (`TrustPolicy`, `IoBoundary`).
- **`docs/internal-spec/flow-contribution-merger.md`** — slice-3
  contribution merger (analyzer-internal today; the wire plugins
  will emit bundles through later).
- **`docs/internal-spec/plugin-cache-producers.md`** — slice-6
  cache-producer surface (`producer` DSL, `cache_for`).
- **`spec/rigor/public_api_drift_spec.rb`** pins every public
  namespace the examples touch. When the contract changes, the
  drift spec updates in the same commit.

## Status note

`v0.1.1` shipped the `FlowContribution`-based plugin
contribution substrate (Track 2 slice 7 —
`Plugin::Base#flow_contribution_for`). `v0.1.2` migrated the
four examples whose runtime returns a typeable value to it:
`rigor-lisp-eval`, `rigor-pattern`, `rigor-units`, and
`rigor-activerecord`. Those plugins now both emit the
diagnostic trace and narrow the call site's return type, so
chained calls (`User.find(1).name`,
`Lisp.eval([:+, 1, 2]).bit_length`,
`(distance / time).in_kilometers_per_hour`) resolve through
the analyzer's normal dispatch instead of the RBS-level
`untyped` envelope.

`v0.1.3` (in progress, unreleased) adds:

- **`rigor-sorbet`** — adapter for inline Sorbet `sig`
  blocks and `T.let` / `T.cast` / `T.must` / `T.unsafe`
  assertions (eight slices landed across ADR-11). Reads
  every `paths:` entry's `.rb` files for `sig` declarations
  and contributes return types via `flow_contribution_for`.
- **Rails ecosystem family** — Tier 1 + 3A + 3B + 3C + 3F
  plugins per
  [`docs/design/20260508-rails-plugins-roadmap.md`](../docs/design/20260508-rails-plugins-roadmap.md):
  `rigor-rails-routes`, `rigor-rails-i18n`,
  `rigor-actionmailer`, `rigor-activejob` (Tier 1 — current
  API), `rigor-pundit` (Tier 3B — uses `Scope#type_of`
  for receiver-type → policy-class resolution),
  `rigor-sidekiq` (Tier 3C — discovery via `include`
  marker module, schedule-aware arity model for
  `perform_in` / `perform_at`), `rigor-actioncable`
  (Tier 3F — channel + stream-name index, dynamic-stream
  suppression), and `rigor-rspec` (Tier 3A —
  deliberately scoped to `let` / `subject` validation;
  the heavier mock-target / let-typo detection from the
  roadmap is queued for v0.2.x). All eight are
  diagnostic-only for v0.1.0 of each plugin, with future
  cross-plugin handoff (e.g. `rigor-rails-routes`'s
  `:helper_table` ADR-9 fact, or `rigor-actioncable`'s
  action-method map) queued for downstream consumers.

`rigor-deprecations`, `rigor-statesman`, and `rigor-routes`
stay diagnostic-only by design: deprecation reports and
state-machine declarations have no return-type fit, and
route helpers are already RBS-expressible. Each example's
README "Future direction" section names the remaining
surfaces queued for later v0.1.x or v0.2.x slices.

## License

Each example is MPL-2.0, matching the parent Rigor project. The
example sources are intended as reference material — fork freely.
