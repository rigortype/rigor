# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older release notes are archived under [`docs/`](docs/) when the leading
version digit moves up. The active file holds the current `[Unreleased]`
section plus the most recent leading-digit cycle (currently `0.1.x`); past
cycles live in dedicated archives:

- [`docs/CHANGELOG-0.0.x.md`](docs/CHANGELOG-0.0.x.md) — `0.0.1` through `0.0.9`.

### Archival rule

At the **first release after a leading-digit bump** — e.g. `0.1.1` is the
first release after the `0.0.x` → `0.1.x` bump landed at `0.1.0` — the
entire previous-digit range moves out of this file into a new
`docs/CHANGELOG-<old-prefix>.md` archive. The trigger is the first `a.b.c`
release where `(a, b)` matches the most recent release's `(a, b)` but
differs from the previous archive's prefix. The release-prep SKILL
([`.codex/skills/rigor-release-prep/SKILL.md`](.codex/skills/rigor-release-prep/SKILL.md))
codifies the move as a checklist step so the archive doesn't drift.

## [Unreleased]

### Added

#### Steep cross-check baseline closes the only `[error]` ahead of v0.1.1

- **`sig/rigor.rbs:67`** referenced `Rigor::Cache::Store` but no `sig/rigor/cache/store.rbs` exists (the Cache namespace is in `UNSIGNED_NAMESPACES` per `spec/rigor/public_api_drift_spec.rb`). `make steep-check` raised the only `[error]`-level diagnostic — `RBS::UnknownTypeName: Rigor::Cache::Store`. Replaced with `untyped` until the full Cache::Store sig lands.
- **`Rigor::Analysis::Runner`'s sig** also gained `attr_reader plugin_registry: untyped` and `?plugin_requirer: untyped` to match the v0.1.1 Track 2 slice 7 surface (the `plugin_registry` / `plugin_requirer` Runner additions added without sig updates would have shown up as drift on the next sig audit).
- **Remaining 8 `[warning]`s** are all Steep's coarse handling of Ruby idioms (`Data.define do def initialize ... end end` override blocks, `Kernel#Array` narrowing on `Target | Array[Target]`, lambda defaults inside `def`). They sit in `D::Ruby.lenient` warning territory and will dissolve naturally as `Plugin::*` / `Cache::Store` sigs land. Triage at [`docs/notes/20260503-steep-cross-check-triage.md`](docs/notes/20260503-steep-cross-check-triage.md) updated with a v0.1.1 follow-up section.
- `make steep-check` is intentionally NOT part of `make verify` — it's an advisory cross-checker, not a release blocker.

#### `.rigor.yml` `exclude:` setting + built-in defaults

- **New `Configuration#exclude_patterns`** — a list of `File.fnmatch?` glob patterns layered over the project's directory globs. The runner's `expand_paths` consults the list when expanding a directory argument and skips any file whose path matches an exclusion pattern. Explicit file arguments to the CLI bypass the filter — only directory expansion is filtered.
- **Built-in defaults** that users can't disable (and rarely want to): `**/vendor/bundle/**`, `**/.bundle/**`, `**/node_modules/**`. These cover the cases where Rigor would otherwise walk into vendored gems / build artefacts and emit floods of diagnostics for code the user doesn't own.
  - Earlier self-analysis surfaced 1677 errors over 132 files when running `rigor check tool` against this repo, almost all of them inside `tool/steep/vendor/bundle/`. After this slice, `rigor check tool` reports `No diagnostics`.
- **User additions** layer on top via `.rigor.yml`:
  ```yaml
  exclude:
    - "spec/integration/fixtures/**"
    - "examples/*/demo/**"
  ```
  The `to_h` / round-trip surface returns only the user-supplied entries — built-in defaults are implicit and not echoed back.
- **`tool/extract_builtin_catalog.rb:750`** — point fix via `# rigor:disable call.undefined-method` for the `lines[j..k].join` site. Self-analysis revealed Rigor's overload selector currently picks `Array#[](int) -> Elem` over `Array#[](Range) -> Array[Elem]?` because the RBS `int` alias expands to `Integer | _ToInt` and Rigor translates the `_ToInt` interface to `Dynamic[top]`, which gradually accepts any argument including a Range. Tracked as a deferred v0.1.x item under "interface-strictness on overload selection" in `MILESTONES.md`.

#### `Const = Struct.new(*Symbol)` discovery — symmetric with `Data.define`

- **`Inference::ScopeIndexer.record_meta_new_constant?`** (renamed from `record_data_define_constant?`) now recognises `Const = Struct.new(:a, :b)` and the `keyword_init:` variant `Const = Struct.new(:a, :b, keyword_init: true)` alongside the existing `Const = Data.define(:a, :b)` recogniser. The discovered constant gets registered as `Singleton[<qualified-Const>]`, so `Const.new(...)` resolves to a fresh `Nominal[<qualified-Const>]` via `meta_new` instead of the un-narrowed `Dynamic[top]` returned by the default `Class#new` envelope.
- **Cleared 30 false positives across the seven worked plugin examples.** Before this slice, `examples/rigor-deprecations/lib`, `examples/rigor-routes/lib`, `examples/rigor-units/lib`, `examples/rigor-lisp-eval/lib`, `examples/rigor-activerecord/lib` all fired `error: undefined method 'new' for Struct` at every site that used the canonical `Foo = Struct.new(:a, :b)` pattern. `bundle exec exe/rigor check examples/rigor-*/lib` now reports `No diagnostics` for each.
- **Trailing `KeywordHashNode`** (the `keyword_init: <expr>` form Ruby 3+ requires for keyword-arg struct types) is recognised and ignored at member-discovery time. Members must still all be `Prism::SymbolNode`; non-symbol positional args (e.g. `Struct.new(:x, "not_a_symbol")`) decline. `Struct.new()` with no positional args is a degenerate form Ruby allows but Rigor declines, since it has no members to discover.
- Spec coverage: 5 new examples in `spec/rigor/inference/scope_indexer_spec.rb` (basic discovery, `keyword_init:` variant, qualified-class-path discovery, non-symbol arg rejection, empty-arg rejection).

#### v0.1.1 Track 1 — narrowing depth

##### Slice 1 — regex pattern → refinement-name recogniser

