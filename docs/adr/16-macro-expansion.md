# ADR-16 — Macro / DSL expansion substrate

Status: **proposed, 2026-05-15.** Triggered by the per-library survey
[`docs/notes/20260515-macro-expansion-library-survey.md`](../notes/20260515-macro-expansion-library-survey.md)
covering Rails (`ActiveSupport::Concern`, ActiveStorage attached macros),
AASM, Devise, GraphQL-Ruby, factory_bot, Sinatra, Sequel, and Redmine.
Implementation queued, no committed milestone. ADR-12 (dry-rb packaging)
remains reserved; this ADR sits in parallel and does not block on it.

## Context

Rigor's open work item O2 (ROADMAP) has carried the placeholder "macro-
template + heredoc-Ruby expansion" since v0.1.5. The motivating real-world
cases were tDiary Core's `instance_eval`-loaded plugin files (35 FP / file
on legacy plugins) and Rails generator templates that ship as `.rb` but
contain ERB interpolations. The per-library survey extended that picture
across the broader Ruby DSL zoo to determine whether a shared substrate is
warranted and what shape it should take.

The survey produced two strong signals.

**Signal 1 — most of the surveyed DSL shapes share three recurring
expansion patterns.** Counting only the subsystems where macro-style
expansion is feasible at all (excluding GraphQL-Ruby, which is a
schema-graph recorder, and Sequel column accessors, which need a database
oracle):

| Pattern | Survey sites | Description |
| --- | --- | --- |
| (i) **Block-as-method** | Sinatra `get/post/…`, AASM `event :x do`, ActiveStorage `included do`, factory_bot `factory :user do` (definition-side), Redmine `Redmine::Plugin.register :id do` | A block passed to a class-level DSL call runs as a method body (or as DSL recorder) with a declared `self`-type. `Sinatra::Base#generate_method` literally does `define_method(name, &block); remove_method`. |
| (ii) **Heredoc template parameterised by literal symbols** | ActiveStorage `has_one_attached :avatar` (`activestorage/lib/active_storage/attached/model.rb:111-126`), Devise `define_helpers` (`lib/devise/controllers/helpers.rb:116-134`), Devise `Mapping.add_module` predicate synth (`lib/devise/mapping.rb:113-119`), Redmine `Setting.define_setting` (`app/models/setting.rb:333-350`), Redmine `acts_as_event` (`lib/plugins/acts_as_event/lib/acts_as_event.rb:48-62`), Redmine `LabelledFormBuilder` (`lib/redmine/views/labelled_form_builder.rb:25-33`) | A `class_eval <<~SRC … SRC` heredoc emits N method definitions whose names interpolate source-visible literal arguments. |
| (iii) **Trait-inlining via a bundled module registry** | Devise model side (`devise :database_authenticatable, …`), AASM `state :x` / `event :x`, Sequel `one_to_many :posts`, AASM-via-Concern, Devise-via-Concern | A class-level call enumerates symbols; the analyzer consults a bundled registry mapping each symbol to a module / method-name table and applies the contributions to the calling class. |

A fourth pattern — **(iv) external-Ruby-file inclusion under a declared
`self`** — appears in Redmine's `webhook_payload.rb` (`instance_eval(File.read(path), path, 1)`,
`app/models/webhook_payload.rb:71`) and in tDiary Core's plugin loader.
This is PHPStan's stub-files pattern in Ruby clothing: a file shipped
outside the analyzed source tree, parsed as if pasted at the call site
with a stated receiver type.

The dominant pattern is (ii); the cleanest is (i); the most
registry-shaped is (iii); the most boundary-shaped is (iv). The survey
found **no instance of genuine "pattern (d)" runtime-data string-eval**
across the surveyed projects — every `class_eval` / `eval` site
interpolates either source-visible literals or values reachable via one
indirection (YAML, plugin registry, sibling constants).

**Signal 2 — `ActiveSupport::Concern`'s `included do … end` is a
re-targeting concern, not a fifth expansion pattern.** The `class_eval(&@_included_block)`
at `activesupport/lib/active_support/concern.rb:138` runs the block with
the includer as `self`. Whatever DSL calls already live inside the block
(`has_one_attached`, `has_many`, AASM `state`, Devise's per-module
`included do`) fire on the includer; the analyzer's job is to rebind the
block's lexical receiver, not to expand it differently. Treating Concern
as a *re-target operator over patterns (i)–(iv)* keeps the substrate
small.

**Current state of macro-shaped handling in rigor.** Every existing
example plugin that touches a macro DSL implements its own walker:

- `rigor-activestorage` walks `has_one_attached :name` calls and
  contributes a return type for the synthetic accessor.
- `rigor-activerecord` walks `belongs_to` / `has_one` and contributes
  `Nominal[Target] | nil`.
- `rigor-factorybot` walks `FactoryBot.create(:user)` and contributes
  the return type from the factory registry.
- `rigor-statesman` walks the state-machine DSL and contributes
  per-state / per-event method facts.

The walkers do not share substrate: each re-implements (a) literal-symbol
extraction from the call AST, (b) name-interpolation, (c) registry
storage, (d) integration with `Plugin::Base#flow_contribution_for`. The
per-walker approach scales linearly with plugin count and forces each new
plugin author to re-derive boilerplate the survey now demonstrates is
common.

## Audience and purpose

ADR-16 distinguishes **three stakeholder roles**, with different
audiences for the substrate, the per-library plugin, and the
fallback heuristic respectively. Confusing them produced the earlier
"primary audience: plugin authors" formulation, which conflated two
distinct populations.

| Role | Who | What they consume |
| --- | --- | --- |
| Library developer | Maintainer of a metaprogramming-shaped library (e.g. the AASM core team, the dry-rb team, a Rails component maintainer) | The substrate — to declare their DSL's call shapes once, either bundled with their library or via a sibling `rigor-<lib>` plugin gem. |
| Library user | Application author who depends on the library | The `rigor-<lib>` plugin (when one exists), enabled via `.rigor.yml`'s `plugins:` list. They never see the substrate directly. |
| rigor itself, as fallback | The analyzer in projects where no `rigor-<lib>` is enabled for a depended-on library | A best-effort substrate-shaped heuristic (when achievable cheaply) that recognises the library's macros at minimum quality. |

