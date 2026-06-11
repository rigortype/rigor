# Rigor production plugins

Thirty entries targeting real Ruby gems, frameworks, and DSLs.
Each keeps a self-contained layout (`lib/` + README + demo +
integration spec), and the set **ships bundled inside the single
`rigortype` gem** (v0.1.11) — you do not add them to your
project's `Gemfile`; you activate the ones you want through
`.rigor.yml`'s `plugins:` list. Bundled plugins are **not**
separately installable gems: the per-plugin gemspecs were dropped
(commit `9769f5fa`) and [ADR-31](../docs/adr/31-contribution-and-supply-chain-policy.md)
settled the distribution model on the single bundled gem (with
third-party plugins living in their authors' own repos, WD4). The
self-contained layout is what lets a third-party author lift a
plugin's shape into their own `rigor-*` gem.

> **Authoring a new plugin?** Read the
> [walkthroughs](../examples/README.md) under `examples/`
> first — they exercise the plugin contract on deliberately
> simplified virtual use cases, one architectural surface per
> example. This catalogue is for **using** plugins on real
> projects.

## Activation

```yaml
# .rigor.yml
plugins:
  - rigor-rails-routes
  - rigor-activerecord
  - rigor-rspec
  - rigor-factorybot
  # ...
```

The Tier 1 + Tier 2 Rails plugins can be bundled via the
[`rigor-rails`](rigor-rails/) Gemfile-convenience meta-gem
(per [ADR-12](../docs/adr/12-dry-rb-packaging.md) WD1) —
adding `gem "rigor-rails"` pulls in seven sub-plugins, but
`.rigor.yml` activation stays per-plugin so users can opt
out of any individual member.

## Catalogue

### Rails ecosystem (Tier 1)

Smallest surface, most likely to be activated everywhere.

| Plugin | Tier | What it checks | I/O | Cache |
| --- | --- | --- | --- | --- |
| [`rigor-rails-routes`](rigor-rails-routes/) | 1A | `config/routes.rb` parser + `_path` / `_url` helper validation; **publishes `:helper_table` as an ADR-9 fact** | Ruby (`config/routes.rb`) | ✅ |
| [`rigor-rails-i18n`](rigor-rails-i18n/) | 1B | `config/locales/*.yml` → `t('key.path')` validation (key existence, per-locale coverage, interpolation matching) | YAML | ✅ |
| [`rigor-actionmailer`](rigor-actionmailer/) | 1C | Mailer call shape + view template existence | Ruby + view templates | ✅ |
| [`rigor-activejob`](rigor-activejob/) | 1D | Job `perform_later` / `perform_now` / `perform` argument arity | Ruby | ✅ |

### Rails ecosystem (Tier 2 + 3)

Larger surfaces — typically need a Rails app shape to make sense.

| Plugin | Tier | What it checks | I/O | Cache |
| --- | --- | --- | --- | --- |
| [`rigor-activerecord`](rigor-activerecord/) | 2 | DSL interpretation + multi-file IoBoundary + chained cache producers + two-pass discover-then-validate; **publishes `:model_index` as an ADR-9 fact** (associations / enums / scopes / validations / callbacks) | Ruby (`db/schema.rb` + `app/models/`) | ✅ ✅ |
| [`rigor-actionpack`](rigor-actionpack/) | 2 | Phase 4 route-helper consumption + Phase 2 filter chain (`before_action :name` against the controller's effective method set) + Phase 3 render-target validation (`render :show` → `app/views/<controller>/show.html.erb`) | Ruby + view templates | ✅ |
| [`rigor-activestorage`](rigor-activestorage/) | 3E | `has_one_attached :avatar` / `has_many_attached :photos` macro discovery + return-type narrowing to `Nominal[ActiveStorage::Attached::One]` / `::Many` | Ruby | ✅ |
| [`rigor-actioncable`](rigor-actioncable/) | 3F | ActionCable channel discovery + `<Channel>.broadcast_to` / `ActionCable.server.broadcast(stream)` validation, with dynamic-stream suppression | Ruby | ✅ |
| [`rigor-pundit`](rigor-pundit/) | 3B | Policy class + predicate method validation for `authorize(record, :action)`; receiver-type lookup via `Scope#type_of` | Ruby | ✅ |
| [`rigor-sidekiq`](rigor-sidekiq/) | 3C | Sidekiq worker `perform_async` / `perform_in` / `perform_at` argument shape; schedule-aware arity model | Ruby | ✅ |

### Rails ecosystem (meta-gem)

| Plugin | Bundles |
| --- | --- |
| [`rigor-rails`](rigor-rails/) | Tier 1+2 Rails plugins (7 gems: rails-routes / rails-i18n / actionmailer / activejob / activerecord / actionpack / factorybot). Gemfile convenience only — users still enumerate the individual plugins they want active in `.rigor.yml`'s `plugins:` list, per [ADR-12](../docs/adr/12-dry-rb-packaging.md) WD1. |

### Testing & matchers (Pillar 2 "Your specs are types")

The testing-side plugins. Activate the relevant ones for
your test framework; they compose freely.

| Plugin | What it does |
| --- | --- |
| [`rigor-rspec`](rigor-rspec/) | Duplicate `let` / `subject` + self-referencing let detection (Tier 3A). v0.2.0 adds **Pillar 2 Slice 1** — `expect(x).to <matcher>` narrows `x` downstream through `:local`-kind `post_return_facts` (eight-matcher floor: `be_a` / `be_kind_of` / `be_instance_of` / `be_an_instance_of` / `be_nil` / `eq(literal)` / `eql(literal)` / `match(/regex/)`; `not_to` / `to_not` negation). v0.3.0 adds **Pillar 2 Slice 2** — `let(:name) { ... }` / `subject(:name) { ... }` block bodies infer their type from `ConstantClass.new(...)` / `described_class.new(...)` / `create(:factory)` and bind the local in `it` bodies. |
| [`rigor-rspec-rails`](rigor-rspec-rails/) | **Behavioral matcher validation** — `have_http_status(int_or_symbol)` floor: Integer must be in 100..599; Symbol must be a Rack `SYMBOL_TO_STATUS_CODE` key OR a Rails status-group alias. Composes with `rigor-rspec` (type-narrowing matchers); activate independently. |
| [`rigor-shoulda-matchers`](rigor-shoulda-matchers/) | **shoulda-matchers ↔ `:model_index` cross-check** — walks `RSpec.describe <ModelConst> do ... end` blocks and validates each `should validate_presence_of(:col)` / `belong_to(:assoc)` / `have_many(:assoc)` / `have_db_column(:col)` / 12 other matchers against the model's known columns / associations. Consumes `:model_index` from `rigor-activerecord` (optional dep); falls silent without it. |
| [`rigor-minitest`](rigor-minitest/) | **Minitest + Test::Unit assertion narrowing** — `assert_kind_of(T, x)` / `assert_instance_of(T, x)` / `assert_nil(x)` / `assert_equal(literal, x)` / `assert_match(regex, x)` + `refute_*` / `assert_not_*` mirrors + Minitest/spec `_(x).must_*` / `.wont_*` matchers (matchers_vaccine covered transitively). Single plugin covers both frameworks. |
| [`rigor-factorybot`](rigor-factorybot/) | Validates `FactoryBot.create(:name, key: ...)` / `.build` / `.attributes_for` / `*_list` against a per-run factory index built from `spec/factories/`. v0.2.0 (**Pillar 2 Slice 3**) publishes `:factory_index` with per-factory `model_class` (inferred from name via camelize, or `class:` keyword option) so downstream consumers — `rigor-rspec` Slice 2's `let(:user) { create(:user) }` binding — can map factory names to Ruby classes. |

### dry-rb foundation

Four plugins forming the dry-rb adapter family per
[ADR-12](../docs/adr/12-dry-rb-packaging.md). Activate any
subset; they cross-reference through ADR-9 facts.

| Plugin | What it does |
| --- | --- |
| [`rigor-dry-types`](rigor-dry-types/) | Recognises `module X; include Dry.Types(); end` and publishes the `{X::String => "String", X::Integer => "Integer", …}` table as the `:dry_type_aliases` cross-plugin fact (15 canonical + 60 nested coercion categories + user-authored compositions + transitive composition references with cycle detection). Foundation gem for the `rigor-dry-*` family. |
| [`rigor-dry-schema`](rigor-dry-schema/) | Recognises `Foo = Dry::Schema.{Params,JSON,define} { ... }` and publishes `:dry_schema_table`. Maps `required(:k).filled(:string)` / `value(Types::Email)` rows to underlying classes; resolves user-authored type references through `:dry_type_aliases`. |
| [`rigor-dry-struct`](rigor-dry-struct/) | **ADR-16 macro expansion substrate Tier C consumer** — declarative `Plugin::Macro::HeredocTemplate` manifest synthesises an instance reader on every `Dry::Struct` subclass for each `attribute :name, T` / `attribute? :name, T`. v0.2.0 reads `:dry_type_aliases` via ADR-18's `returns_from_arg:` for per-call-site precision uplift (`attribute :city, Types::String` returns `Nominal[String]` instead of `Dynamic[Top]`). |
| [`rigor-dry-validation`](rigor-dry-validation/) | Recognises `class T < Dry::Validation::Contract` subclasses; publishes `:dry_validation_contracts`. Ships an RBS overlay typing `Contract#call → Result` + `Result#{success?, failure?, to_h, errors, []}` so `contract.call(input).to_h` chains resolve cleanly. |

### Other ecosystem plugins

| Plugin | What it does |
| --- | --- |
| [`rigor-graphql`](rigor-graphql/) | `class T < GraphQL::Schema::Object` recognition + `field :name, Type, null:` walking + `Schema::{Enum, InputObject, Mutation}` coverage; publishes four cross-plugin facts (`:graphql_type_table`, `:graphql_enum_table`, `:graphql_input_object_table`, `:graphql_mutation_table`). Metadata-recorder shape rather than ADR-16 substrate consumer (graphql-ruby's `field` DSL emits no Ruby methods). |
| [`rigor-devise`](rigor-devise/) | **ADR-16 macro expansion substrate Tier B consumer** — declarative `Plugin::Macro::TraitRegistry` manifest mirroring Devise's `lib/devise/modules.rb` symbol → module table. The substrate explodes each `devise :strategy_a, :strategy_b` call's included modules' RBS instance methods onto the calling AR model. |
| [`rigor-sinatra`](rigor-sinatra/) | **ADR-16 macro expansion substrate Tier A consumer** — declarative `Plugin::Macro::BlockAsMethod` manifest narrows the block body's `self_type` for `get` / `post` / `put` / `delete` / `head` / `options` / `patch` / `link` / `unlink` against `Sinatra::Base` subclasses. |
| [`rigor-sorbet`](rigor-sorbet/) | **External type DSL adapter** — reads inline `sig { params(...).returns(T) }` blocks plus `T.let` / `T.cast` / `T.must` / `T.unsafe` assertions and contributes return types via `dynamic_return` (per ADR-11 / ADR-52). |
| [`rigor-hanami`](rigor-hanami/) | **ADR-28 path-scoped protocol contract** — enforces `#handle(Hanami::Action::Request, Hanami::Action::Response) → void` on every class under `app/actions/**/*.rb`. The engine **provides** `Hanami::Action::Request` / `Hanami::Action::Response` into action bodies (replacing `Dynamic[Top]`) so misuse surfaces as core diagnostics. Plugin ships its own Hanami Action RBS stubs. Config override: `action_path:`. |
| [`rigor-statesman`](rigor-statesman/) | State machine DSL recognition (`state` + `transition` declarations) and `transition_to(:state)` / `can_transition_to?(:state)` validation against the per-class state set. Two-pass collect → validate analysis. |
| [`rigor-activesupport-core-ext`](rigor-activesupport-core-ext/) | **RBS-only community bundle** (not a plugin in the contract sense — no `Rigor::Plugin::Base` subclass). Top ~50 ActiveSupport `core_ext` selectors that dominated the nine-project Rails survey: `Integer`/`Float` Duration & Bytes multipliers; `Time`/`Date`/`DateTime` calculations; `String` inflections / filters / `#exclude?`; `Array.wrap` + `Array#to_sentence` / `#in_groups_of`; `Hash#deep_dup` / `#deep_merge` / `#symbolize_keys`; `Object#blank?` / `#present?` / `#presence` / `#try`. Measured impact across nine survey projects: total diagnostics 12,502 → 3,071 (−75%). Wire via `signature_paths:` in `.rigor.yml`. |
| [`rigor-typescript-utility-types`](rigor-typescript-utility-types/) | **Type-language vocabulary extension** via `Plugin::TypeNodeResolver` ([ADR-13](../docs/adr/13-typenode-resolver-plugin.md)) — maps `Pick<T, K>` / `Omit<T, K>` / `Partial<T>` / `Required<T>` / `Readonly<T>` onto Rigor-canonical shape-projection type functions. |
| [`rigor-mangrove`](rigor-mangrove/) | **Carrier-generic instantiation** for the [Mangrove](https://github.com/kazzix14/mangrove) functional toolkit — contributes `type_args[0]` (the `OkType` / `InnerType`) as the return type of `Result#unwrap!` / `#unwrap_in` / `Option#unwrap_or` and siblings via `dynamic_return`, so unwrapped values dispatch against the carried type instead of `untyped`. Layers on `rigor-sorbet` (which supplies the carrier signatures); emits no diagnostics of its own. The `is_a?` narrowing + `variants do … end` Enum surfaces are deferred ([survey note](../docs/notes/20260530-mangrove-library-survey.md) / [ADR-36](../docs/adr/36-mangrove-enum-nested-class-emission.md)). |
| [`rigor-rbs-inline`](rigor-rbs-inline/) | **Inline-RBS ingestion** ([ADR-32](../docs/adr/32-rbs-inline-comment-ingestion.md)) — runs the upstream rbs-inline library at env-build time via the `source_rbs_synthesizer:` manifest field and contributes the synthesised RBS, gated by the `# rbs_inline: enabled` magic comment (override with the `require_magic_comment: false` plugin-config knob). Backs `rigor check --treat-all-as-inline-rbs`. |
| [`rigor-playground`](rigor-playground/) | **Browser-playground backend** ([ADR-29](../docs/adr/29-browser-playground.md)) — a Rack/Puma app exposing `/check` / `/annotate-lines` / `/type-of` JSON endpoints behind a CodeMirror frontend. A companion gem, **not an analyzer plugin**; the `rigor playground` CLI command requires it. Loads `rigor-rbs-inline` with `require_magic_comment: false` so pasted snippets are analysed as inline-RBS. |

## What's in scope for each plugin

| Cross-plugin fact (ADR-9 channel) | Producer | Consumers |
| --- | --- | --- |
| `:helper_table` | rigor-rails-routes | rigor-actionpack |
| `:model_index` | rigor-activerecord | rigor-actionpack / rigor-factorybot / rigor-shoulda-matchers |
| `:factory_index` (with `model_class`) | rigor-factorybot | rigor-rspec (Pillar 2 Slice 2) |
| `:dry_type_aliases` | rigor-dry-types | rigor-dry-struct / rigor-dry-schema / rigor-dry-validation |
| `:dry_schema_table` | rigor-dry-schema | (rigor-dry-validation slice 2, queued) |
| `:dry_validation_contracts` | rigor-dry-validation | (downstream consumers TBD) |
| `:graphql_type_table` / `:graphql_enum_table` / `:graphql_input_object_table` / `:graphql_mutation_table` | rigor-graphql | (downstream consumers TBD) |

## ADR-16 macro expansion substrate consumers

Three plugins exercise the macro substrate
([ADR-16](../docs/adr/16-macro-expansion.md)) end-to-end —
their plugin bodies are purely declarative
`Plugin::Macro::*` manifest entries with no walker code:

| Plugin | Tier | Substrate API |
| --- | --- | --- |
| [`rigor-sinatra`](rigor-sinatra/) | A | `Plugin::Macro::BlockAsMethod` |
| [`rigor-devise`](rigor-devise/) | B | `Plugin::Macro::TraitRegistry` |
| [`rigor-dry-struct`](rigor-dry-struct/) | C | `Plugin::Macro::HeredocTemplate` |

## License

All plugins are MPL-2.0, matching the parent Rigor project.

## Where the plugin contract is documented

See [`examples/README.md`](../examples/README.md) (the
walkthrough catalogue) and
[`docs/adr/2-extension-api.md`](../docs/adr/2-extension-api.md)
(the binding design). Each plugin's `README.md` documents its
own configuration knobs and limitations.