- **New `Rigor::Builtins::RegexRefinement` module** at [`lib/rigor/builtins/regex_refinement.rb`](lib/rigor/builtins/regex_refinement.rb). Pure recogniser that maps a curated table of canonical regex sub-patterns (`\d+`, `\d{N}`, `\d{N,M}`, `\h+`, `[0-9a-fA-F]+`, `[0-9a-f]+`, `[0-9A-F]+`, `\h{N}`, `[0-7]+` and bounded forms, `[a-z]+`, `[A-Z]+`, `[[:digit:]]+`, all with `+` or `{n}` / `{n,m}` quantifiers where `n >= 1`) onto the imported refinement carriers Rigor already ships (`decimal-int-string`, `hex-int-string`, `octal-int-string`, `lowercase-string`, `uppercase-string`, `numeric-string`). Bodies that admit the empty string (`*`, `?`, `{0,N}`) or sit outside the audited table return `nil` so callers fall back to the v0.1.0 baseline (plain `String`). Spec at [`spec/rigor/builtins/regex_refinement_spec.rb`](spec/rigor/builtins/regex_refinement_spec.rb).
- **`Inference::Narrowing.analyse_match_write` consults the recogniser.** When the `MatchWriteNode`'s wrapped `=~` call has a statically known `RegularExpressionNode` receiver, every `(?<name>body)` whose body matches a recogniser row narrows the truthy edge of `if regex =~ str` to the matching refinement instead of plain `String`. Bodies with nested groups, alternation, anchors, or anything else outside the table fall back unchanged. The falsey edge is still `nil` per the v0.1.0 contract.
- A pattern like `if /(?<year>\d{4})-(?<month>\d{1,2})/ =~ str; year; month; end` now binds `year` and `month` to `decimal-int-string` in the truthy branch.

##### Slice 2 — digit-only refinements propagate through `to_i` / `Integer(s)`

- **2a — `String#to_i` / `#to_int`.** `MethodDispatcher::ShapeDispatch.dispatch_refined` gains four rows in `REFINED_STRING_PROJECTIONS` covering `to_i` / `to_int` on `decimal-int-string` and `numeric-string` receivers, returning `non-negative-int`. End-to-end: `if /(?<year>\d+)/ =~ str; year.to_i; end` resolves to `non-negative-int` instead of `Integer`. No-arg form only.
- **2b — `Kernel#Integer`.** `MethodDispatcher::KernelDispatch.try_integer_from_refinement` mirrors the rule for the single-arg `Kernel#Integer(s)` form.

##### Slice 3 — full `self`-narrowing in `predicate-if-*` / `assert-if-*` / `assert`

- **Three additional receiver shapes now narrow `self`-targeted facts** (in addition to the v0.1.0 LocalVariableReadNode case):
  - `Prism::InstanceVariableReadNode` — `@buddy.logged_in?` narrows `@buddy` itself on each edge via `Scope#with_ivar`.
  - `Prism::SelfNode` — `self.logged_in?` narrows `scope.self_type` via `Scope#with_self_type`.
  - Implicit self (nil receiver) — `logged_in?` with no receiver inside an instance method body narrows `scope.self_type`. `Inference::Narrowing#analyse_call` no longer rejects nil-receiver call shapes outright; the RBS::Extended path is allowed to run when the receiver is implicit.
- **`Inference::Narrowing#apply_self_fact`** is the new dispatch helper covering all four receiver shapes. Mirrored as `StatementEvaluator#apply_self_post_return_fact` for the `assert self is T` post-return path. `resolve_rbs_extended_method` consults `scope.self_type` when the receiver is nil so the implicit-self call's method definition is reachable.
- Inference engine spec at [`docs/internal-spec/inference-engine.md`](docs/internal-spec/inference-engine.md) updated. Integration fixture `spec/integration/fixtures/self_predicate/` extended with `User#greet_buddy` (ivar receiver) and `User#greet` (implicit self) cases.

##### Slice 4 — `String#start_with?` / `#end_with?` / `#include?` flow facts

- **`Inference::Narrowing#analyse_string_predicate`** recognises `s.start_with?("foo")`, `s.end_with?(...)`, and `s.include?(...)` against a `Constant<String>` needle and a `Prism::LocalVariableReadNode` receiver. The truthy edge attaches an `Analysis::FactStore::Fact` (`bucket: :relational`, `predicate:` the method name, `payload:` the needle string, `polarity: :positive`); the falsey edge attaches the `:negative` mirror.
- **No type narrowing.** Rigor has no "starts-with-X" carrier today, so the receiver's type stays unchanged on both edges. The slice intentionally lands the lightweight FactStore-based form first; a heavier carrier-based form may follow if downstream consumers need it. Receiver type gating is left to consumers (`String#start_with?` is String-only, but `Array#include?` exists with different semantics — facts are advisory).

##### Slice 5 — `literal-string` / `digit-int-string` propagation through additional methods

- **5a — `#strip` / `#lstrip` / `#rstrip` / `#chomp` (no-arg) / `#chop` / `#scrub` (no-arg).** `MethodDispatcher::LiteralStringFolding`'s `LITERAL_PRESERVING_METHODS` rule. Each strips a known character subset from the ends of the string (or replaces invalid bytes for `#scrub` — a no-op on always-valid literal source code), so a literal-bearing receiver stays literal-bearing. Result is plain `literal-string` (`non-empty-literal-string` collapses because `"   ".strip == ""`).
- **5b — `Integer#to_s` precision on non-negative `IntegerRange`.** `MethodDispatcher::ShapeDispatch` gains an `IntegerRange` receiver handler. When the range's lower bound is `>= 0`, `to_s(base)` returns a digit-string with no leading sign and lifts to the matching imported refinement: base 10 → `decimal-int-string`, base 8 → `octal-int-string`, base 16 → `hex-int-string`. Other bases (2, 36, …) and signed ranges keep the v0.1.0 baseline.
- **5c — `String#center` / `#ljust` / `#rjust`.** `LiteralStringFolding.fold_width_pad` lifts these on a literal-bearing receiver to `literal-string` when the width arg is Integer-typed and the (optional) padding arg is literal-bearing.
- **`Numeric#to_s` (no args)** intentionally not implemented: `Float#to_s` produces `.`-bearing strings, signed `Integer#to_s` produces `-`-prefixed strings, and no current Rigor refinement captures either. The non-negative-Integer case is covered by 5b.