### Primary purpose

**The substrate is a declarative authoring layer for library
developers.** Whether the declarations ship in the library's own gem
(`lib/foo/rigor.rb` or a sidecar config), in a separate `rigor-foo`
plugin gem, or as community-maintained sidecar configuration, the
substrate's value is in lowering the cost of authoring those
declarations. Application authors are not the audience — they install
plugins, they do not write substrate entries.

The traditional ADR-2 hand-rolled plugin route remains available; the
substrate is the convenience option for the patterns the survey shows
recur (Tiers A–D).

### Secondary purpose (best-effort, NOT a requirement)

**When an application depends on a library `foo` but no `rigor-foo`
is enabled, the substrate MAY apply heuristic pattern matching to
recognise `foo`'s macros at minimum quality** — e.g. detecting a
heredoc `class_eval` with literal-symbol interpolation and emitting
synthetic readers for the visible method names, without requiring
a `rigor-foo` declaration.

This path is bounded by three hard constraints:

- **Performance bound.** Secondary recognition MUST NOT add measurable
  wall-clock cost beyond what an "ignore unrecognized macros" baseline
  would pay. If a heuristic forces a measurable slowdown on the warm-
  cache `rigor check` profile, it is dropped. Per ADR-15 the analyzer's
  inference cost is the dominant share (~50%); the secondary path
  cannot grow that.
- **Exclusion.** When a `rigor-foo` plugin IS enabled, the secondary
  heuristic does NOT also run on that library's call sites. The two
  are mutually exclusive at use-site to keep interpretation cost
  bounded. The dedicated plugin always wins; rigor does not double-
  process.
- **No correctness guarantee.** The secondary path is "best-effort
  try"; an application author who wants precise typing installs the
  dedicated plugin. Heuristic-derived facts carry a
  `macro.heuristic.<id>` provenance marker so downstream consumers
  (diagnostics, `--explain`) can distinguish plugin-authored facts
  from heuristic-derived ones.

The secondary purpose is an *aspiration*, not an obligation. The
substrate ships its primary purpose (library-developer declaration)
even if no heuristic detection is ever implemented. WD12 records the
trade-off in detail.

### Default principle

**Per-library dedicated plugins remain the preferred shape.** Each
metaprogramming-providing library (Rails, AASM, Devise, Sequel,
dry-types, …) gets its own `rigor-<lib>` plugin — same model as the
existing `rigor-activestorage` / `rigor-activerecord` /
`rigor-statesman` plugins. ADR-16 does not change that default; it
lowers the cost of authoring each such plugin by absorbing the
repeating name-interpolation / registry / call-shape plumbing into
the substrate.

**For the libraries surveyed in
[`docs/notes/20260515-macro-expansion-library-survey.md`](../notes/20260515-macro-expansion-library-survey.md)**:
each is a target for a future library-user-facing plugin. The
substrate makes those plugins cheap to author. The coverage map is
fixed in § Decision § Planned per-library plugins. Libraries whose
DSL does not fit substrate expansion (GraphQL-Ruby, Sequel column
accessors) still get future plugins — they just ride the regular
ADR-2 plugin contract instead of the new substrate. The "no
substrate" path stays a first-class option.

## Goals

- **Substrate reuse.** Authors of a new plugin targeting a heredoc-template
  DSL (the dominant pattern) should declare the template and the literal
  parameters, not hand-write AST walking and name interpolation.
- **Hygiene.** Expansion outputs are pure functions of source AST plus
  plugin-declared registries. No Ruby execution, no IO at expansion time,
  no observation of runtime state.
- **Composability with the existing plugin contract** (ADR-2,
  [ADR-7](7-v0.1.0-slice-decisions.md), [ADR-9](9-cross-plugin-api.md)).
  The substrate sits *under* the existing extension API; existing plugins
  keep working unchanged, new plugins opt into substrate use through
  declarative registrations on the manifest.
- **Ractor-safety** ([ADR-15](15-ractor-concurrency.md)). Substrate
  outputs are `Ractor.shareable?` at construction. Per-Ractor materialisation
  follows the Phase 3a plugin-blueprint convention.
- **Composability with `ActiveSupport::Concern`.** A re-targeting walker
  for `included do` makes any substrate-using plugin fire correctly when
  the DSL call is wrapped in a concern's deferred block.
- **Cacheability.** Expanded synthetic ASTs participate in
  `Cache::Store` with deterministic descriptors per
  [ADR-6](6-cache-persistence-backend.md).

## Non-Goals

- **Running arbitrary Ruby code.** No interpreter on heredoc bodies, no
  `eval` of user-side templates. Substrate inputs are AST literals plus
  plugin-declared registries.
- **Solving GraphQL-Ruby.** The survey demonstrates it is a schema-graph
  recorder with `Proc` and `String#constantize` lazy types as
  first-class inputs. A future `rigor-graphql` plugin needs a
  schema-resolution pass, not macro expansion. Excluded explicitly.
- **Solving Sequel column accessors.** They depend on a live database
  schema. A separate ADR addresses schema oracles when concrete user
  demand surfaces.
- **ERB-templated `.rb` files** (Rails generator `templates/*.rb`
  shipping `<%= … %>` interpolations). Adjacent but distinct: needs
  filename-pattern detection and an ERB-aware parser pass *before* the
  substrate fires. Tracked as a separate ROADMAP item that consumes this
  ADR's substrate downstream.
- **Forcing all current plugins to migrate.** The substrate is opt-in.
  Existing walkers in `examples/rigor-activestorage/` etc. continue to
  work; migration is a follow-up exercise demonstrating the substrate's
  reach.

## Decision

Land a **four-tier expansion substrate** registered through the
existing plugin manifest, with an explicit fifth pattern (Concern
re-targeting) handled by extending the AS::Concern walker rather than
by adding a tier. The dynamic-return-type extension (factory_bot shape)
is already covered by ADR-2 + ADR-9 and is restated here for symmetry
only — no new mechanism.

### Tier A — Block-as-method (Sinatra-shape)

Plugin declares: a class-level DSL call of a named shape promotes its
block to an instance method on the calling class, with `self` typed as
an instance of that class.

```ruby
class RigorSinatra < Rigor::Plugin::Base
  manifest(
    id: "sinatra",
    block_as_method: [
      # When X < Sinatra::Base and X.get(path, &block) is called,
      # the block is an instance method on X with self : X.
      Macro::BlockAsMethod.new(
        receiver_constraint: "Sinatra::Base",
        verbs: %i[get post put delete head options patch link unlink],
        self_type: :receiver_instance,
        scope_methods: [:params, :request, :response, :env, :app,
                        :erb, :redirect, :halt, :session, :headers,
                        :content_type, :body, :status]
      )
    ]
  )
end
```

The block AST is not rewritten. The substrate annotates the block's
lexical scope so the inference engine sees `self : Sinatra::Base
subclass`, with the declared `scope_methods` available as bare
identifiers. Helpers and accessors come from RBS for `Sinatra::Base` —
the plugin does not redeclare them.

Reaches: Sinatra, RSpec nested contexts (a follow-up plugin), the
factory_bot definition-side `factory :user do … end` block (recorder,
not method body — but the receiver-typing primitive is shared).

### Tier B — Trait inlining via bundled registry (Devise-shape)

Plugin declares: a class-level DSL call enumerates symbols; each
symbol resolves through a bundled registry to a `Module` constant
and a list of contributions (instance method facts, class-method
facts, `included do` side effects pre-recorded as fact tables).
Applied to the calling class in registry-declared order.

```ruby
class RigorDevise < Rigor::Plugin::Base
  manifest(
    id: "devise",
    trait_registries: [
      Macro::TraitRegistry.new(
        call_shape: { receiver_constraint: "ActiveRecord::Base",
                      method_name: :devise },
        symbol_arg_position: :rest,
        modules_by_symbol: {
          database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
          recoverable: "Devise::Models::Recoverable",
          rememberable: "Devise::Models::Rememberable",
          # …
        },
        always_included: ["Devise::Models::Authenticatable"],
        sort_key: ALL_ORDER  # mirrors lib/devise/modules.rb
      )
    ]
  )
end
```

Substrate behaviour:

- For each symbol argument, look up the module constant; emit an
  `include` fact equivalent to `include Devise::Models::X` on the
  calling class.
- For each module, the bundled registry MAY also declare an
  `included_do` digest — a static list of method facts that the
  module's `included do` block would have added. Authored once per
  plugin release, NOT replayed at runtime.
- Class-level contributions (`extend ClassMethods`) follow the same
  shape, with a separate `class_methods_module` entry per module.

Reaches: Devise model side (`devise :…`), AASM `state :x` / `event :x`
(when re-cast as trait registries over the generated method table),
Sequel associations (`one_to_many :posts` → fixed method-name
table), Devise routes side (with the call-shape pointing at
`devise_for :resources`).

### Tier C — Heredoc-template expansion with literal-symbol parameters

Plugin declares: a class-level DSL call emits N synthetic method
definitions whose names interpolate source-visible literal arguments.
Substrate emits synthetic AST nodes attached to the calling class.

```ruby
class RigorActivestorage < Rigor::Plugin::Base
  manifest(
    id: "activestorage",
    heredoc_macros: [
      Macro::HeredocTemplate.new(
        call_shape: { receiver_constraint: "ActiveRecord::Base",
                      method_name: :has_one_attached },
        symbol_arg_position: 0,
        emit: [
          { name: "#{name}",   returns: "ActiveStorage::Attached::One" },
          { name: "#{name}=",  params: [{ name: :attachable,
                                          type: "ActiveStorage::Attachable" }],
                               returns: "void" },
          { name: "#{name}_attachment",
                               returns: "ActiveStorage::Attachment?" },
          { name: "#{name}_blob",
                               returns: "ActiveStorage::Blob?" }
        ],
        class_level_emit: [
          { name: "with_attached_#{name}",
            returns: "ActiveRecord::Relation[T]" }
        ]
      )
    ]
  )
end
```

The substrate produces synthetic `Type::Method` carriers (per the
internal `Rigor::Type::Method` shape introduced in v0.1.5's
`Type::BoundMethod` work) and registers them on the calling class's
method dispatcher. The carriers are flagged as `synthetic: true` for
diagnostic provenance.

Constraint: every name interpolation MUST resolve to a source-visible
literal Symbol or String. Non-literal arguments (`has_one_attached(some_method)`)
fall through to the existing plugin walker hooks (or to no handling at
all).

Reaches: ActiveStorage attached macros, Devise per-mapping helper
quad (`current_user`, `user_signed_in?`, `authenticate_user!`,
`user_session`), Redmine's `Setting.define_setting`, Redmine
`acts_as_event` and `LabelledFormBuilder` heredocs.

### Tier D — External-Ruby-file inclusion under declared `self`

Plugin declares: files matching a glob are evaluated as if their body
were pasted at a declared call site, with `self` typed as a declared
class. The substrate adds the file's AST to analysis with the bound
receiver type.

```ruby
class RigorRedminePayloads < Rigor::Plugin::Base
  manifest(
    id: "redmine-webhook-payloads",
    external_file_inclusions: [
      Macro::ExternalFile.new(
        glob: "config/webhooks/*.rb",
        receiver_type: "Redmine::WebhookPayload",
        # ivars accessible inside the file:
        bound_ivars: { "@event" => "Symbol",
                       "@issue" => "Issue?",
                       "@user"  => "User" }
      )
    ]
  )
end
```

Closest analogue: PHPStan stub files. The mechanism is
`instance_eval(File.read(path), path, 1)` at runtime; statically, the
file's body is parsed once and added to the analysis fileset with the
plugin-declared receiver / ivar typing context. No execution.

Reaches: Redmine webhook payload templates, tDiary Core's
`instance_eval`-loaded plugin files (`misc/plugin/category-legacy.rb`
and siblings — the original O2 motivating case).