#### v0.1.1 Track 2 — cross-plugin API + return-type contributions (ADR-9)

##### Slice 1 — `Rigor::Plugin::FactStore` value object

- **New `Rigor::Plugin::FactStore`** at [`lib/rigor/plugin/fact_store.rb`](lib/rigor/plugin/fact_store.rb). Per-run cross-plugin fact storage per [ADR-9](docs/adr/9-cross-plugin-api.md). A producer plugin (e.g. `rigor-activerecord`) publishes a typed `(plugin_id, name) -> value` triple in its `#prepare` hook (slice 3); a consumer plugin reads it via `services.fact_store.read(plugin_id:, name:)`. Constructed fresh at the start of every `Analysis::Runner.run` and discarded at the end — caching the underlying expensive computation is the producer's job (`Plugin::Base.producer`); the FactStore just publishes the *reference* to that already-cached result.
- **API surface** (frozen by `spec/rigor/public_api_drift_spec.rb`): `#publish(plugin_id:, name:, value:)`, `#read(plugin_id:, name:)`, `#published?(plugin_id:, name:)`, `#each_fact(&)`, plus the `Fact = Data.define(:plugin_id, :name, :value)` shape and `Conflict` exception class. `plugin_id` canonicalises to String, `name` to Symbol. Thread-safe via internal Mutex.
- **Conflict semantics.** A duplicate `publish` with the same value (`==`) is a no-op; differing values raise `Conflict`. Real conflict only happens when a single plugin publishes twice with differing values — the conflict signals a plugin-author bug, never a load-time interaction between unrelated plugins.

##### Slice 2 — `Plugin::Services#fact_store` accessor

- **`Rigor::Plugin::Services`** gains a `fact_store` attribute and a matching keyword arg. When no `fact_store:` is supplied, a fresh `Plugin::FactStore` instance is constructed per Services. Drift snapshot updated.

##### Slice 3 — `Plugin::Base#prepare(services)` hook + Runner invocation

- **New `Plugin::Base#prepare(services)`** default-no-op hook. Producer plugins override to compute and publish facts other plugins consume:
  ```ruby
  def prepare(services)
    services.fact_store.publish(plugin_id: manifest.id, name: :model_index, value: model_index)
  end
  ```
- **`Analysis::Runner` calls `#prepare`** on every loaded plugin once per `run`, after `#init` and before per-file iteration. Failure isolation: a `#prepare` raise becomes a `:plugin_loader runtime-error` diagnostic, mirroring the `#diagnostics_for_file` raise envelope. The plugin's facts are considered un-published; downstream consumers see `nil` from `fact_store.read` and degrade gracefully.

##### Slice 4 — `manifest(produces:)` / `manifest(consumes:)` declarations

- **`Rigor::Plugin::Manifest`** gains two new declarative fields. `produces:` is an `Array<Symbol>` listing the names this plugin publishes; `consumes:` is an `Array<{ plugin_id:, name:, optional: }>` listing the `(plugin_id, name)` pairs this plugin reads. The new `Rigor::Plugin::Manifest::Consumption` frozen `Data.define(:plugin_id, :name, :optional)` shape coerces hash entries (string- or symbol-keyed) into Consumption instances; malformed entries raise `ArgumentError` at class-definition time.

##### Slice 5 — topological sort + missing-producer detection in `Plugin::Loader`

- **`Plugin::Loader.load` topologically sorts** loaded plugins by their `manifest(consumes:)` declarations so producer plugins run before consumers in the runner's `#prepare` pass. Tie-break preserves `Configuration#plugins` order, keeping the v0.1.0 contract intact for plugins that don't opt into the cross-plugin API. The topo sort is skipped entirely when no loaded plugin declares a `consumes:` entry — same observable behaviour as before slice 5.
- **Missing producer detection.** A non-optional `consumes:` entry that names a `(plugin_id, name)` no loaded plugin produces emits a `Plugin::LoadError` with `reason: :"missing-producer"`, dropping the offending consumer. `optional: true` consumes skip the check.
- **Cycle detection.** A consumes graph that forms a cycle emits a `Plugin::LoadError` with `reason: :"dependency-cycle"` naming the offending plugins. Non-cycle plugins still load. `Plugin::LoadError` gains an optional `reason:` field carrying the new symbol codes; older callers omit `reason:` and the field defaults to nil.

##### Slice 7 — `Plugin::Base#flow_contribution_for` return-type contribution tier

- **New `Plugin::Base#flow_contribution_for(call_node:, scope:)`** default-no-op hook. Plugins override to return a `Rigor::FlowContribution` whose `return_type` slot pins the call site's result type. Hooks that raise have their contribution silently dropped per-call so the dispatch chain keeps going.
- **`MethodDispatcher.dispatch`** gains optional `call_node:` and `scope:` keywords. When both are provided and the receiver scope's environment carries a non-empty `plugin_registry`, a new tier between the precision tiers and `RbsDispatch` walks every loaded plugin's hook, merges via `FlowContribution::Merger`, and returns the merged `return_type` if present. Internal dispatcher callers (per-element block fold, etc.) skip the tier by passing nil for `call_node` / `scope`.
- **`Environment#plugin_registry`** new optional reader (default nil; `Environment.for_project(plugin_registry:)` accepts it). `Analysis::Runner` threads its per-run `Plugin::Registry` through here so the dispatcher tier can consult the loaded plugins from any call site.
- Migrating the seven example plugins from "info diagnostic only" to "narrowed return type" stays deferred — slice 7 lands the substrate; per-plugin migration is incremental follow-up.

#### Rails ecosystem plugin roadmap and ADR-9 design

- **[`docs/design/20260508-rails-plugins-roadmap.md`](docs/design/20260508-rails-plugins-roadmap.md)** captures the full plan for the `rigor-*` Rails ecosystem plugin family, building on the existing `rigor-activerecord` example. Three tiers: Tier 1 plugins (`rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`) need only the v0.1.0 plugin contract; Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) blocks on ADR-9; Tier 3 plugins (`rigor-rspec`, `rigor-pundit`, `rigor-sidekiq`, `rigor-graphql`, `rigor-activestorage`, `rigor-actioncable`) author when there is concrete user demand. A future `rigor-rails` meta-gem aggregates Tier 1+2 dependencies.
- **[ADR-9 — Cross-plugin API](docs/adr/9-cross-plugin-api.md)** proposes the missing piece for Tier 2 plugins. Six independently shippable implementation slices documented; slices 1 → 5 + slice 7 landed in v0.1.1.
- **`docs/MILESTONES.md`** gains a "Rails ecosystem plugins" section listing the running parallel track. **CLAUDE.md** "Read these first" table and ADR table updated with ADR-9. **`.codex/skills/rigor-plugin-author/SKILL.md`** gains "Real-Rails alignment" and "Cross-plugin facts (post-ADR-9)" sections.