### Concern re-targeting (not a tier — walker extension)

`ActiveSupport::Concern.included do … end` is implemented as a
deferred `class_eval(&block)` at `activesupport/lib/active_support/concern.rb:138`.
The analyzer already walks `included do` (partially); extend that
walker so that when the deferred block contains a Tier-A / Tier-B /
Tier-C call, the substrate fires with the includer as the calling
class.

No new manifest entry. The Concern walker is part of the
`rigor-activesupport-core-ext` family or a sibling under `examples/`.

### Out of scope as a tier

| Shape | Why not a tier |
| --- | --- |
| Dynamic return type from a registry (factory_bot's `create(:user)`) | Already covered by ADR-2 dynamic-return-type extension + ADR-9 fact-store. `rigor-factorybot` works. No substrate gap. |
| GraphQL-Ruby field DSL | The DSL does not emit methods. Needs a schema-resolution pass that re-implements `Schema::Member` traversal — a separate ADR when demand surfaces. |
| Sequel column accessors | Need a live database schema. Separate ADR. |
| ERB-templated `.rb` files | Need a parse-time ERB pass before the substrate fires. Tracked as a separate ROADMAP item that consumes Tier D + an ERB front-end. |
| Pattern (d) runtime-data string-eval | Survey found no real-world example. If one surfaces, handle via `Dynamic[T]` degradation, not a substrate tier. |

### Planned per-library plugins

For traceability — these are the plugins the substrate is designed to
serve. Each is a future library-user-facing plugin that consumes
either the substrate (the rows naming a tier) or the regular ADR-2
extension API (the "no substrate" rows). Authoring each is gated on
user authorisation; the substrate enables them without committing to
any particular one. Rows marked "authored" already exist under
`examples/` and are candidates for migration onto the substrate.

**Interaction with the secondary heuristic** (§ Audience and purpose,
WD11): when any row below is enabled in `.rigor.yml`'s `plugins:`,
the substrate's secondary-purpose heuristic does NOT also run on
that library's call sites. The dedicated plugin owns its claimed
call shapes; the heuristic only fires on libraries where no
dedicated plugin is configured.

| Plugin | Tier(s) consumed | Survey reference | Status |
| --- | --- | --- | --- |
| `rigor-sinatra` | A | Sinatra section | Not yet authored. Substrate slice-1 validation target. |
| `rigor-devise` | B (model side) + C (per-mapping controller helpers) | Devise section | Not yet authored. Substrate slice-3 validation target. Bundled module registry mirrors `lib/devise/modules.rb`. |
| `rigor-aasm` | B (state / event method tables) | AASM section | Not yet authored. Sibling of `rigor-statesman` (authored, may itself migrate to Tier B). |
| `rigor-sequel` | B (associations + `plugin :name` registry) | Sequel section | Not yet authored. Column accessors deferred to a separate schema-oracle ADR. |
| `rigor-activestorage` | C (heredoc template; migration from hand-rolled walker) | ActiveStorage section | Authored. Substrate slice-2 validates Tier C reach by re-implementing the existing walker against the manifest. |
| `rigor-redmine-payloads` (working name) | D (external `instance_eval`'d Ruby files) | Redmine site E | Not yet authored. Substrate slice-5 validation target. tDiary's plugin loader is the sibling case. |
| `rigor-redmine-settings` (working name) | C (YAML-driven name set + bundled triplet template) | Redmine site C | Not yet authored. Pairs with the project-side monkey-patch pre-evaluation memory note as a follow-up. |
| `rigor-graphql` | None — does not consume the substrate | GraphQL-Ruby section | Not yet authored. Uses ADR-2 fact-contribution hooks; macro substrate does not apply (schema-graph recorder). Demand-driven. |
| `rigor-factorybot` | None — does not consume the substrate | factory_bot section | Authored. Uses ADR-2 + ADR-9 (registry + dynamic return type). No substrate migration planned; the shape doesn't fit. |
| `rigor-dry-types` | C (constant emit via bundled `core.rb` registry; tier C in `const_set` flavour) + ADR-2 dynamic-return-type for `Dry::Types[<literal>]` + carrier-algebra handling for `\|` `&` `>` `.optional` `.constrained` `.constructor` | dry-types section | Not yet authored. Shared dependency of `rigor-dry-schema` and `rigor-dry-struct` (mirrors the gem dependency graph). Packaging strategy gated on ADR-12 (dry-rb plugins) but the per-library shape is fixed here. |
| `rigor-dry-struct` | C (`attribute :name, T` → 5-row emit table: reader / schema key / `to_h` row / `[:key]` access / `.new(name:)` kwarg) + Tier A for nested `attribute :x do … end` blocks | dry-struct section | Not yet authored. **Consumes** `rigor-dry-types` for the per-attribute `T` carrier. Cleanest Tier C consumer in the survey; textbook example. |
| `rigor-dry-schema` | A (block runs `instance_eval` on `Dry::Schema::DSL`; declare bareword surface — `required` / `optional` / `value` / `filled` / `maybe` / `each` / `array`) + AST recorder building `key → type` map + ADR-2 dynamic-return-type rule on `Processor#call(input) -> Result[T]` | dry-schema section | Not yet authored. **Consumes** `rigor-dry-types` for per-key type resolution. The schema-class itself is not method-extended; the value is in typing the processor's return shape. |
| `rigor-activerecord` (existing) | B (associations / enums / scopes) — partial migration candidate | — | Authored. Migration to Tier B is a follow-up validation; current hand-rolled walker continues to work. |
| `rigor-statesman` (existing) | B — partial migration candidate | — | Authored. Same as above. |

Two facts the table makes explicit:

- **The "no substrate" rows (`rigor-graphql`, `rigor-factorybot`)
  matter.** They confirm the substrate is opt-in and that plugins
  targeting libraries the substrate doesn't fit continue to work via
  the existing extension API. No plugin is forced through the substrate.
- **Existing authored plugins are migration candidates, not migration
  obligations.** A migration lands only when it demonstrably reduces
  the plugin's code surface; otherwise the hand-rolled walker stays.
  Slice 6 of § Implementation slicing exists precisely to judge that
  per plugin.

## Substrate contract

Each tier shares an invariant set:

- **Pure function of source AST + plugin-declared registries.** No Ruby
  execution, no IO, no `require` of the analyzed project.
- **Source-visibility precondition.** Tier C and Tier B require the
  parameter arguments to be literal Symbol / String / Array-of-Symbol.
  Non-literal calls produce a `plugin.<id>.non-literal-argument`
  `:info` provenance marker and fall through.
- **Substrate-produced synthetic carriers carry provenance.** Every
  `Type::Method` / `Type::*` carrier emitted by Tiers A–D carries a
  `Macro::Provenance` record naming the plugin id, the tier, the call
  site, and the parameter values. Surfaced in `--explain` mode.
- **Cacheability.** Substrate outputs participate in the existing
  `Cache::Store` keyed on the plugin manifest digest plus the call-site
  AST descriptor. Per ADR-6 the cache is sharded directory of binary
  entries; substrate outputs sit alongside ordinary plugin cache slots.
- **Ractor-safety.** Outputs are `Ractor.shareable?` at construction;
  per-Ractor materialisation follows the ADR-15 Phase 3a blueprint /
  registry split.
- **No conflict between tiers.** A single call site participates in at
  most one tier per plugin. Two plugins MAY register against the same
  call shape; first-wins by registration order matches ADR-13's
  TypeNode-resolver convention. A `plugin.<id>.macro-shadow` `:info`
  diagnostic surfaces conflicts.

## Boundary with existing ADRs

**ADR-2** (extension API). The substrate is *under* the existing
`Plugin::Base#flow_contribution_for` / `dynamic_return_type` /
`type_specifying` hooks. The new manifest entries (`block_as_method`,
`trait_registries`, `heredoc_macros`, `external_file_inclusions`) are
declarative shortcuts that synthesise the equivalent hand-rolled
walker. A plugin MAY mix declarative manifest entries with hand-rolled
`flow_contribution_for` callbacks; the substrate is opt-in per entry.

**ADR-9** (cross-plugin API). Substrate-produced facts are publishable
through the existing `Plugin::FactStore`. Tier B's bundled registries
are exactly the consumer side of an ADR-9 fact-store contract — e.g.
`rigor-devise` MAY publish `:devise_mappings` and consume `:helper_table`
from `rigor-rails-routes` to know which mapping names exist project-wide.

**ADR-13** (TypeNode resolver). Disjoint. ADR-13 is parse-time
type-name resolution in `%a{rigor:v1:…}` payloads. ADR-16 is AST-level
expansion of class-level DSL calls. The two compose: a substrate-emitted
synthetic method MAY have its return type spelled in `%a{rigor:v1:return: …}`,
which then goes through the ADR-13 resolver chain.

**ADR-15** (Ractor concurrency). The substrate's per-tier registry is
a frozen, `Ractor.shareable?` carrier registered on the
`Plugin::Blueprint` (per ADR-15 Phase 3a). Per-Ractor materialisation
proceeds as for any other plugin component.

**ADR-6** (cache persistence backend). Substrate outputs are cached
per call site with a descriptor keyed on `(plugin_manifest_digest,
tier_id, call_site_ast_digest)`. No new backend; reuses sharded
directory storage.

**ADR-0 / ADR-1** (RBS canonical, no inline DSL). The substrate
introduces no new user-visible DSL in application code. Plugin
authors write Ruby in their plugin gem; users opt in via
`.rigor.yml`'s `plugins:` list.

## Public-API drift surface

This ADR adds (when implementation lands):

- `Rigor::Plugin::Macro::BlockAsMethod` (new frozen value class).
- `Rigor::Plugin::Macro::TraitRegistry` (new frozen value class).
- `Rigor::Plugin::Macro::HeredocTemplate` (new frozen value class).
- `Rigor::Plugin::Macro::ExternalFile` (new frozen value class).
- `Rigor::Plugin::Macro::Provenance` (new frozen value class).
- `Rigor::Plugin::Manifest#block_as_method`,
  `#trait_registries`, `#heredoc_macros`, `#external_file_inclusions`
  (four new attr_readers; defaults `[]`).
- `Rigor::Type::Method#synthetic?` (new attr; default `false`).
- New diagnostic identifiers:
  - `plugin.<id>.non-literal-argument` (`:info`; substrate could not
    expand because parameter was not literal).
  - `plugin.<id>.macro-shadow` (`:info`; two plugins claim the same
    call shape; first-wins applied).
  - `plugin.<id>.unresolved-module` (`:warning`; Tier B registry
    references a module constant that doesn't resolve in the
    analyzed environment).
  - `plugin.<id>.external-file-missing` (`:warning`; Tier D glob
    matched zero files at scan time).

All updates land in `spec/rigor/public_api_drift_spec.rb` in the same
commit as the implementation.

## Implementation slicing

Recommended order; each slice independently shippable.

1. **Tier A — block-as-method.** Plugin manifest entry +
   substrate annotates block scopes. Worked plugin:
   `examples/rigor-sinatra/`. Smallest tier; validates the
   manifest / blueprint integration.
2. **Tier C — heredoc-template expansion.** Tier C is the
   highest-value tier per the survey count. Worked migration:
   reimplement `examples/rigor-activestorage/` against the
   declarative manifest. Drift snapshot updated.
3. **Tier B — trait-inlining registry.** Worked plugin:
   `examples/rigor-devise/` model side. Bundled registry
   mirrors `lib/devise/modules.rb`. Routes side queued behind
   ADR-9 publish/consume.
4. **Concern re-targeting walker.** Extends the existing
   `ActiveSupport::Concern`-aware walker so Tier A/B/C plugins
   fire correctly when the DSL call is nested inside
   `included do`.
5. **Tier D — external-file inclusion.** Worked plugin: a
   reduced Redmine webhook-payload example, or the tDiary
   plugin-loader case if the user prefers. Establishes the
   "stub file" boundary with the cache.
6. **Migrate existing plugins.** `rigor-activerecord` (Tier B for
   associations / enums), `rigor-statesman` (Tier B for state /
   event), `rigor-actionpack` (Tier C for `before_action` /
   strong-params), `rigor-factorybot` (no migration — already
   ADR-2 shape). Each migration validates the substrate is
   actually a win.
7. **Documentation.** Handbook chapter on macro / DSL plugins;
   `examples/README.md` table grows substrate-using rows;
   `.codex/skills/rigor-plugin-author/SKILL.md` updates with
   the substrate decision flow.

## Working decisions

### WD1 — Why four tiers, not a unified macro evaluator?

A single Lisp-style macro evaluator that interprets
`class_eval` / `define_method` / `instance_eval` against arbitrary
strings would have to (a) parse the heredoc body, (b) substitute
interpolated values, (c) re-parse the result, (d) bind it into the
target class. Three of those steps are deterministic only when the
inputs are source-visible literals — which is exactly what each tier
enforces declaratively. The four tiers are the *patterns the survey
actually found*; a more general evaluator would carry the cost of
handling pattern (d) (runtime-data string-eval) that the survey shows
does not occur in real code.

### WD2 — Why expansion produces synthetic AST / type carriers, not narrowing facts directly?

A narrowing fact attached to a call site explains "this expression has
type X." A synthetic method carrier explains "this class has a method
M of type X" — which is the question rigor needs to answer when M is
called *elsewhere*, on a different line, possibly in a different file.
Tier C must emit synthetic methods so downstream call-site analysis
fires correctly. Tier A's annotation is a fact attached to the *block*
(the block is method-shaped), which is enough because Sinatra's block
isn't called from elsewhere. The two contracts coexist.

### WD3 — Why plugin-declared, not generic AST macro evaluation?

A generic evaluator would have to understand `class_eval(SRC, __FILE__, __LINE__)`
in arbitrary Ruby. Three problems: (1) the interpolation context (what
`#{name}` resolves to) depends on the enclosing lexical scope, which is
unbounded; (2) the receiver of `class_eval` may be computed (the survey
shows this is rare but real); (3) the heredoc body may itself contain
metaprogramming. Plugin-declared templates sidestep all three: the
plugin author commits to the call shape, the parameter positions, and
the output, while the substrate handles the AST plumbing. The trade-off
is that each new DSL needs a plugin; the survey suggests this is
acceptable because the universe of "DSLs worth typing" is small and
well-known.

### WD4 — Where in the pipeline does expansion run?

After parsing, before inference. The substrate runs as a *project-load*
phase that scans every file once, identifies substrate-eligible call
sites by manifest shape, and emits synthetic carriers / scope
annotations / file inclusions before the inference engine starts on
file-level analysis. This mirrors the existing
`Environment::Reflection` build phase and lets the inference engine
treat substrate outputs identically to RBS-sourced carriers.

The pre-pass is keyed in cache by manifest digest + AST descriptor, so
substrate work is amortised across incremental runs.

### WD5 — How does expansion interact with the cache?

Each substrate output is a frozen value object keyed by
`(plugin_manifest_digest, tier_id, call_site_ast_digest)`. Cache
invalidation follows the existing rules: changing a plugin's manifest
invalidates all of its substrate slots; changing a call-site argument
literal invalidates only that slot. LRU eviction (deferred per ADR-6)
applies uniformly.

A second cache key — `concern_retarget_chain` — records the includer
chain for Concern re-targeted contributions. This is necessary because
the same `included do { has_one_attached :avatar }` inside `module M`
produces different synthetic carriers depending on which class
includes `M`.

### WD6 — How does expansion interact with ADR-15 Ractor isolation?

Substrate registries are part of the `Plugin::Blueprint` and are
`Ractor.shareable?` at construction. Each Ractor materialises its own
`Plugin::Registry` from the shared blueprint per ADR-15 Phase 3a;
substrate outputs (synthetic carriers) follow the same per-worker
materialisation. The pre-pass runs once on the main Ractor before
workers spawn, building a frozen substrate-output map; workers consume
the map via `RbsLoader#prewarm`-style sharing.

### WD7 — Why not handle Concern re-targeting as Tier E?

`included do` is *deferred class_eval*, not a new emission shape.
The body inside the block is already Ruby that some other walker
(Tier A or Tier C plugin walker) knows how to handle. The only
new behaviour needed is "rebind the block's `self` to the includer
when expanding child calls." That fits inside the existing
AS::Concern walker; adding a Tier E entry would duplicate the
walker's responsibilities.

### WD8 — Why does Tier D allow ivar typing but not local-variable typing?

Plugin-declared `bound_ivars` model the runtime convention that the
caller of `instance_eval(File.read(...))` sets `@`-ivars before
loading. Local variables, by contrast, are scoped to the file and
declared lexically by the file itself — they don't need plugin
declaration. Allowing plugins to *override* local-variable types
would breach lexical scoping, which is a stronger contract than the
substrate should touch.

### WD9 — Why are the diagnostic markers `:info` for non-literal arguments, not `:warning`?

A non-literal argument (`has_one_attached(some_method)`) is uncommon
but legitimate Ruby. The substrate's correct response is "I can't
expand this; fall back." That's not a defect to warn about — it's a
boundary. Plugin authors who want stricter behaviour can publish a
custom rule that escalates the provenance marker.

### WD10 — Why "per-library dedicated plugin" remains the default, not "one substrate-driven universal plugin"?

Each library's call shapes, registry contents, and edge cases (e.g.
Devise's `Devise.add_module` runtime registry, AASM's `namespace:`
option, Sequel's `:methods_module` override) belong to that library's
maintenance surface. Bundling several libraries into one giant plugin
gem couples release cycles, complicates `git subtree split`-ability
(see [Rails plugins roadmap][rails-roadmap]), and confuses Gemfile
selection (a project on Sequel + Sinatra would pull in Devise
infrastructure too). The substrate's job is to make each
per-library plugin cheap to author; it is not a vehicle for collapsing
plugin count. The two "no substrate" rows in § Planned per-library
plugins (`rigor-graphql`, `rigor-factorybot`) confirm the symmetric
boundary on the other side: a library that doesn't fit the substrate
still gets its own dedicated plugin via the regular ADR-2 contract.

[rails-roadmap]: ../design/20260508-rails-plugins-roadmap.md

### WD11 — Why are dedicated plugin and substrate-heuristic mutually exclusive at use-site?

The secondary purpose (heuristic recognition without a dedicated
plugin) and the dedicated plugin path are alternative *routes to the
same answer*: both compute synthetic carriers from a literal-symbol
DSL call. Letting both fire on the same call site would (a) waste
analyzer time computing the same answer twice, (b) require a
fact-merging policy when the two routes disagree (the dedicated
plugin is always more correct — there's no value in second-source
adjudication), (c) double-count in the cache.

Exclusion is therefore a single rule: when a `rigor-foo` plugin
declares ownership of a call shape (via the plugin's manifest), the
heuristic detector skips that shape for files in `foo`'s gem
dependency tree. The mechanism is a "claimed call shapes" set
populated from enabled plugins' manifests at startup; the heuristic
detector consults the set before running.

The exclusion is unidirectional: the heuristic never overrides or
augments a dedicated-plugin output. If the plugin produces nothing
for a given call (e.g. because the argument is non-literal), the
heuristic does NOT take over either — both fall through to
`Dynamic[T]` with appropriate provenance.

### WD12 — Why is the secondary purpose best-effort, not a hard requirement?

Two reasons: scope and cost.

**Scope.** The patterns the secondary heuristic could detect overlap
imperfectly with the patterns the substrate exposes for declared
plugins. Tier C (heredoc + literal symbol interpolation) is the
easiest to detect heuristically because the surface pattern is
syntactically distinctive. Tier B (trait-inlining via bundled
registry) is much harder — the heuristic would need to recognise
"this method enumerates symbols and `include`s modules" without a
registry telling it which module. Tier A (block-as-method) is
trivial syntactically but useless without a declared `self`-type.
Tier D (external-file inclusion) is undetectable without configured
paths. So "minimum-effort recognition without a plugin" is realistic
only for a subset of substrate patterns.

**Cost.** Detection cost is paid on every call site that *could* be a
substrate pattern but isn't — a per-call probe against the
heuristic. Today rigor's inference loop is ~50% of wall-clock per
ADR-15 § Context; adding an unconditional substrate-pattern probe at
each call site grows that share. Per the performance bound in
§ Audience and purpose, the secondary path's net wall-clock impact
must be zero or negligible. That constrains the heuristic to either
(a) running once during the project-load pre-pass and producing a
small candidate set, or (b) deferring to a syntactic gate that costs
no more than an existing call-shape match (e.g. "the call's receiver
class is `Module` and its method is `class_eval` AND the first arg is
a heredoc node" — a 3-predicate gate already on the AST path).

Both routes are implementable but neither is *necessary*. The
substrate's primary purpose (declared-plugin authoring convenience)
stands on its own. The secondary purpose ships if and when the
heuristic clears the performance bound; otherwise the substrate is
declared-plugin-only.

## Alternatives considered

| Candidate | Status | Reason |
| --- | --- | --- |
| Single generic Lisp-macro evaluator interpreting `class_eval` / `define_method` / `instance_eval` | Rejected (WD1) | Requires evaluating arbitrary Ruby; security + determinism risk; survey shows pattern (d) does not occur. |
| Keep per-plugin walkers only, no shared substrate | Rejected | Per-library dedicated plugins remain the default *shape* (see WD10), but the walkers inside them duplicate name-interpolation and registry plumbing — survey shows ~80% of macro-DSL sites share Tier B/C shape. The substrate is the convenience layer underneath the plugins, not a replacement for them. |
| One substrate-driven universal plugin covering every metaprogramming library | Rejected (WD10) | Couples release cycles, breaks subtree-splitability, confuses Gemfile selection. Per-library plugins stay the default; the substrate is the shared authoring layer. |
| Run both dedicated plugin AND substrate heuristic at the same call site, merging facts | Rejected (WD11) | Wastes analyzer time computing the same answer twice; requires a fact-merging policy when the two routes disagree (the dedicated plugin is always more correct); double-counts in the cache. Exclusion at use-site is the simpler rule. |
| Make the secondary heuristic a hard requirement matched against every substrate pattern | Rejected (WD12) | Detection cost is paid on every call site that *could* be a substrate pattern. Tier B / D heuristics are also not implementable without registry / path configuration the substrate's primary purpose already requires. Substrate's primary purpose (declared-plugin authoring) stands alone; heuristic ships best-effort when achievable. |
| Defer entirely until concrete user demand | Rejected | Survey demonstrates concrete demand: Redmine 35 FP / file on legacy plugins, Devise model side has no plugin, AASM is reachable but not implemented. |
| Single Tier C only (heredoc templates), skip A/B/D | Rejected | Tier A (Sinatra-shape) is the simplest validation case for the manifest plumbing; Tier B (Devise-shape) is the highest-ergonomic-payoff for ecosystem plugins; Tier D unblocks the original O2 motivating cases. Shipping only Tier C leaves the substrate's reach narrower than the survey justifies. |
| Treat Concern re-targeting as Tier E | Rejected (WD7) | Re-targeting is not a new emission shape; it composes over the other tiers. |
| Plugin priority registry for cross-plugin macro-shadow conflicts | Rejected | First-wins by registration order matches ADR-13's TypeNode-resolver convention and ADR-2's `diagnostics_for_file` convention. Priority registries couple plugin gems. |
| Substrate emits narrowing facts only, no synthetic methods | Rejected (WD2) | Tier C must emit synthetic methods so distant call sites can resolve them. Facts attached at the macro call site don't help when `user.avatar` is called five files away. |
| Author the substrate against Prism AST node types directly, no `Macro::*` value objects | Rejected | The value objects let plugins declare expansion intent at the manifest layer; replacing them with raw Prism queries pushes AST plumbing back into every plugin (which is what the substrate exists to avoid). |
| Land the substrate but mandate migration of every existing plugin | Rejected | Existing walkers ship working code. Migration is a per-plugin choice; the substrate's value is judged by its uptake, not by forcing churn. |

## Open questions

- **Should Tier C templates support method bodies, not just signatures?**
  ActiveStorage's `with_attached_avatar` scope has a real body that
  `joins(:avatar_attachment).joins(:avatar_blob)`. Today rigor types
  the scope's return type without modelling its body. Question: does
  the substrate gain enough by representing body shape? Defer to slice
  2 (Tier C MVP) — start with signature-only emission, revisit if a
  concrete consumer needs body typing.

- **Should Tier B registries support per-symbol *option-driven*
  emission?** Devise's `available_configs` setter (`lib/devise/models.rb:97-103`)
  reads option hashes and calls per-module setters. Question: does the
  substrate's `TraitRegistry` need a "per-option-hash side effect"
  primitive, or do plugins handle that via `flow_contribution_for`
  on the side? Defer to slice 3 (Tier B MVP) — start without; see
  whether the Devise plugin needs it.

- **Tier D scope rules under `instance_eval`-on-a-block vs
  `instance_eval`-on-a-file.** The two have subtly different
  receiver-binding semantics in Ruby (the file form sets
  `__FILE__` / `__LINE__` differently from the block form). Question:
  does the substrate care? Defer to slice 5 (Tier D MVP) — the survey
  case (Redmine webhook payloads) uses the file form exclusively.

- **Should Concern re-targeting be opt-in per-plugin, or default-on
  for any plugin registering Tier A/B/C entries?** Default-on is the
  ergonomic choice (the plugin author doesn't have to think about
  the wrapped-in-Concern case) but creates a feedback effect on
  caching (every substrate output gains a Concern-chain key
  dimension). Defer to slice 4.

- **Interaction with the dependency-source inference tier
  ([ADR-10](10-dependency-source-inference.md)).** If a gem ships
  with no RBS and rigor's source-walker contributes `Dynamic[T]`
  returns from its `def`s, does the substrate see those `def`s as
  candidates for expansion? Answer is probably no — ADR-10 sits at
  a different tier and walks gem source for *signatures*, not
  *macro call sites*. Confirm in slice 1.

- **Interaction with [ADR-11](11-sorbet-input-adapter.md) Sorbet
  input.** A Sorbet `sig` block on a method emitted by a Tier C
  template should not conflict with the substrate's synthetic
  return-type. Question: does the substrate take precedence, or does
  Sorbet input override? Decision: Sorbet input overrides (it's
  user-authored); substrate becomes the fallback. Document in
  slice 2.

- **Concrete shape of the secondary heuristic (WD12).** Two
  candidate forms: (a) a project-load pre-pass over every `class_eval` /
  `module_eval` / `define_method` call site, producing a candidate
  set with `macro.heuristic.candidate` provenance; (b) an AST-path
  gate during inference that triggers only on the cheapest syntactic
  pattern (heredoc-arg `class_eval` with literal-symbol interpolation).
  Decision deferred. Both can ship independently of the primary
  substrate; neither is committed. Slice ordering puts the heuristic
  *after* slice 6 (existing-plugin migration), so substrate uptake
  through declared plugins is observed before the heuristic's
  scope is finalised.

- **Exclusion-set granularity (WD11).** Today's claimed-shape rule
  reads "if `rigor-foo` is enabled, skip heuristic on files inside
  foo's gem tree." Open question: what is the unit of exclusion when
  a library is application-bundled (not gem-bundled), e.g. an
  internal monkey-patch under `lib/myapp/extensions/`? Candidates:
  per-call-shape-key, per-load-path, per-`require`-path. Decision
  deferred to slice 7 (heuristic ships); the substrate's primary
  purpose does not need this rule defined.

## Revision history

- 2026-05-15 — initial proposal. Triggered by user request to advance
  the per-library survey
  ([`docs/notes/20260515-macro-expansion-library-survey.md`](../notes/20260515-macro-expansion-library-survey.md))
  into a formal ADR. Resolution: four-tier expansion substrate
  (block-as-method / trait-inlining-registry / heredoc-template /
  external-file) plus Concern re-targeting walker extension; opt-in
  per plugin via manifest entries; substrate outputs participate in
  the existing cache, Ractor, and plugin contracts.
- 2026-05-15 — clarified audience and purpose. The substrate is a
  developer-experience layer for plugin authors targeting
  metaprogramming-shaped libraries (or application-specific macro
  DSLs); per-library dedicated plugins remain the default shape. Added
  § Audience and purpose, § Decision § Planned per-library plugins
  (coverage map across the eight surveyed libraries), WD10, and the
  "universal plugin" alternative-considered row. Surveyed libraries
  whose DSLs do not fit substrate expansion (GraphQL-Ruby, Sequel
  column accessors) still get future dedicated plugins via the
  regular ADR-2 contract.
- 2026-05-15 — extended the survey to cover the dry-rb trio
  (dry-types / dry-schema / dry-struct). Added three rows to
  § Planned per-library plugins (`rigor-dry-types`, `rigor-dry-struct`,
  `rigor-dry-schema`); `rigor-dry-types` is a shared dependency for
  the other two, mirroring the gem dependency graph one-to-one. The
  survey note's cross-library summary and observations section gained
  corresponding rows. Packaging strategy still gated on ADR-12;
  per-library substrate shape is fixed here.
- 2026-05-15 — refined the audience framing to distinguish three
  stakeholder roles (library developer / library user / rigor as
  fallback). Added the substrate's **secondary purpose** —
  best-effort heuristic recognition of macro patterns when no
  dedicated `rigor-<lib>` plugin is enabled — bounded by a hard
  **mutual-exclusion rule** at use-site (WD11) and a hard
  **performance bound** (WD12). Secondary purpose is an
  aspiration, not an obligation; substrate's primary purpose
  (declared-plugin authoring convenience) ships independently.
  Updated WD10, added WD11 / WD12, extended Alternatives considered
  with two rejected variants, added two open questions about the
  heuristic's concrete shape and exclusion-set granularity.