#### Example plugin: `rigor-activerecord`

- **Seventh worked example of the v0.1.0 plugin authoring surface** under [`examples/rigor-activerecord/`](examples/rigor-activerecord/) — and the most architecturally complete. Validates `Model.find` / `Model.find_by` / `Model.where` calls against the project's `db/schema.rb` and discovered AR model classes. Combines DSL interpretation (Prism walk over the `create_table "users" do |t| ... end` schema), multi-file `IoBoundary` reads (schema + every `app/models/*.rb`), chained cache producers (`:schema_table` + `:model_index`, both auto-invalidating on the digests of every file the boundary touched), and two-pass discover-then-validate.
- **Diagnostics.** `:info plugin.activerecord.model-call`; `:error plugin.activerecord.unknown-column` with Levenshtein-distance ≤ 3 did-you-mean suggestions; `:error plugin.activerecord.wrong-arity`; `:warning plugin.activerecord.load-error`.
- **Configurable.** `schema_file:`, `model_search_paths:`, `model_base_classes:`. **Schema parser** is a small Prism interpreter (no `eval`). **Inflector** is bundled, no `activesupport` runtime dependency.
- **Limitations** (intentional for v0.1.0 of the plugin): direct-superclass match only; `db/schema.rb` only (no `db/structure.sql`); no instance-method typing; no associations / scopes / strong parameters / controllers.
- **Demo project**, integration spec (14 examples). Eventual extraction via `git subtree split`.

#### Runtime audit guards for every `.rigor.yml` setting

- **New `Rigor::Analysis::Runner` "configuration wiring at runtime (audit guard)" spec block** verifies that each documented `.rigor.yml` setting actually flows from `Configuration` into the runtime, beyond the existing per-attribute load tests. The block was prompted by two phantom-setting bugs caught earlier in this batch (`cache.path` and `target_ruby`); the guard prevents the same regression class from re-opening silently.
  - `libraries:` reaches `Environment.for_project(libraries:)`.
  - `signature_paths:` reaches `Environment.for_project(signature_paths:)`, and a custom `.rbs` declared on a non-default path makes the class known via `Reflection`.
  - `plugins_io.allowed_paths:` extends `Plugin::TrustPolicy#allowed_read_roots`.
  - `cache.path:` is honoured by `Rigor::CLI#run_check` when constructing the `Cache::Store` (covered in `cli_spec.rb`).
  - `target_ruby:` is honoured by `Prism.parse_file(version:)` and a Prism-rejected version surfaces a single configuration-error diagnostic.

### Changed

#### Two-file config convention — `.rigor.yml` (dev-local) + `.rigor.dist.yml` (project default)

- **Auto-discovery order**: `Configuration.load(nil)` (the default when `--config=PATH` is not passed) now reads the **first** of `.rigor.yml` then `.rigor.dist.yml` it finds in the project root. Both files are **never merged automatically** — when a developer keeps a `.rigor.yml`, that file is the sole source of config for that developer's runs. The repo's own committed config moved from `.rigor.yml` to `.rigor.dist.yml`; the seven worked examples under `examples/rigor-*/demo/.rigor.yml` moved to `.rigor.dist.yml` for the same reason. `.gitignore` (top-level + each demo's `.gitignore`) now ignores `/.rigor.yml` so a developer's local override does not get accidentally committed.
- **`includes:` directive** (PHPStan-style). To extend the project default, an override file lists the dist file (and any others) under `includes:`:
  ```yaml
  # .rigor.yml
  includes:
    - .rigor.dist.yml
  disable:
    - call.undefined-method
  ```
  Processed in declaration order; later content overrides earlier; the current file's keys override every included file. Circular includes raise `ArgumentError`.
- **Path resolution** mirrors [PHPStan's rule](https://phpstan.org/config-reference#paths). Every path-bearing key (`paths:`, `signature_paths:`, `plugins_io.allowed_paths:`, `includes:`) is resolved relative to the **directory of the config file that declares it**. `paths: [lib]` in `<root>/.rigor.dist.yml` means `<root>/lib`; the same line in `<root>/sub/extra.yml` means `<root>/sub/lib`. `cache.path:` is the one exception — it stays as the literal user-supplied string so `--cache-stats` / `--clear-cache` messages read project-relative.
- **`rigor init`** now writes `.rigor.dist.yml` by default (the committed project default). Pass `--path=.rigor.yml` for the developer-local override.
- **`docs/handbook/01-getting-started.md`** § "A first walk through Rigor's config file" expanded with the new "Two file names, no implicit merge" + "Path resolution rules" subsections.

#### v0.1.1 Track 3 — plugin authoring DX

##### Slice 8 — plugin spec helper module extracted

- **New `Rigor::IntegrationSupport::PluginHelpers` module** at [`spec/integration/examples/support/plugin_helpers.rb`](spec/integration/examples/support/plugin_helpers.rb), auto-included for every `*_plugin_spec.rb` file under `spec/integration/examples/`. Replaces per-spec boilerplate (`requirer` lambda, hand-rolled `run_plugin`, hand-rolled `plugin_diagnostics` filter) with five helpers. All seven example plugin specs migrated; spec total dropped ~15%. `spec/spec_helper.rb` now also loads `spec/integration/**/support/**/*.rb`. SKILL Phase 6 updated with the slimmed boilerplate.

##### Slice 9 — strict per-demo cache isolation under `tmp/`

- **Each `examples/rigor-*/demo/.rigor.yml` now sets `cache.path: tmp/.rigor/cache`** so demo runs write under `tmp/` instead of `.rigor/cache/`. Each demo gains a `/tmp/`-only `.gitignore` (anchored to the demo root). The layout survives the future `git subtree split` per the `rigor-plugin-author` SKILL without depending on the parent repo's `.gitignore`.
- **CLI fix.** `Rigor::CLI#run_check` previously hardcoded `cache_root = ".rigor/cache"` and ignored `.rigor.yml`'s `cache.path:` setting. The CLI now consults `configuration.cache_path` so the demo `.rigor.yml` setting actually takes effect. The slice intentionally avoids "demo mode" auto-detection — demos opt in explicitly. `rigor-plugin-author` SKILL Phase 5 updated.

##### Slice 10 — examples re-included in RuboCop with documented relaxations

- **`.rubocop.yml`** removed the blanket `examples/**/*` exclusion. The new layout disables `Metrics/*` and `Naming/FileName` for examples, relaxes `Style/TopLevelMethodDefinition` and `Style/OneClassPerFile` for `examples/*/demo/**/*`, and excludes `Lint/StructNewOverride` / `Layout/LineLength` / `Lint/DuplicateBranch` / `Style/EmptyElse` for `examples/**/*`. Each carve-out is annotated inline. RuboCop now inspects 262 files / 0 offenses (was 210). Autocorrect cleaned up the previously-unchecked sources (`require "set"` removal, block-pass shorthand, etc.).

#### v0.1.1 Track 4 — maintenance

##### Item 13 — prelude `composed` bodies classify as `dispatch`

- **`tool/extract_builtin_catalog.rb` `classify_purity`** now returns `"dispatch"` for `body_kind: composed` prelude entries instead of falling through to `"unknown"`. `composed` invariably ends in a Ruby method dispatch, and Ruby methods are user-overridable, so the catalog must treat the call as unsafe for folding either way. Both `unknown` and `dispatch` are non-foldable per `FOLDABLE_PURITIES`, so folding behaviour is unchanged; the rename is catalog self-documentation cleanup. `numeric.yml` `Integer#ceildiv` is the v0.1.1 trigger; ~50 `pathname.yml` Pathname-facade entries plus rows in `array.yml` / `hash.yml` / `io.yml` / `proc.yml` / `time.yml` reclassify the same way.

#### v0.1.1 scope expanded to multi-track release

- **`docs/MILESTONES.md` § "v0.1.1 — Planned"** restructured into four parallel tracks: Track 1 (literal-string / refinement narrowing depth), Track 2 (cross-plugin API per ADR-9 + plugin return-type contributions), Track 3 (plugin authoring DX), Track 4 (maintenance).
- **`docs/CURRENT_WORK.md`** updated to describe the four-track structure rather than just the regex-pattern headline.

### Fixed

#### `target_ruby` setting now consumed at parse time (phantom-setting wiring closed)

- **Phantom configuration setting closed.** `target_ruby` had an attribute reader, a `.rigor.yml` entry, a default of `"4.0"`, a CLI help mention, and a handbook example — but no runtime code consumed it. The setting was loaded into `Configuration#target_ruby` and then ignored. `Prism.parse_file` was called without `version:` everywhere.
- **Wired through to Prism.** `Analysis::Runner#analyze_file`, `CLI::TypeOfCommand#execute`, and `CLI::TypeScanCommand#scan_one` now pass `version: @configuration.target_ruby` to `Prism.parse_file` / `Prism.parse`.
- **Format validation at Configuration load.** `target_ruby` MUST match `<major>.<minor>`, `<major>.<minor>.<patch>`, or the literal `"latest"`. Other shapes raise `ArgumentError` at `Configuration.new` time.
- **Fail-fast for Prism-rejected versions.** Format-passing strings that Prism doesn't accept (e.g. `"3.0"` — too old) used to crash the run on the first file. `Runner#run` now does a one-time smoke parse against `target_ruby`; if Prism raises `ArgumentError`, the run returns a single `:builtin configuration-error` diagnostic at `.rigor.yml:1:1` naming the offending version.

#### v0.1.1 Track 4 item 11 — three `lib/` sig drifts closed

- **`Trinary#negate`** collapsed the `:maybe` arm into the `case`'s `else`, so the case is exhaustive without changing semantics. The constructor invariant (`value ∈ [:yes, :no, :maybe]`) already guaranteed the third path; the previous form returned `nil` on the unreachable fallthrough, which Rigor's type analysis (correctly) flagged as a `Trinary | nil` return against the declared `Trinary`.
- **`Type::IntegerRange#lower` / `#upper`** rewrote the `m.is_a?(Symbol) ? ±Float::INFINITY : m` ternary as an `is_a?(Integer)` early return. The new form (`return m if m.is_a?(Integer); ±Float::INFINITY`) lines up with Rigor's narrowing path so the analyzer infers `Integer | Float` directly without leaking the Symbol arm. Runtime behaviour unchanged — `min` / `max` were always one of `Integer` / `:neg_infinity` / `:pos_infinity`.
- **`bundle exec exe/rigor check lib`** now reports `No diagnostics`. Categories A-1 / A-2 in [`docs/notes/20260503-steep-cross-check-triage.md`](docs/notes/20260503-steep-cross-check-triage.md) closed.

## [0.1.0] - 2026-05-07

The tenth preview, and the **first plugin-contract release**. v0.0.3 → v0.0.9 built the substrate (type vocabulary, inference engine, persistent cache layer, `Rigor::FlowContribution` bundle, public-API drift pins, `RBS::Extended` directive plumbing); v0.1.0 turns that substrate into a stable extension API. All six slices of [ADR-2 § "Extension API"](docs/adr/2-extension-api.md) have landed (`Rigor::Plugin` registration / loading, `Plugin::TrustPolicy` + `Plugin::IoBoundary`, `FlowContribution::Merger`, internal narrowing routed through the merger, plugin diagnostic emission, plugin-side cache producers), backed by six worked plugin examples under [`examples/`](examples/README.md) and a nine-chapter end-user handbook under [`docs/handbook/`](docs/handbook/README.md). The Steep-inspired diagnostic improvements ([ADR-8](docs/adr/8-steep-inspired-improvements.md)) — diagnostic ID family hierarchy, severity profile, `def.return-type-mismatch` rule — also ship in this cycle.

The next release after `0.1.0` is `0.1.1` — single-digit version-component policy. v0.1.1's headline slice is the **regex pattern → refinement-name recogniser** that extends `Inference::Narrowing.analyse_match_write` (see [`docs/MILESTONES.md`](docs/MILESTONES.md) § "v0.1.1 — Planned").

### Added

#### Plugin contract — `Rigor::Plugin` namespace (ADR-2)

- **`Rigor::Plugin.register(plugin_class)`** is the gem-side entry point plugins call at load time. Plugins subclass **`Rigor::Plugin::Base`**, declare their identity through **`manifest(id:, version:, description:, protocols:, config_schema:)`**, override **`#init(services)`** to wire the injected service container, and override **`#diagnostics_for_file(path:, scope:, root:)`** to walk the parsed `Prism::Node` and return per-file `Rigor::Analysis::Diagnostic` rows.
- **`Rigor::Plugin::Manifest`** is a frozen value object with `id` / `version` / `description` / `protocols` / `config_schema`, plus `#validate_config(config)` returning an array of error strings the loader converts into a `LoadError`. **`Rigor::Plugin::Services`** is the DI container — `reflection`, `type`, `configuration`, `cache_store`, `trust_policy`, plus `#io_boundary_for(plugin_id)`. **`Rigor::Plugin::Registry`** is the read-side snapshot — `plugins` / `ids` / `find(id)` / `load_errors`. **`Rigor::Plugin::LoadError`** is the public failure carrier.
- **`.rigor.yml` `plugins:` extension.** Each entry is now either a bare gem-name string (`rigor-rails`) or a hash (`{ gem:, id:, config: }`). The hash form is required when one gem registers more than one plugin or when the user supplies a config block. **`Analysis::Runner#plugin_registry`** exposes the loaded plugins after the run.
- **Loader failure isolation.** `Plugin::Loader` collects every `LoadError` (gem-load failure, missing registration, multi-registration ambiguity, duplicate ids, config-schema violation, `#init` raise) on the resulting `Registry`. `Analysis::Runner` converts each into a `:error` `Diagnostic` with `source_family: :plugin_loader` and `rule: "load-error"`, then continues the analysis. Plugin exceptions inside the per-file `#diagnostics_for_file` hook isolate as a `:plugin_loader runtime-error` diagnostic.

#### Plugin trust / I/O policy (ADR-2 § "Plugin Trust and I/O Policy")

- **`Rigor::Plugin::TrustPolicy`** — frozen value object exposing `trusted_gems`, `allowed_read_roots`, `network_policy`, plus `#allow_read?(path)` / `#network_allowed?` / `#gem_trusted?(name)` predicates. v0.1.0 accepts only `network_policy: :disabled`.
- **`Rigor::Plugin::IoBoundary`** — per-plugin analyzer-side helper for sandboxed file reads. `#read_file(path)` validates the absolute path against the policy, returns the bytes, and accumulates a `:digest` `Cache::Descriptor::FileEntry` so contributions stay invalidatable alongside their inputs. `#open_url(url)` always raises `Plugin::AccessDeniedError` while the policy is `:disabled`. `#cache_descriptor` returns a frozen `Cache::Descriptor` capturing the boundary's read history.
- **`Rigor::Plugin::AccessDeniedError`** — public exception carrying `reason:` (`:read_outside_scope` / `:network_disabled`) and `resource:` (offending path or URL).
- **`.rigor.yml` `plugins_io:` section.** New top-level key with `network:` (only `disabled` accepted in v0.1.0) and `allowed_paths:` (extra absolute / project-relative paths plugins may read from beyond the project root + signature_paths + trusted-gem roots). Surfaced through `Configuration#plugins_io_network` / `#plugins_io_allowed_paths`. Defaults preserve the strictest stance.
- **`Analysis::Runner` trust-policy build.** The runner derives `trusted_gems` from the gem-name half of each `Configuration#plugins` entry and `allowed_read_roots` from the project root, signature paths, each trusted gem's `Gem::Specification#full_gem_path` (when loadable), and the user's `plugins_io.allowed_paths` extras. The built `TrustPolicy` lands on the `Plugin::Services` container.

#### Plugin contribution merger (ADR-2 § "Plugin Contribution Merging")

- **`Rigor::FlowContribution#to_element_list`.** Mechanical / deterministic / round-trippable flattening of a bundle into `(target, edge, kind)`-keyed `Element` rows. Spec at [`docs/internal-spec/flow-contribution-merger.md`](docs/internal-spec/flow-contribution-merger.md).
- **`Rigor::FlowContribution::Element` / `Conflict` / `MergeResult`.** Frozen `Data` value objects. `Conflict.reason` enum: `:return_type_collapse`, `:exceptional_disagreement`, `:lower_tier_contradiction`. `MergeResult` carries the eight slots from `FlowContribution` plus `provenances` and `conflicts`.
- **`Rigor::FlowContribution::Merger`.** Stateless module-level surface (`Merger.merge(contributions)`, `Merger.tier_for(provenance)`). Implements the ADR-2 authority tiers (`:builtin > :rbs_extended / :generated > :plugin > unknown`) with deterministic intra-tier ordering and the composition rules: return-type intersection (collapse via mutual `accepts.no?`), edge-local fact accumulation with payload-equality dedupe, mutation / invalidation / role union, single-valued exceptional with disagreement detection, lower-tier contradiction handling that preserves the higher-tier value while emitting a `Conflict`.
- **Canonical `FlowContribution::Fact` substrate.** Frozen `Data.define(:target_kind, :target_name, :type, :negative)` with `#target` accessor (`:self` for self-targeted, `[:parameter, name]` for parameter-targeted) so two facts that narrow the same target group into a single merge bucket regardless of source family. **`PredicateEffect#to_fact` / `AssertEffect#to_fact`** lift the parser-side typed Effect carriers into Facts. `RbsExtended.read_flow_contribution` now populates slot payloads with Facts; assert effects route by condition (`:always` → `post_return_facts`, `:if_truthy_return` → `truthy_facts`, `:if_falsey_return` → `falsey_facts`).

#### Plugin diagnostic emission protocol

- **`Plugin::Base#diagnostics_for_file(path:, scope:, root:)`** — per-file emission hook. Plugin subclasses return an array of `Rigor::Analysis::Diagnostic` rows; the runner invokes the hook once per analysed file. Default returns `[]`.
- **Auto-stamped provenance.** `Analysis::Runner` re-stamps every plugin-emitted diagnostic with `source_family: "plugin.<manifest.id>"` so plugin authors cannot accidentally publish under another plugin's id or under `:builtin`.
- **Qualified-rule text rendering.** `Diagnostic#to_s` appends `[<source_family>.<rule>]` for non-builtin source families. The standard text stream now surfaces plugin / `rbs_extended` / `generated` provenance without changing the layout for built-in rules.
- **`Conflict#to_diagnostic(path:, line:, column:, severity: :error)`.** Converts a merger conflict into a `Diagnostic` with `source_family: :contribution_merge` and a kebab-cased `rule` derived from the conflict reason (`return-type-collapse`, etc.).
- **`Analysis::Runner.new(plugin_requirer:)`** kwarg lets specs inject a fake requirer so the runner exercises plugin loading without depending on installed gems.

#### Plugin-side cache producers

- **`Plugin::Base.producer(id, serialize:, deserialize:, &block)` DSL.** Class-level declaration registers a cached producer; the block body runs through `instance_exec` so `io_boundary` / `services` / `manifest` / `config` are in scope. `serialize:` / `deserialize:` forward to `Cache::Store#fetch_or_compute`; default round-trip is `Marshal.dump` / `Marshal.load`.
- **`Plugin::Base#cache_for(producer_id, params:, descriptor:)` callable.** Returns a callable that performs the cache round-trip. The descriptor is auto-assembled from (1) the plugin's `PluginEntry` template (id, version, SHA-256 of canonicalised config), (2) the `IoBoundary`'s accumulated `:digest` `FileEntry` rows, and (3) the user-supplied `params:` hash. Optional `descriptor:` extension flows through `Cache::Descriptor.compose` for `GemEntry` / `FileEntry` / `ConfigEntry` rows the boundary cannot capture; per-slot conflicts raise `Cache::Descriptor::Conflict`.
- **Cache-id sandbox.** `Plugin::Base#cache_for` auto-prefixes producer ids with `plugin.<manifest.id>.` so plugin caches stay sandboxed from built-in producers (`rbs.*`) and from each other. `rigor check --cache-stats` shows attribution unambiguously through the prefix.
- **`Plugin::Base#io_boundary` memoised accessor** so the per-plugin `IoBoundary`'s read history persists across producer invocations within the same plugin instance and feeds cache invalidation.

#### Worked plugin examples (six gems under [`examples/`](examples/README.md))

- **[`rigor-deprecations`](examples/rigor-deprecations/README.md)** — under 80 lines; the smallest worked example. Config-driven deprecation warnings: `.rigor.yml` declares an `:array` of `{method:, receiver:?, replacement:?, since:?}` rows; matches surface as `:warning plugin.deprecations.deprecated-call`. Recommended starting point for "I want to author my first plugin."
- **[`rigor-lisp-eval`](examples/rigor-lisp-eval/README.md)** — types literal AST arguments. Walks a small S-expression-style grammar (`:+`/`:-`/`:*`/`:/`, `:<`/`:>`/`:==`, `:and`/`:or`/`:not`, `:if`) inside `Lisp.eval([:+, 1, [:*, 2, 3]])` calls and emits an `:info plugin.lisp-eval.inferred-return-type` naming the statically-inferred return type. Ill-typed forms surface as `:error plugin.lisp-eval.type-error`.
- **[`rigor-units`](examples/rigor-units/README.md)** — local-variable flow tracking. Types a units-of-measure DSL (`100.kilometers`, `2.hours`, `distance / time`, `60.kilometers.per_hour`, `speed.in_kilometers_per_hour`) recognising four dimensions (`Distance`, `Time`, `Speed`, `Acceleration`). Catches dimensional mismatches like `Distance + Time`, `speed.in_meters`.
- **[`rigor-statesman`](examples/rigor-statesman/README.md)** — two-pass DSL analysis. Walks `state_machine do ... end` blocks to collect declared states, then validates `transition_to(:sym)` references with Levenshtein-distance did-you-mean suggestions. Configurable for `aasm` / hand-rolled DSLs.
- **[`rigor-pattern`](examples/rigor-pattern/README.md)** — plugin → analyzer collaboration. Asks Rigor's type system whether each `validate(:name, value)` call's `value` argument is provably a literal string (via `Scope#type_of` + `Type::Combinator.literal_string_compatible?`) and runs the configured regex against the literal value at lint time. Inherits every literal-string improvement Rigor lands going forward.
- **[`rigor-routes`](examples/rigor-routes/README.md)** — IoBoundary + cache producer reference. Validates Rails-style route helper calls (`users_path`, `edit_user_path(@user.id)`, …) against `config/routes.yml`. Reads the YAML once via `IoBoundary#read_file`, caches the parsed `RouteTable` via `Plugin::Base.producer`. Demonstrates the `--cache-stats`-visible cache flow plus the "read first, `cache_for` second" pattern.

Each example ships `lib/`, runnable `demo/`, README, and an end-to-end integration spec under `spec/integration/examples/`. The [`examples/README.md`](examples/README.md) landing page carries a comparison table and recommended reading order across the six.

#### End-user handbook (nine chapters under [`docs/handbook/`](docs/handbook/README.md))

- New nine-chapter walkthrough of the type model written for Ruby programmers without prior static-typing background — getting started, everyday types, narrowing, tuples / hash shapes, methods / blocks, classes, RBS / `RBS::Extended`, understanding errors, plugins. Modeled on the TypeScript handbook v2 in volume of information; adapted to Rigor's idioms.
- Each chapter ends with cross-references into [`docs/type-specification/`](docs/type-specification/README.md), [`docs/internal-spec/`](docs/internal-spec/README.md), or the ADRs. The handbook is informational — the spec corpus binds when they disagree.

#### Steep-inspired diagnostic improvements (ADR-8)

- **Diagnostic ID family hierarchy.** Built-in rule identifiers normalised to `family.rule-name` form. The five built-in families: `call.*` (call-site rules), `flow.*` (flow-analysis proofs), `assert.*` (runtime assertion rules), `dump.*` (debug helpers), `def.*` (method-definition rules). Mapping: `undefined-method` → `call.undefined-method`; `wrong-arity` → `call.wrong-arity`; `argument-type-mismatch` → `call.argument-type-mismatch`; `possible-nil-receiver` → `call.possible-nil-receiver`; `dump-type` → `dump.type`; `assert-type` → `assert.type-mismatch`; `always-raises` → `flow.always-raises`. Backward-compatible legacy aliases keep `# rigor:disable undefined-method` working unchanged. **Family wildcards** (`# rigor:disable call`, `disable: ["call"]`) suppress every rule in the family at once.
- **Severity profile.** New `Rigor::Configuration::SeverityProfile` module with three named profiles — `lenient` (uncertain rules `:warning`), `balanced` (default — most rules `:error`, `dump.type` `:info`), `strict` (everything `:error`). `.rigor.yml` `severity_profile:` and `severity_overrides:` keys control the final-filter re-stamping. `severity_overrides:` accepts canonical rule ids, family wildcards, and the `off` / `"off"` value (drops the diagnostic entirely).
- **`def.return-type-mismatch` rule.** `CheckRules` now flags methods whose body's last expression cannot satisfy the RBS-declared return type. Conservative envelope: the method must have an RBS sig reachable through `Reflection.{instance,singleton}_method_definition`; the body's last expression must type to a non-`Dynamic[top]` value; the comparison is `declared.accepts(inferred)`. `:no` (proven mismatch) emits at the rule's authored `:error` severity (re-stamped to `:warning` under the `balanced` profile, `:error` under `strict`); `:maybe` is silent in the v0.1.0 first cut.

#### Type-vocabulary tightening

- **Narrowing through `if regex =~ str` named-capture predicates.** `Inference::Narrowing.analyse_match_write` recognises `Prism::MatchWriteNode` predicates and narrows every named-capture target from `String | nil` (the binding `eval_match_write` records) down to `String` in the truthy branch, `Constant[nil]` in the falsey branch. Closes a precision gap that produced false `call.possible-nil-receiver` for code like `if /(?<year>\d{4})/ =~ str then year.upcase end`. Symmetric for `unless`, conditional expressions, and post-modifier `if`.
- **`literal-string` propagation through `Kernel#format` / `Kernel#sprintf` / `String#%`.** `MethodDispatcher::LiteralStringFolding` lifts `format(template, *values)` / `sprintf(template, *values)` to `literal-string` when the template is `Type::Combinator.literal_string_compatible?` and every value argument is either literal-bearing or a `Type::Constant` of any value. `String#%` lift on literal-bearing receivers when the value argument is either literal-bearing/Constant directly, or a `Tuple[…]` whose every element is literal-bearing/Constant.
- **`literal-string` propagation through `Array#join`.** `MethodDispatcher::LiteralStringFolding` lifts `Tuple[…].join(separator)` to `literal-string` when every element of the Tuple plus the optional separator argument is `Type::Combinator.literal_string_compatible?`. Empty `Tuple[]` lifts trivially.

#### Cache layer follow-ups

- **Per-method Reflection cache.** `Cache::RbsInstanceDefinitions` / `Cache::RbsSingletonDefinitions` cache `RBS::Definition` objects (instance and singleton sides) as a single `Hash<String, RBS::Definition>` blob per kind. Disk footprint for `bundle exec exe/rigor check lib` drops from 212 MiB → 25 MiB; cold-run timing drops from 5.94s → 3.15s. `RbsLoader#instance_definitions_table` / `#singleton_definitions_table` load the blob on first access and answer per-class queries via Hash lookup; class-name keys normalise to `RBS::TypeName#to_s` form via the new `#normalise_class_key` helper.
- **RBS sig drift detection.** `spec/rigor/public_api_drift_spec.rb` gains an "RBS sig drift" describe block verifying that every public method in the runtime drift snapshots is also declared in the project's `sig/rigor/*.rbs`. Five drift-pinned namespaces with sigs (`Scope`, `Environment`, `Type::Combinator`, `Reflection`) are sig-drift-checked at every spec run; eleven namespaces without sigs (`Plugin::*`, `FlowContribution::*`) are tracked in a dedicated `UNSIGNED_NAMESPACES` snapshot.

### Changed

- **Internal narrowing routes through `FlowContribution::Merger`.** Three of the eight `Rigor::RbsExtended::*` consumer call sites now route flow-contribution narrowing through `RbsExtended.read_flow_contribution` + `Merger.merge`: `Inference::Narrowing` predicate / assert-if narrowing (one shared `analyse_rbs_extended_contribution` analyser); `Inference::StatementEvaluator#apply_rbs_extended_assertions` (consumes the merged `post_return_facts` slot); `MethodDispatcher::RbsDispatch.translate_return_type` (reads the `return_type` slot via the merger). Future plugin / `:rbs_extended` bundles compose at these call sites through `MergeResult#conflicts` rather than racing each other. **No user-visible behaviour change.** The remaining five consumers are param-override readers explicitly excluded from `read_flow_contribution`.

### Fixed

- **`;`-prefixed block-local declarations now shadow outer locals to `Constant[nil]`.** `Inference::StatementEvaluator#build_block_entry_scope` binds every `;`-prefixed block-local (`do |i; x| ... end`) to `Constant[nil]` at block entry, shadowing any same-named outer local for the duration of the block body. Per Ruby's semantics, `;`-block-locals are freshly nil-valued on every block invocation; previously the inner read of `x` saw the outer binding, which would let `x.even?` type-check despite the runtime `nil.even?` `NoMethodError`.
- **Cache load order for CLI flow.** `lib/rigor/cache/store.rb` and `lib/rigor/cache/rbs_descriptor.rb` now `require_relative "descriptor"`. In CLI flow, the umbrella `lib/rigor.rb` is never loaded, so `Cache::Descriptor` was undefined when the cache producers fired. The resulting `NameError` was being silently swallowed by `RbsLoader#cached_class_known`'s `rescue StandardError` (and friends), causing the cache layer to be effectively dead in production CLI runs (`--cache-stats` showed `0 hits, 0 misses, 0 writes` despite `cache_store` being set). Fixed; `--cache-stats` now reports real activity.
- **Fail-soft `rescue StandardError` was masking analyzer-internal bugs.** Tightened to `rescue ::RBS::BaseError` across the RBS-touching code paths — `environment/rbs_loader.rb`, `cache/rbs_constant_table.rb`, `cache/rbs_class_ancestor_table.rb`, `cache/rbs_class_type_param_names.rb`, `reflection.rb`. Analyzer-internal `NameError` / `NoMethodError` / `LoadError` now propagate so similar bugs surface immediately rather than silently degrading user-visible behaviour.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rigortype/rigor/compare/v0.0.9...v0.1.0
