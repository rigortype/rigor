# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — `manifest(produces:)` / `manifest(consumes:)` declarations (v0.1.1 Track 2 / ADR-9 slice 4)

- **`Rigor::Plugin::Manifest`** gains two new declarative fields. `produces:` is an `Array<Symbol>` listing the names this plugin publishes through `#prepare(services)`; `consumes:` is an `Array<{ plugin_id:, name:, optional: }>` listing the `(plugin_id, name)` pairs this plugin reads from `services.fact_store`. Optional flag (`optional: true`) marks dependencies whose absence is acceptable — the consumer falls through to a graceful `nil` from `fact_store.read`.
- **New `Rigor::Plugin::Manifest::Consumption`** frozen Data shape (`Data.define(:plugin_id, :name, :optional)`). Manifest construction coerces hash entries (`{ plugin_id: "ar", name: :model_index }`) into `Consumption` instances; YAML round-trip via string-keyed hashes is supported. Malformed entries (missing `plugin_id` or `name`, non-Array `consumes:`) raise `ArgumentError` at class-definition time with a message naming the offending entry.
- **No loader behaviour change yet.** Slice 4 carries the declarations on the manifest; ADR-9 slice 5 (queued) wires `Plugin::Loader` to consume them — topological sort by `consumes` so producers run before consumers, plus early `:missing-producer` validation when a non-`optional` consume names a `(plugin_id, name)` no loaded plugin produces.
- **Drift snapshot** updates: `Rigor::Plugin::Manifest` exposes `produces()` / `consumes()` getters, and the new `Rigor::Plugin::Manifest::Consumption` Data shape is pinned alongside `Rigor::Plugin::FactStore::Fact`.

### Added — `Plugin::Base#prepare(services)` hook + Runner invocation (v0.1.1 Track 2 / ADR-9 slice 3)

- **New `Plugin::Base#prepare(services)`** default-no-op hook. Producer plugins override to compute and publish facts other plugins consume:
  ```ruby
  def prepare(services)
    services.fact_store.publish(plugin_id: manifest.id, name: :model_index, value: model_index)
  end
  ```
- **`Analysis::Runner` calls `#prepare`** on every loaded plugin once per `run`, after `#init` and before per-file iteration. Plugins are visited in registration order; ADR-9 slice 5 (queued) introduces topological ordering by `manifest(consumes:)` so producers always run before consumers, but for now `Configuration#plugins` order MUST be producer-first if cross-plugin dependencies exist.
- **Failure isolation.** A `#prepare` raise becomes a `:plugin_loader runtime-error` diagnostic mirroring the `#diagnostics_for_file` raise envelope. The plugin's facts are considered un-published; downstream consumers see `nil` from `fact_store.read` and degrade gracefully.
- **Drift snapshot** updated: `Rigor::Plugin::Base` now exposes `prepare(req:services)` alongside `init(req:services)`.

### Added — `Plugin::Services#fact_store` accessor (v0.1.1 Track 2 / ADR-9 slice 2)

- **`Rigor::Plugin::Services`** gains a `fact_store` attribute (and a matching keyword arg in the constructor). When no `fact_store:` is supplied, a fresh `Plugin::FactStore` instance is constructed per Services. The runner (slice 3) will thread its own per-run instance through. Plugins reach for `services.fact_store.read(plugin_id:, name:)` to consume facts and `services.fact_store.publish(...)` to produce them.
- **Public-API drift snapshot** in `spec/rigor/public_api_drift_spec.rb` updated to include `fact_store()` on `Rigor::Plugin::Services`.

### Added — `Rigor::Plugin::FactStore` value object (v0.1.1 Track 2 / ADR-9 slice 1)

- **New `Rigor::Plugin::FactStore`** at [`lib/rigor/plugin/fact_store.rb`](lib/rigor/plugin/fact_store.rb). Per-run cross-plugin fact storage per [ADR-9](docs/adr/9-cross-plugin-api.md) — a producer plugin (e.g. `rigor-activerecord`) publishes a typed `(plugin_id, name) -> value` triple in its `#prepare` hook (slice 3), and a consumer plugin (e.g. `rigor-actionpack` Phase 1) reads it via `services.fact_store.read(plugin_id:, name:)` in `#diagnostics_for_file`. The store is constructed fresh at the start of every `Analysis::Runner.run` and discarded at the end — caching the underlying expensive computation is the producer's job (`Plugin::Base.producer`); the FactStore just publishes the *reference* to that already-cached result.
- **API surface (frozen by `spec/rigor/public_api_drift_spec.rb`).** `#publish(plugin_id:, name:, value:)`, `#read(plugin_id:, name:)`, `#published?(plugin_id:, name:)`, `#each_fact(&)`, plus the `Fact = Data.define(:plugin_id, :name, :value)` shape and `Conflict` exception class. `plugin_id` is canonicalised to String and `name` to Symbol on every operation. `Conflict` carries `plugin_id` / `name` / `existing` / `incoming` for diagnostic provenance. The store is thread-safe via an internal Mutex.
- **Conflict semantics.** A duplicate `publish` with the same value (`==`) is a no-op; differing values raise `Conflict`. Since `plugin_id` namespaces the key, a real conflict only happens when a single plugin publishes twice with differing values — the conflict signals a plugin-author bug, never a load-time interaction between unrelated plugins.
- **Slice 1 only.** This is the pure value object — no plugin loader changes yet. ADR-9 slices 2 (`Plugin::Services#fact_store` accessor), 3 (`Plugin::Base#prepare(services)` hook + Runner invocation), 4 (`manifest(produces:/consumes:)` declarations), and 5 (topological sort + missing-producer detection) follow in subsequent commits.

### Changed — strict per-demo cache isolation under `tmp/` (v0.1.1 Track 3 slice 9)

- **Each `examples/rigor-*/demo/.rigor.yml` now sets `cache.path: tmp/.rigor/cache`** so demo runs write their cache under `tmp/` instead of `.rigor/cache/`. The `tmp/` location is anchored within each demo, which matters for the eventual `git subtree split` per the `rigor-plugin-author` SKILL — the cache discipline survives the split without depending on the parent repo's `.gitignore`.
- **Each demo gets a `/tmp/`-only `.gitignore`** (anchored to the demo root) so the cache stays out of git automatically. The repo-root `.gitignore` `/tmp/` is anchored at the root and would not catch demo-local `tmp/` directories without this addition.
- **CLI fix.** `Rigor::CLI#run_check` previously hardcoded `cache_root = ".rigor/cache"` and ignored `.rigor.yml`'s `cache.path:` setting. The CLI now consults `configuration.cache_path` so the demo `.rigor.yml` setting actually takes effect. `--cache-stats` reports `Cache (root: tmp/.rigor/cache)` when the demo runs.
- **No CLI "demo mode" concept.** The slice intentionally avoids auto-detection — demos opt in explicitly via `.rigor.yml`. The repo-root `.gitignore`'s non-anchored `.rigor/cache/` pattern stays in place as a fallback for any project that still defaults to that path.
- **`rigor-plugin-author` SKILL Phase 5** updated with the `cache.path: tmp/.rigor/cache` template, the per-demo `.gitignore` template, and the subtree-split readiness checklist.

### Added — `String#start_with?` / `#end_with?` / `#include?` flow facts (v0.1.1 Track 1 slice 4)

- **`Inference::Narrowing#analyse_string_predicate`** recognises `s.start_with?("foo")`, `s.end_with?(...)`, and `s.include?(...)` against a `Constant<String>` needle and a `Prism::LocalVariableReadNode` receiver. The truthy edge attaches an `Analysis::FactStore::Fact` (`bucket: :relational`, `predicate:` the method name, `payload:` the needle string, `polarity: :positive`); the falsey edge attaches the `:negative` mirror.
- **No type narrowing.** Rigor has no "starts-with-X" carrier today, so the receiver's type stays unchanged on both edges. The slice intentionally lands the lightweight FactStore-based form first; downstream consumers (a future plugin's `prepare(services)` hook, an internal post-narrowing rule) read these facts when they need the predicate semantics. Mirrors the relational-fact pattern already used by `==` / `!=` against broader-than-Constant domains.
- **Receiver type gating is left to consumers.** `String#start_with?` / `#end_with?` are String-only, but `Array#include?` / `Hash#include?` exist with different semantics. The slice 4 producer doesn't gate on receiver type — facts are advisory, and any consumer that acts on them must verify the receiver is a String.

### Added — full `self`-narrowing in `predicate-if-*` / `assert-if-*` / `assert` directives (v0.1.1 Track 1 slice 3)

- **Three additional receiver shapes now narrow `self`-targeted facts** (in addition to the v0.1.0 LocalVariableReadNode case):
  - **`InstanceVariableReadNode`** — `@buddy.logged_in?` narrows `@buddy` itself on each edge via `Scope#with_ivar`.
  - **`Prism::SelfNode`** — `self.logged_in?` narrows `scope.self_type` via `Scope#with_self_type`.
  - **Implicit self (nil receiver)** — `logged_in?` with no receiver inside an instance method body narrows `scope.self_type`. `Inference::Narrowing#analyse_call` no longer rejects nil-receiver call shapes outright; the RBS::Extended path is allowed to run when the receiver is implicit.
- **`Inference::Narrowing#apply_self_fact`** is the new dispatch helper covering all four receiver shapes (LocalVariableRead / InstanceVariableRead / SelfNode / nil). Mirrored as `StatementEvaluator#apply_self_post_return_fact` for the `assert self is T` post-return path.
- **`Inference::Narrowing#resolve_rbs_extended_method`** consults `scope.self_type` when `node.receiver` is nil so the implicit-self call's method definition is reachable. Mirrors the resolver pattern already in use in `StatementEvaluator#resolve_call_method`.
- **Inference engine spec** at [`docs/internal-spec/inference-engine.md`](docs/internal-spec/inference-engine.md) updated to describe the four supported receiver shapes; the previous "self produces no scope edits" caveat is removed.
- **Integration fixture** `spec/integration/fixtures/self_predicate/` extended with `User#greet_buddy` (ivar receiver) and `User#greet` (implicit self) cases. `assert_type` checks confirm the narrowing on each edge.

### Added — `literal-string` preservation through `#center` / `#ljust` / `#rjust` (v0.1.1 Track 1 slice 5c)

- **`MethodDispatcher::LiteralStringFolding.fold_width_pad`** lifts `#center` / `#ljust` / `#rjust` calls on a literal-bearing receiver to `literal-string`. The first argument (the target width) MUST be Integer-typed (`Type::Constant<Integer>`, `Type::Nominal["Integer"]`, or `Type::IntegerRange`). The optional second argument (padding) MUST be literal-bearing per `Type::Combinator.literal_string_compatible?`. The default padding is a space — always literal — so the no-second-arg form passes through directly. Width is allowed to be any Integer because Ruby accepts negative widths and widths smaller than the receiver's length without raising.
- **Carrier collapse.** `non-empty-literal-string` collapses to plain `literal-string` for the same reason it does in slice 5a — the result is structurally a fresh string of given width, so the receiver's non-empty refinement isn't carried.

### Added — `Integer#to_s` precision on non-negative `IntegerRange` (v0.1.1 Track 1 slice 5b)

- **`MethodDispatcher::ShapeDispatch`** gains an `IntegerRange` receiver handler. When the range's lower bound is `>= 0`, every member is a non-negative integer and `to_s(base)` returns a digit-string with no leading sign, so the result lifts to the matching imported refinement: base 10 → `decimal-int-string`, base 8 → `octal-int-string`, base 16 → `hex-int-string`. No-arg `to_s` defaults to base 10. Bases without a digit-only refinement (2, 36, …) and signed ranges (whose `to_s` can carry a leading `-`) keep the v0.1.0 baseline.
- **End-to-end with v0.0.3 narrowing.** `if n.is_a?(Integer) && n >= 0; n.to_s(16); end` narrows the receiver to `non-negative-int` (existing v0.0.3 narrowing) and the call result to `hex-int-string` (this slice). Verified via `exe/rigor type-of`.

### Added — `literal-string` preservation through `#strip` / `#chomp` / `#scrub` family (v0.1.1 Track 1 slice 5a)

- **`MethodDispatcher::LiteralStringFolding`** gains a `LITERAL_PRESERVING_METHODS` rule covering `#strip`, `#lstrip`, `#rstrip`, `#chomp` (no-arg), `#chop`, and `#scrub` (no-arg). Each strips a known character subset from the ends of the string (or, for `#scrub`, replaces invalid bytes — a no-op on always-valid literal source code), so the result on a literal-bearing receiver is itself literal-bearing. The result is `literal-string` (not `non-empty-literal-string`, since `"   ".strip == ""` collapses non-empty-ness).
- **Carrier collapse on intersection.** `non-empty-literal-string` (an `Intersection[non-empty-string, literal-string]`) collapses to plain `literal-string` after the call — the non-empty refinement isn't preserved across `#strip`. Both shapes still beat the v0.1.0 baseline (`Nominal[String]` from RBS).
- **Scope.** No-arg form only. `#chomp("\n")` and other arg-bearing variants keep the v0.1.0 baseline; future slices may extend the rule when the argument itself is literal-bearing.

### Added — `Kernel#Integer` on digit-only refinements narrows to `non-negative-int` (v0.1.1 Track 1 slice 2b)

- **`MethodDispatcher::KernelDispatch`** gains a `try_integer_from_refinement` arm matching `Kernel#Integer(s)` whose argument is a `Refined[String, predicate]` with `predicate ∈ { :decimal_int, :numeric }`. The result is `non-negative-int`, mirroring the slice 2a `String#to_i` projection — both refinements describe digit-only ASCII strings, so the parse is total over the carrier domain. Plain `Nominal[String]` and other refinements (lowercase / uppercase / hex / octal) continue to fall through to the RBS sig.
- **End-to-end with slice 1.** `if /(?<year>\d+)/ =~ str; Integer(year); end` now resolves the `Integer(year)` call to `non-negative-int` instead of the RBS-declared `Integer`. Verified via `exe/rigor type-of`.
- **Scope.** Single-arg form only. `Integer(s, base)` keeps the v0.1.0 baseline (the new arm requires `args.size == 1`); a future slice can extend the recogniser to honour the explicit base.

### Added — `String#to_i` / `#to_int` on digit-only refinements narrows to `non-negative-int` (v0.1.1 Track 1 slice 2a)

- **`MethodDispatcher::ShapeDispatch.dispatch_refined`** gains four rows in `REFINED_STRING_PROJECTIONS` covering `to_i` and `to_int` on `decimal-int-string` (`/\A\d+\z/`) and `numeric-string` (Rigor's numeric-string predicate). Both refinements describe digit-only strings, so the parse is total over the carrier domain and the result is always `>= 0`. The tightest existing carrier that captures the lower bound and the integer-ness is `non-negative-int`, which the projection returns.
- **End-to-end with slice 1.** A pattern like `if /(?<year>\d+)/ =~ str; year.to_i; end` now binds `year.to_i` to `non-negative-int` instead of plain `Integer`. Slice 1 (regex pattern recogniser) is the producer; this is the first consumer of that signal.
- **Scope.** Slice 2a covers the no-arg form only. Forms like `s.to_i(base)` keep the v0.1.0 baseline since the table only fires when `args.empty?`. Slices 2b (`Kernel#Integer`) and beyond consume the same producer in subsequent commits.

### Changed — examples re-included in RuboCop with documented relaxations (v0.1.1 Track 3 slice 10)

- **`.rubocop.yml`** removed the blanket `examples/**/*` exclusion. The new layout disables `Metrics/*` and `Naming/FileName` for examples (kebab-case file names are part of the gem-id convention; mid-sized methods keep illustrations end-to-end legible), relaxes `Style/TopLevelMethodDefinition` and `Style/OneClassPerFile` for `examples/*/demo/**/*` (demos run as scripts and pack ad-hoc class hierarchies into one file), and excludes `Lint/StructNewOverride` / `Layout/LineLength` / `Lint/DuplicateBranch` / `Style/EmptyElse` for `examples/**/*` (deliberate domain words like the `:method` Struct member, long diagnostic-message strings, multi-arm switches that share a body for documentation, comment-bearing trailing `else` extension points). Each carve-out is annotated inline.
- **Autocorrect.** Running RuboCop with `-A` cleaned up the previously-unchecked example sources: dropped `require "set"` (Set is built-in on Ruby 3+), switched to the block-pass shorthand `&` form, retired stale `Metrics/*` suppressions made redundant by the carve-out, normalised string-literal interpolation quoting, etc. No example's behaviour changed; the diffs are cosmetic.
- **Result.** RuboCop now inspects 262 files / 0 offenses (was 210).

### Changed — prelude `composed` bodies classify as `dispatch` (v0.1.1 Track 4 item 13)

- **`tool/extract_builtin_catalog.rb` `classify_purity`** now returns `"dispatch"` for `body_kind: composed` prelude entries instead of falling through to `"unknown"`. `composed` is the residual body kind — a Ruby method body that is neither `Primitive.attr!(:leaf)` nor a literal return nor `self` — and any such body ends in a Ruby method dispatch (Ruby methods are user-overridable, so the catalog must treat the call as unsafe for folding either way).
- **Catalog regenerated.** `numeric.yml` `Integer#ceildiv` is the v0.1.1 trigger (the last `composed`/`unknown` entry on the numeric catalog after v0.0.9); `pathname.yml` (~50 entries that delegate through the Pathname facade), plus a handful of `array.yml` / `hash.yml` / `io.yml` / `proc.yml` / `time.yml` rows reclassify the same way. Both `unknown` and `dispatch` are non-foldable per `FOLDABLE_PURITIES = ["leaf", "trivial", "leaf_when_numeric"]`, so folding behaviour is unchanged; the rename is purely catalog self-documentation cleanup.

### Fixed — three `lib/` sig drifts closed (v0.1.1 Track 4 item 11)

- **`Trinary#negate`** collapsed the `:maybe` arm into the `case`'s `else`, so the case is exhaustive without changing semantics. The constructor invariant (`value ∈ [:yes, :no, :maybe]`) already guaranteed the third path; the previous form returned `nil` on the unreachable fallthrough, which Rigor's type analysis (correctly) flagged as a `Trinary | nil` return against the declared `Trinary`.
- **`Type::IntegerRange#lower` / `#upper`** rewrote the `m.is_a?(Symbol) ? ±Float::INFINITY : m` ternary as an `is_a?(Integer)` early return. The two methods now read `return m if m.is_a?(Integer); ±Float::INFINITY`, which lines up with Rigor's narrowing path so the analyzer infers `Integer | Float` directly without leaking the Symbol arm. Runtime behaviour is unchanged — `min` / `max` were always one of `Integer` / `:neg_infinity` / `:pos_infinity` and the new form handles each case identically.
- **`bundle exec exe/rigor check lib`** now reports `No diagnostics`. Categories A-1 / A-2 in [`docs/notes/20260503-steep-cross-check-triage.md`](docs/notes/20260503-steep-cross-check-triage.md) closed.

### Added — regex pattern -> refinement-name recogniser for named captures (v0.1.1 Track 1 slice 1)

- **New `Rigor::Builtins::RegexRefinement` module** at [`lib/rigor/builtins/regex_refinement.rb`](lib/rigor/builtins/regex_refinement.rb). Pure recogniser that maps a curated table of canonical regex sub-patterns (`\d+`, `\d{N}`, `\d{N,M}`, `\h+`, `[0-9a-fA-F]+`, `[0-9a-f]+`, `[0-9A-F]+`, `\h{N}`, `[0-7]+` and bounded forms, `[a-z]+`, `[A-Z]+`, `[[:digit:]]+`, all with `+` or `{n}` / `{n,m}` quantifiers where `n >= 1`) onto the imported refinement carriers Rigor already ships (`decimal-int-string`, `hex-int-string`, `octal-int-string`, `lowercase-string`, `uppercase-string`, `numeric-string`). Bodies that admit the empty string (`*`, `?`, `{0,N}`) or sit outside the audited table return `nil` so callers fall back to the v0.1.0 baseline (plain `String`). Spec at [`spec/rigor/builtins/regex_refinement_spec.rb`](spec/rigor/builtins/regex_refinement_spec.rb).
- **`Inference::Narrowing.analyse_match_write` consults the recogniser.** When the `MatchWriteNode`'s wrapped `=~` call has a statically known `RegularExpressionNode` receiver, every `(?<name>body)` whose body matches a recogniser row narrows the truthy edge of `if regex =~ str` to the matching refinement instead of plain `String`. Bodies with nested groups, alternation, anchors, or anything else outside the table fall back unchanged. The falsey edge is still `nil` per the v0.1.0 contract.
- **Why this lands now.** v0.1.0 introduced the `MatchWriteNode` narrowing site plus the imported refinement carriers and the existing per-name factories on `Type::Combinator`; v0.1.1 wires them together. A pattern like `if /(?<year>\d{4})-(?<month>\d{1,2})/ =~ str; year; month; end` now binds `year` and `month` to `decimal-int-string` in the truthy branch, so downstream consumers (e.g. the queued `numeric-string` propagation through `Integer(s)` slice in the same track) see a tighter type than `String`.
- **Headline of v0.1.1 Track 1**, per [`docs/MILESTONES.md`](docs/MILESTONES.md) § "v0.1.1 — Planned". Track 1 slices 2 (`numeric-string` propagation through `Integer(s)` / `s.to_i` / etc.) and 4 (`String#start_with?` / `#end_with?` / `#include?` predicate narrowing) build on this producer slice.

### Changed — extracted plugin spec helper module to slim integration specs

- **New `Rigor::IntegrationSupport::PluginHelpers` module** at [`spec/integration/examples/support/plugin_helpers.rb`](spec/integration/examples/support/plugin_helpers.rb), auto-included for every `*_plugin_spec.rb` file under `spec/integration/examples/`. Replaces the per-spec boilerplate (let-bound `requirer` lambda, hand-rolled `run_plugin` method materialising tmpdir + writing demo.rb + building Configuration + driving Analysis::Runner, hand-rolled `plugin_diagnostics` filter) with five helpers: `run_plugin(source:, plugin_entry:, cache_store:, files:, paths:)` for the convenience case, `run_plugin_in_dir(dir:, source:, …)` for multi-run tests against the same project (cache invalidation, second-run-after-edit), `plugin_diagnostics(result)` filtering by `source_family == "plugin.<manifest.id>"` derived from the spec's `let(:plugin_class) { ... }`, plus `build_plugin_requirer` and `materialize_files(dir, files)` lower-level pieces.
- **All seven example plugin specs migrated** (lisp_eval, units, pattern, statesman, deprecations, routes, activerecord). Spec total dropped from ~1240 lines to 1057 (~15% reduction). Every new plugin spec from now on starts ~30 lines lighter.
- **`spec/spec_helper.rb` now loads `spec/integration/**/support/**/*.rb` files** in addition to the existing `spec/support/`. Helpers nested under `spec/integration/` stay close to the specs they support.
- **`.codex/skills/rigor-plugin-author/SKILL.md` Phase 6 updated.** The "Integration spec" section now shows the slimmed boilerplate (~10 lines) instead of the previous hand-rolled scaffold (~40 lines). The "Spec gotchas" subsection updated to reference `run_plugin` / `run_plugin_in_dir` lifecycle semantics instead of the obsolete hand-rolled requirer pattern.

### Changed — v0.1.1 scope expanded to multi-track release

- **`docs/MILESTONES.md` § "v0.1.1 — Planned"** restructured into four parallel tracks: Track 1 (literal-string / refinement narrowing depth — the existing theme plus additional `String#start_with?` etc. narrowing and more `literal-string` propagation methods), Track 2 (cross-plugin API per [ADR-9](docs/adr/9-cross-plugin-api.md) slices 1 → 5 + plugin return-type contributions slice 1), Track 3 (plugin authoring DX — helper extraction landed; demo cache + examples RuboCop relaxation queued), Track 4 (maintenance — three `lib/` sig drifts, `node_locator_spec` cleanup, `numeric.yml` `Integer#ceildiv` resolution).
- **`docs/CURRENT_WORK.md` § "Where the Work Resumes" / "v0.1.1"** updated to describe the four-track structure rather than just the regex-pattern headline. Plugin spec helper extraction marked landed.
- The Rails plugin parallel running track (in `docs/design/20260508-rails-plugins-roadmap.md`) is unchanged — Tier 1 plugins remain unblocked on the current API; Tier 2 unblocks once ADR-9 ships in v0.1.1.

### Added — Rails ecosystem plugin roadmap and cross-plugin API design

- **[`docs/design/20260508-rails-plugins-roadmap.md`](docs/design/20260508-rails-plugins-roadmap.md)** captures the full plan for the `rigor-*` Rails ecosystem plugin family, building on the existing `rigor-activerecord` example. Three tiers: Tier 1 plugins (`rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`) need only the v0.1.0 plugin contract and can land in parallel; Tier 2 (`rigor-actionpack` Phase 1, `rigor-factorybot`) blocks on ADR-9; Tier 3 plugins (`rigor-rspec`, `rigor-pundit`, `rigor-sidekiq`, `rigor-graphql`, `rigor-activestorage`, `rigor-actioncable`) author when there is concrete user demand. A future `rigor-rails` meta-gem aggregates Tier 1+2 dependencies. Each plugin stages in `examples/rigor-<id>/` per the [`rigor-plugin-author`](.codex/skills/rigor-plugin-author/SKILL.md) SKILL discipline and extracts via `git subtree split` once stable.
- **[ADR-9 — Cross-plugin API](docs/adr/9-cross-plugin-api.md)** proposes the missing piece for Tier 2 plugins: a per-run `Plugin::FactStore` that lets producers (e.g. `rigor-activerecord` publishing `:model_index`) hand state to consumers (`rigor-actionpack` Phase 1 strong-params validation against AR columns) without re-reading source. Three additions: `Plugin::FactStore` value object, `Plugin::Base#prepare(services)` hook (called once per `Analysis::Runner.run` between `#init` and the per-file iteration), and `manifest(consumes: [...])` / `manifest(produces: [...])` declarations the loader uses for topological sort + missing-producer detection. Six independently shippable implementation slices documented; `rigor-actionpack` Phase 1 lands AFTER slice 5.
- **`docs/MILESTONES.md`** gains a "Rails ecosystem plugins" section listing the running parallel track. The Tier 1 plugins are unblocked and may be authored in any order; Tier 2 blocks on ADR-9.
- **`docs/CURRENT_WORK.md`** gains a Rails-ecosystem paragraph under "Where the Work Resumes" so the next implementer sees the parallel track up front.
- **CLAUDE.md "Read these first" table** gains the roadmap entry. **CLAUDE.md ADR table** gains ADR-9.
- **`.codex/skills/rigor-plugin-author/SKILL.md`** gains two sections: "Real-Rails alignment" (plugin source never requires Rails; per-plugin demos for subtree-split readiness; integration specs may exec real Rails for verification) and "Cross-plugin facts (post-ADR-9)" (the FactStore-based pattern, with a placeholder for a Phase 4.7 once ADR-9 lands).

### Added — example plugin: `rigor-activerecord`

- **Seventh worked example of the v0.1.0 plugin authoring surface** under [`examples/rigor-activerecord/`](examples/rigor-activerecord/) — and the most architecturally complete to date. Validates `Model.find` / `Model.find_by` / `Model.where` calls against the project's `db/schema.rb` and discovered AR model classes. Combines DSL interpretation (Prism walk over the `create_table "users" do |t| ... end` schema), multi-file `IoBoundary` reads (schema + every `app/models/*.rb`), chained cache producers (`:schema_table` + `:model_index`, both auto-invalidating on the digests of every file the boundary touched), and two-pass discover-then-validate (model classes are gathered project-wide before per-file query analysis runs).
- **Diagnostics.** `:info plugin.activerecord.model-call` for recognised finder calls (e.g. `User.where(:admin) on table users`); `:error plugin.activerecord.unknown-column` for query keys absent from the resolved table (with Levenshtein-distance ≤ 3 did-you-mean suggestions); `:error plugin.activerecord.wrong-arity` when `Model.find` is called with no arguments; `:warning plugin.activerecord.load-error` once when `db/schema.rb` cannot be read.
- **Configurable.** Three `config_schema` keys: `schema_file:` (default `"db/schema.rb"`), `model_search_paths:` (default `["app/models"]`), `model_base_classes:` (default `["ApplicationRecord", "ActiveRecord::Base"]`). Adapt to non-Rails-default project layouts or custom AR base classes.
- **Schema parser.** A small Prism interpreter under `lib/rigor/plugin/activerecord/schema_parser.rb` walks the `ActiveRecord::Schema[...].define do ... end` block and recognises `t.string`/`t.integer`/`t.text`/`t.boolean`/`t.datetime`/`t.timestamps`/`t.references` (which becomes `<name>_id` integer). Maps Rails column types to Ruby class names per `SchemaTable::RUBY_TYPE_MAPPING`. No `eval` — the schema source is parsed, not executed.
- **Inflector.** A bundled `User → users` / `BlogPost → blog_posts` / `Category → categories` inflector under `lib/rigor/plugin/activerecord/inflector.rb`. Avoids an `activesupport` runtime dependency. Handles regular plurals; users with irregular ones (`Person → people`) declare `self.table_name = "..."` on the model.
- **Limitations (intentional for v0.1.0 of the plugin).** Direct-superclass match only (multi-level inheritance not chased); `db/schema.rb` only (no `db/structure.sql`); no instance-method typing (`user.name` not yet typed as `String`); no associations / scopes / strong parameters / controllers (those belong in a future `rigor-rails` meta-gem). Each is documented in the README's "Limitations" section.
- **Demo project** under `examples/rigor-activerecord/demo/` — a sample 3-table schema (`users`, `posts`, `comments` with `t.references`-derived foreign keys), three model classes under `app/models/`, plus `demo.rb` (9 valid AR calls) and `errors_demo.rb` (5 ill-typed cases). Run with `RUBYLIB=$PWD/../lib bundle exec rigor check --cache-stats`. First run reports `plugin.activerecord.schema_table: 1 miss / 1 write` + `plugin.activerecord.model_index: 1 miss / 1 write`; second run reports `1 hit / 0 writes` for both.
- **Integration spec** at [`spec/integration/examples/activerecord_plugin_spec.rb`](spec/integration/examples/activerecord_plugin_spec.rb) — 14 examples covering recognised finder calls (find / find_by / where), `t.references` columns, inflector resolution, unknown-column with did-you-mean, multi-key partial mismatch, `find` arity, non-model receivers stay silent, `self.table_name = "..."` override, configurable `model_base_classes`, and graceful warning when `db/schema.rb` is missing.
- **Eventual extraction.** Per the discussion at the head of [`.codex/skills/rigor-plugin-author/SKILL.md`](.codex/skills/rigor-plugin-author/SKILL.md) and the recommendation in `examples/README.md`, this plugin is staged in the monorepo to validate the v0.1.0 plugin API against a real consumer; once stable it will be extracted to a separate `rigortype/rigor-activerecord` repository via `git subtree split` and published as an independent gem.

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

## [0.0.9] - 2026-05-05

The ninth preview. Theme: **finish the cache surface, broaden the type vocabulary, and lock the public API ahead of the v0.1.0 plugin contract.** v0.0.9 closes every remaining pre-`0.1.0` substrate slice: the persistent cache is wired into `rigor check` end-to-end (warm runs hit disk-backed tables; `--cache-stats` reports real hit/miss/write counts; `--no-cache` toggles it off), the type vocabulary picks up paired-complement `~T` narrowing and `literal-string` flow tracking through interpolation / `+` / `*` / `<<`, the [`RBS::Extended`](docs/type-specification/rbs-extended.md) directive surface rolls every recognised directive on a method into a single `Rigor::FlowContribution` bundle, and six new built-in catalogues cover `Random`, `Struct` (+ `Data`), `Encoding`, `Regexp` / `MatchData`, `Proc` / `Method` / `UnboundMethod`, and `Exception`.

The next release after `0.0.9` is `0.1.0` — single-digit version-component policy, no `0.0.10`. v0.1.0 starts the plugin contract proper; v0.0.9 ships the substrate that contract is designed against.

### Added

#### Cache layer wired through to `rigor check`

- **`Analysis::Runner.cache_store` surface + `rigor check --no-cache`.** Runner defaults to a `Cache::Store` rooted at `.rigor/cache`; the CLI flag threads `nil` through to disable. `Environment.for_project(cache_store:)` plumbs the Store down to the underlying `RbsLoader`.
- **First end-to-end cached producer — `RbsLoader#constant_type` reads from `RbsConstantTable`.** Cold runs build the translated constant-type table once and persist it; warm runs (and a separate loader sharing the same Store) skip the env walk entirely and pay only a `Marshal.load` of the table.
- **Five more cache producers** — `RbsKnownClassNames` (Set<String>), `RbsClassAncestorTable` (Hash<String, Array<String>>), `RbsClassTypeParamNames` (Hash<String, Array<Symbol>>), and `RbsEnvironment` (the full `RBS::Environment`). The fifth producer (`RbsEnvironment`) caches the biggest cold-start cost — `RBS::EnvironmentLoader#load + Environment.from_loader + resolve_type_names` — by adding minimal `_dump`/`_load` Marshal hooks to the rbs gem's C-extension `RBS::Location`. The patch is purely additive and idempotent; `RBS::Location` is never read from any analysis path so the lost source-position metadata is inert.
- **`Cache::Store#stats` + `--cache-stats` runtime breakdown.** In-process hits / misses / writes counters (per-producer breakdown) bumped inside `fetch_or_compute`; `rigor check --cache-stats` prints an on-disk inventory followed by a "this run:" section. Under `--no-cache` the section is omitted.
- **`Cache::Store#fetch_or_compute(serialize:, deserialize:)` callable surface.** Producers whose return values are not Marshal-clean (RBS-native objects with `RBS::Location` members, raw `IO`, …) can register custom round-trip callables. Default stays at `Marshal.dump` / `Marshal.load`. Deserialiser exceptions become cache misses. `RbsEnvironment` rides this surface.
- **Shared `Rigor::Cache::RbsDescriptor`.** Every RBS-derived producer attaches the same descriptor (rbs gem locked version + `:digest` entries for every `.rbs` file under `signature_paths` + a `rbs.libraries` configs entry), so a signature change or rbs gem bump invalidates them in lockstep.

#### Type vocabulary

- **Paired-complement narrowing for `Refined[base, predicate]`.** `Type::Refined::COMPLEMENT_PAIRS` registers bidirectional pairs; the narrowing tier returns `Refined[base, complement]` instead of the imprecise `Difference[base, refined]` fallback. Three pairs land in v0.0.9: `lowercase ↔ not_lowercase`, `uppercase ↔ not_uppercase`, `numeric ↔ not_numeric`. Positive carriers `non-lowercase-string`, `non-uppercase-string`, `non-numeric-string` join `Builtins::ImportedRefinements::REGISTRY` so users can write them directly.
- **`literal-string` carrier and `non-empty-literal-string` composition.** A `String` known to come from a source-code literal (or a composition of literals). Tracked through string interpolation `"#{...}"` (lifts to `literal-string` when every part is literal-bearing) and through the new `LiteralStringFolding` dispatcher tier covering `String#+`, `String#*`, `String#<<`, `String#concat` (lifts when every operand is literal-bearing).
- **Six new built-in catalogues** — Random, Struct (+ Data), Encoding, Regexp + MatchData, Proc / Method / UnboundMethod, Exception. Each catalog drives the fold dispatcher with per-class blocklists for indirect mutators (Random's MT-state-advancing methods, Regexp's `$~`-writing matchers, Proc / Method's `:call` / `:[]` execution paths, Exception's runtime-state readers, etc.).
- **`Numeric#clone` reclassified.** `numeric` topic's `c_index_paths` now includes `references/ruby/object.c`, so `Numeric#clone`'s alias to `rb_immutable_obj_clone` is found by the C-body classifier and the entry moves from `purity: unknown` to `purity: leaf`.

#### Pre-v0.1.0 substrate (locks the surface the plugin contract attaches to)

- **`Rigor::FlowContribution` bundle struct.** Eight content slots (`return_type`, `truthy_facts`, `falsey_facts`, `post_return_facts`, `mutations`, `invalidations`, `exceptional`, `role_conformance`) plus a `Provenance` Data carrier (`source_family`, `plugin_id`, `node`, `descriptor`). Frozen on construction; collection slots duped + frozen. Public read shape per ADR-2 § "Flow Contribution Bundle"; element-list flattening deferred to v0.1.0 alongside the contribution merger that consumes it.
- **`Rigor::RbsExtended.read_flow_contribution(method_def)`.** Rolls every recognised directive on a single RBS method (`predicate-if-(true|false)`, `assert*`, `return:`) into one `FlowContribution` with `:rbs_extended` source family. Internal narrowing keeps consuming the typed Data carriers; the bundle is the public packaging the v0.1.0 contribution merger reads.
- **Public-API drift specs for `Rigor::Scope`, `Rigor::Environment`, `Rigor::Type::Combinator`, `Rigor::Reflection`.** Snapshot-style spec at `spec/rigor/public_api_drift_spec.rb` pins each namespace's instance + singleton method set so accidental signature changes show up as test failures, not silent breakage. The four namespaces are the v0.1.0 plugin-contract attachment points.
- **`docs/internal-spec/public-api.md`.** Public/internal stability boundary declared explicitly: which namespaces are drift-pinned today (Scope / Environment / Type::Combinator / Reflection), which are public-shape but still in flux until v0.1.0 (FlowContribution, Diagnostic, Cache::Store#fetch_or_compute, RbsExtended directive readers), and which stay strictly internal (Inference::*, Analysis::FactStore / CheckRules / Runner, AST::* virtuals, Source / CLI / Configuration plumbing).

### Internal

- The cache layer's public read shape grows to cover all six producers in [`docs/internal-spec/cache.md`](docs/internal-spec/cache.md): `Descriptor`, `Store` (with the new `serialize:`/`deserialize:` kwargs and `Store#stats`), `RbsConstantTable`, `RbsKnownClassNames`, `RbsClassAncestorTable`, `RbsClassTypeParamNames`, `RbsEnvironment`, the shared `RbsDescriptor` builder, and the `RBS::Location` Marshal patch.
- `Rigor::FlowContribution` documented in [`docs/internal-spec/flow-contribution.md`](docs/internal-spec/flow-contribution.md) with the slot table, equality / `to_h` / `empty?` semantics, `RbsExtended.read_flow_contribution` mapping (predicate-if-* → `truthy_facts` / `falsey_facts`, `assert*` → `post_return_facts`, `return:` → `return_type`), and the deferred element-list flattening note.

## [0.0.8] - 2026-05-04

The eighth preview. Theme: **first cache-related code slice** — land the persistence layer that v0.0.7's cache slice taxonomy design doc fixed the schema for, with a Marshal-clean producer wired through it end-to-end. Backend choice is fixed by [ADR-6](docs/adr/6-cache-persistence-backend.md): a sharded directory of binary entries written through a custom canonical format, **zero new gem dependencies**.

### Added

- **`Rigor::Cache::Descriptor` value object.** Pure-value four-slot schema (`files`, `gems`, `plugins`, `configs`) per [`docs/design/20260505-cache-slice-taxonomy.md`](docs/design/20260505-cache-slice-taxonomy.md). Each slot holds typed, frozen entries; `FileEntry` validates its comparator enum (`:digest > :mtime > :exists`); the rest accept already-canonical hashes. `Descriptor.compose(*descriptors)` unions slots by key, prefers the stricter comparator on file conflicts, and raises `Descriptor::Conflict` on disagreeing values. `descriptor.cache_key_for(producer_id:, params:)` derives the canonical hex SHA-256 over the composed inputs; `to_canonical_bytes` produces sorted, deterministic JSON so equivalent descriptors round-trip to identical bytes.
- **`Rigor::Cache::Store` filesystem backend.** Sharded layout `<root>/<producer-id>/<2-prefix>/<62-suffix>.entry`, schema-version marker at `<root>/schema_version.txt`. Custom binary entry format (`"RIGOR\x00\x01"` magic, varint-prefixed descriptor and value, trailing SHA-256 integrity). Writes follow rename-into-place with `flock(LOCK_EX)` on the destination and `fsync` on the temp file. Reads tolerate any failure (missing file, bad magic, bad SHA-256, malformed varint, unmarshal-able payload) by falling through to a cache miss. `Store#fetch_or_compute(producer_id:, params:, descriptor:) { ... }` is the single producer-facing API; producer ids are constrained to `[a-z][a-z0-9._-]*` for filesystem safety.
- **First cached producer — `Rigor::Cache::RbsConstantTable`.** Caches a `Hash<String, Rigor::Type>` mapping every RBS-declared constant (e.g. `"::Math::PI"`) to its translated `Rigor::Type`. Descriptor: the `rbs` gem with its locked version, `:digest` entries for every `.rbs` file under `signature_paths`, and a configs entry for the libraries list. The slice plan originally named the RBS environment loader (`build_env`) as the first producer; implementation discovered `RBS::Environment` is not Marshal-clean (`RBS::Location` is a C-extension class without `_dump_data`). [ADR-6 § 8](docs/adr/6-cache-persistence-backend.md) documents the finding; the slice caches a post-translation artefact instead. `RbsLoader#constant_names` is added to the public surface so the producer can enumerate constants without reaching into the loader's private state.
- **`rigor check --cache-stats`.** Prints an on-disk inventory at the end of the run (per-producer entry counts, total bytes, schema-version marker). Sourced from a new `Rigor::Cache::Store.disk_inventory(root:)` class method. Per-run hit/miss counters are deferred until production code wires the cache (no production caller in v0.0.8).
- **`rigor check --clear-cache`.** Removes the `.rigor/cache` directory (CWD-relative) before the analysis run. Prints `Cleared cache: .rigor/cache` or `Cache already empty: .rigor/cache`. The check itself runs to completion regardless.
- **Diagnostic source-family provenance.** `Rigor::Analysis::Diagnostic` gains a `source_family:` keyword (default `:builtin`) and a `qualified_rule` accessor returning `"#{source_family}.#{rule}"` for non-default families and just `rule` for builtin diagnostics. JSON output (`to_h`) carries both `source_family` and the bare `rule` side-by-side. Prepares ADR-2's plugin-observability story without committing to the plugin API itself; no production caller in v0.0.8 sets a non-default source family.

### Internal

- New normative spec [`docs/internal-spec/cache.md`](docs/internal-spec/cache.md) tracks the cache layer's public read shape (Descriptor API, Store API, file format, atomicity & locking, schema-version mismatch behaviour, disk inventory, diagnostic provenance).

## [0.0.7] - 2026-05-05

The seventh preview. Theme: **pre-plugin coverage push** — close the gap between what the type-language and built-in-coverage specs already commit to and what the analyzer actually implements, so the plugin API designed against this surface in v0.1.0 has a complete substrate to attach to. The release is breadth-over-depth: many small fills, plus the first design output in the pre-v0.1.0 sequence.

### Added

#### Type-language type functions

- **`key_of[T]` / `value_of[T]`** project the type-level union of known keys (resp. values) for `HashShape`, `Tuple`, `Nominal[Hash, [K, V]]`, `Nominal[Array, [E]]`, and finite-bound `Constant<Range>`. Reachable through `RBS::Extended` directive payloads. The parser also accepts `lower_snake` heads alongside `kebab-case` refinements and lets nominal arguments carry their own type-args, so `key_of[Hash[Symbol, Integer]]` parses to `Symbol`.
- **`int_mask[1, 2, 4]` / `int_mask_of[T]`** compute the bitwise-OR closure over a finite integer literal set, returning a `Union[Constant<Integer>…]` for small closures and a covering `IntegerRange` past the cardinality cap. Integer literals are now accepted as parser arguments.
- **`T[K]` indexed-access operator** projects the type at index / key `K` from a structured `T`. Reachable from RBS::Extended directive payloads through trailing `[K]` segments after a parsed type, including chained `T[K1][K2]`. The parser's top-level entry now accepts class-name-headed types directly, so `Hash[Symbol, Integer][Symbol]` parses to `Symbol`.

#### Constant-carrier coverage

- **`Rational` / `Complex` literal lift.** `Prism::ImaginaryNode` (`1i`) and `Prism::RationalNode` (`1.5r`) type as `Constant<Complex>` / `Constant<Rational>`; `Kernel#Rational(num, den)` and `Kernel#Complex(re, im)` calls fold to the same precise constants when every argument is a numeric Constant. `foldable_constant_value?` widens to accept `Rational` / `Complex`, unblocking every catalog-tier `Rational#…` / `Complex#…` fold against constant receivers.
- **`Regexp` literal lift.** Non-interpolated `Prism::RegularExpressionNode` lifts to `Constant<Regexp>` (preserving source and option flags); interpolated regexes keep the conservative `Nominal[Regexp]`. Activates the new `Constant<String>#scan(/regex/)` fold path end-to-end.
- **Pathname delegation.** `Pathname` joins `Type::Constant::SCALAR_CLASSES`; `Pathname.new(Constant<String>)` lifts via a `MethodDispatcher#meta_new` constant-constructor table; a curated 14-method unary / 8-method binary fold table covers pure path manipulation (`to_s`, `basename`, `dirname`, `extname`, `cleanpath`, `+`, `join`, `<=>`, `==`, `relative_path_from`, …). Filesystem-touching methods (`exist?`, `file?`, `read`, `stat`, …) are intentionally NOT folded.

#### Constant<Range> precision

- **`to_a`** lifts to a per-position `Tuple[…]` for finite integer ranges (capped at 16 elements); **`first` / `last` / `min` / `max`** and **`count` / `size` / `length`** fold to precise `Constant<Integer>` values for the no-arg form, bypassing the catalog's `:block_dependent` classification of the optional-block variants.

#### Tuple precision (eleven new ShapeDispatch handlers)

- **`empty?` / `any?` / `all?` / `none?`** (no-block, no-arg) fold to `Constant[bool]` per the tuple's arity and element truthiness.
- **`include?(needle)`** folds to a precise bool when the needle is a `Constant` and the tuple's elements are all `Constant`.
- **`sum` / `min` / `max`** fold to numeric / comparable extremes for all-Constant elements.
- **`sort` / `reverse`** return per-position Tuples in the appropriate order.
- **`to_a`** returns the receiver Tuple unchanged.
- **`zip`** pairs the receiver's per-position elements with the per-position elements of each other Tuple-shaped argument; short other-Tuples pad with `Constant[nil]`; multi-arg `zip` produces wider per-position Tuples (capped at 8).

#### HashShape precision

- **`keys` / `values`** fold to per-position Tuples preserving declaration order.
- **`count` / `length`** match the existing `size` handler.
- **`empty?` / `any?`** (no-arg, no-block) fold to `Constant[bool]` per the shape's emptiness.
- **`first` / `flatten` / `compact`** for closed shapes with no optional keys: `first` returns the `[k, v]` 2-Tuple of the first pair; `flatten` produces the per-position `[k_1, v_1, k_2, v_2, …]` Tuple; `compact` drops every entry whose value is `Constant[nil]`.
- **Tuple ↔ HashShape conversions** — `Tuple#to_h`, `HashShape#to_a`, `HashShape#to_h`, `HashShape#invert` (Symbol-/String-valued shapes only), `HashShape#merge(other)` for closed-shape × closed-shape merges.

#### String precision

- **Format-string fold over `Tuple` / `HashShape` arguments.** `"%d / %d" % [1, 2]` folds to `Constant<"1 / 2">`; `"%{name} is %{age}" % {name: "Alice", age: 30}` folds to `Constant<"Alice is 30">`. Malformed format specs decline so the RBS tier widens.
- **Array-returning method lift.** `s.chars` / `s.bytes` / `s.lines` / `s.split` (no-arg, separator, or `Constant<Regexp>` pattern) / `s.scan` lift the resulting Array to a per-position `Tuple[Constant…]` when every element is a foldable scalar and the cardinality fits within 32. Larger results decline so the RBS tier widens.

#### Refinement narrowing

- **`~Refined[base, predicate]`** narrows through `Difference[base, refined]` instead of falling back to `current_type` unchanged. `assert value is ~lowercase-string` now narrows `String` to `Difference[String, lowercase-string]`. The De Morgan composition for Intersection refinements also tightens.

#### Empty literal carriers

- **`{}` → `HashShape{}`** mirrors the v0.0.6 empty-array literal change. The new HashShape projections fold against it.
- **`Array.new(n, value)` / `Array.new(n)`** lift to a per-position `Tuple[…]` when `n` is a small `Constant<Integer>` (capped at 16). Oversize `n` falls back to `Nominal[Array]`.

#### Pre-v0.1.0 substrate

- **`Rigor::Reflection` read-side facade** joins Rigor's three reflection sources (`ClassRegistry` + `RbsLoader` + `Scope` discovered facts) under one read API. Nine queries: `class_known?`, `class_ordering`, `nominal_for_name`, `singleton_for_name`, `constant_type_for` (in-source wins on collision with RBS), `instance_method_definition`, `singleton_method_definition`, `discovered_class?`, `discovered_method?`. Public read shape for v0.1.0 plugin-API readiness; spec at [`docs/internal-spec/reflection.md`](docs/internal-spec/reflection.md).
- **Reflection consumer migration.** Five engine-internal callers (`Analysis::CheckRules`, `Inference::Narrowing`, `Inference::StatementEvaluator`, `Inference::MethodDispatcher`, `Inference::MethodParameterBinder`, `Inference::MethodDispatcher::RbsDispatch`) move from raw `scope.environment.rbs_loader` access to the facade. The facade gains `rbs_class_known?`, `instance_definition` / `singleton_definition`, `class_type_param_names`, and an `environment:` kwarg variant for dispatcher call paths that don't have a `Scope` in scope. Mechanical refactor; no behaviour change.
- **v0.1.0 readiness design doc** at [`docs/design/20260505-v0.1.0-readiness.md`](docs/design/20260505-v0.1.0-readiness.md) — maps every ADR-2 surface to today's implementation, sequences the seven major pre-v0.1.0 work items, reconciles ADR-2's open questions, and lists the items that can land as v0.0.x dot releases.
- **Cache slice taxonomy design doc** at [`docs/design/20260505-cache-slice-taxonomy.md`](docs/design/20260505-cache-slice-taxonomy.md) — fixes the per-slot entry shapes (`FileEntry` with `:digest` / `:mtime` / `:exists` comparators, `GemEntry`, `PluginEntry`, `ConfigEntry`), composition rules, canonical cache-key derivation, granularity guidance, and schema versioning. Prerequisite contract for the persistence layer that ships in v0.1.0.

## [0.0.6] - 2026-05-05

The sixth preview. Theme: **fold block-taking Enumerable methods through the constant-folding tier** so iterator-shaped expressions over literal collections produce precise carriers instead of widening through RBS.

### Added

- **Block-shaped fold dispatch over constant-block predicates and filters.** Calls like `[1, 2, 3].select { false }`, `arr.all? { true }`, or `arr.any? { false }` collapse to the precise endpoint when the block's inferred return type is a Ruby-truthy or Ruby-falsey `Constant`. Filter methods (`select` / `filter` / `reject` / `take_while` / `drop_while`) fold to either the receiver or `Tuple[]`; predicate methods (`all?` / `any?` / `none?`) fold to `Constant[true]` / `Constant[false]` whenever the receiver-emptiness × block-truthiness combination is unconditional in Ruby's semantics, including the vacuous-truth empty-receiver cases. Receiver-emptiness is recognised against `Tuple`, `HashShape`, `Constant<Array|Hash|String|Range>`, and the imported `non-empty-array[T]` carrier (`Difference[Array, Tuple[]]`).
- **Per-position block re-evaluation over Tuple receivers** for `map` / `collect` / `filter_map` / `flat_map` / `find` / `detect` / `find_index` / `index`. The block body is type-checked once per Tuple position with the corresponding element bound to the block parameter, then assembled per-method:
  - `map` / `collect` produce `Tuple[U_1..U_n]`. `[1, 2, 3].map { |n| n.to_s }` resolves to `["1", "2", "3"]` instead of `Array["1" | "2" | "3"]`.
  - `filter_map` drops `Constant[nil]` / `Constant[false]` positions and concatenates the survivors into a Tuple.
  - `flat_map` concatenates per-position `Tuple` results, treating per-position `Constant` scalars as single-element contributions and declining on opaque carriers.
  - `find` / `detect` return the receiver element at the first truthy position (or `Constant[nil]` when every position is falsey).
  - `find_index` / `index` return the index of the first truthy position (or `Constant[nil]`). The value-search forms `index(value)` / `find_index(value)` decline so the RBS tier still owns those.
- **Per-position block fold over short `Constant<Range>` receivers** up to a cardinality cap of 8 elements. Each integer in the range re-types the block body once with the corresponding `Constant<Integer>` bound to the parameter, so `(1..3).map { |n| n.to_s }` resolves to `["1", "2", "3"]` and `(1..5).find { |n| n.even? }` resolves to `Constant[2]`. Larger ranges decline so the RBS tier widens, keeping block-typing cost bounded.
- **Branch elision for expression-position conditionals.** `if` / `unless` / ternary expressions whose predicate folds to a `Type::Constant` drop the unreachable branch and adopt the live branch's type. Statement-level branch elision was already present from v0.0.3; this slice covers expression-position uses (e.g. the right-hand side of an assignment, an argument expression, or a block body). Composes directly with the per-position fold, so `[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }` resolves to `Tuple[Constant["2"]]`.
- **`&&` / `||` short-circuit elision on Constant-shaped left operands.** When the left operand of `&&` / `||` folds to a `Type::Constant`, the result type follows Ruby's actual short-circuit semantics: `Constant[truthy] && rhs` is the right operand's type, `Constant[falsey] && rhs` keeps the left, and the dual rule applies for `||`. Non-Constant left operands keep the previous union-of-both-operands behaviour.
- **`find { false }` / `detect { false }` / `find_index { false }` / `index { false }` / `count { … }` short-circuit folds.** The block-form falsey side of the find-family folds to `Constant[nil]`; `count { false }` folds to `Constant[0]`; `count { true }` folds to `Constant[size]` when the receiver pins a finite size (Tuple, HashShape, or `Constant<Range>` with finite integer endpoints). The value-search forms `index(value)` / `count(value)` carry a positional argument and decline so the RBS tier still answers them.
- **IntegerRange-aware ternary fold — `Comparable#between?` / `Comparable#clamp`.** The 2-arg `try_fold_ternary` path now accepts an `IntegerRange` receiver paired with two scalar `Constant<Integer>` args. `int<3, 7>.between?(0, 10)` folds to `Constant[true]`; `int<3, 7>.clamp(4, 6)` folds to `int<4, 6>` (collapsing to a `Constant` when the intersection pins a single point). When the bracket is fully disjoint from the range — every receiver value would snap to one bracket bound — the fold declines so the RBS tier widens rather than the dispatcher inventing the snap point.
- **Empty array literal carrier — `[]` resolves to `Tuple[]`.** The empty array literal previously typed as `Nominal[Array]`; v0.0.6 switches it to the empty `Tuple[]` carrier so the per-element block fold can concatenate cleanly across all-empty positions like `[1, 2, 3].flat_map { |_| [] }` (now folds to `Tuple[]`). Both carriers erase to plain `Array` on the RBS-interop path.
- **Pathname catalog import.** `data/builtins/ruby_core/pathname.yml` (102 instance methods, 2 singletons, 5 aliases) and the matching `Builtins::PATHNAME_CATALOG` join the catalog tier. Pathname is a thin wrapper that mostly delegates to `File` / `Dir` / `FileTest`, so the user-visible payoff is narrower than Numeric or String — the import buys receiver-class recognition for `Pathname.new(...)`, a defensive `:initialize_copy` blocklist entry, and catalog folding for the lone `:leaf` method (`<=>`).

### Fixed

- **`tool/extract_builtin_catalog.rb` rescue-on-def classifier crash.** `PreludeParser#analyse_body` previously raised `NoMethodError` on Ruby methods written with the rescue-on-def idiom (`def foo; …; rescue; …; end`) because Prism wraps the body in a `BeginNode` rather than a `StatementsNode`. The classifier now descends into the begin-block's `statements` for that case. The bug surfaced importing Pathname (whose prelude has `def initialize(path); @path = …; rescue TypeError; …; end`); every catalog regenerates cleanly under `make extract-builtin-catalogs`.

## [0.0.5] - 2026-05-03

### Added

- **Rational and Complex built-in catalog imports.** New
  loaders `RATIONAL_CATALOG` and `COMPLEX_CATALOG` join the
  `CATALOG_BY_CLASS` table; the corresponding YAMLs under
  `data/builtins/ruby_core/{rational,complex}.yml` are
  generated from `references/ruby/{rational,complex}.c` via
  `tool/extract_builtin_catalog.rb`. Both classes are fully
  immutable in Ruby, so the per-class `mutating_selectors`
  blocklists carry only the conventional defence-in-depth
  `:initialize_copy` entry. Rigor today has no
  `Constant<Rational>` / `Constant<Complex>` literal lift
  (`Prism::ImaginaryNode` and `Rational(...)` /
  `Complex(...)` Kernel-call folding stay deferred), so the
  catalog wiring is currently a defensive surface — every
  fixture assertion goes through the RBS-tier projection on a
  `Nominal[<class>]` receiver. The blocklist becomes
  load-bearing once a future slice teaches the typer to lift
  these literals into `Constant<…>`.
- **`Const = Data.define(*Symbol)` discovery.**
  `Inference::ScopeIndexer.record_declarations` now
  registers `Const` (qualified by the surrounding class /
  module path) as a discovered class whose constant resolves
  to `Singleton[<qualified-name>]`. Previously
  `Const.new(...)` returned the un-narrowed `Dynamic[top]`
  envelope; with the constant registered, `meta_new` resolves
  it to a fresh `Nominal[<qualified-name>]`, and member
  accessors flow through the user-class fallback without
  false-positives. Both the bare form `Data.define(:x, :y)`
  and the block-override form
  `Data.define(:x, :y) do; def initialize(x:, y:); …; end end`
  are recognised; non-symbol arguments and non-`Data`
  receivers are rejected. Worked example: `Target` and
  `Fact` in `lib/rigor/analysis/fact_store.rb` now type as
  `singleton(Rigor::Analysis::FactStore::Target)` and
  `singleton(Rigor::Analysis::FactStore::Fact)` respectively.
- **`Kernel#Array` precision tier
  (`MethodDispatcher::KernelDispatch`).** A new
  precision-tier dispatcher folds `Array(arg)` into a precise
  `Array[E]` whenever the argument's value-lattice shape lets
  us prove the element type. The rules mirror Ruby's coercion
  contract — `Array(nil) -> []`, an existing `Array[E]`
  preserves its element, a Tuple materialises to
  `Array[T1|T2|…]`, and a Union distributes element-wise and
  unifies. Opaque shapes (Top / Dynamic / Bot) fall through to
  the existing RBS-tier envelope. Worked example: in
  `lib/rigor/analysis/fact_store.rb#fact_targets`,
  `Array(fact.target)` over `fact.target: Target |
  Array[Target]` previously typed as `Array[Dynamic[top]]`;
  it now types as `Array[Target]`.
- **Branch-aware scope propagation for expression-position
  conditionals.** `Inference::ScopeIndexer.propagate` now
  special-cases `Prism::IfNode` and `Prism::UnlessNode`,
  threading the predicate's narrowed truthy / falsey scopes
  into the corresponding branch subtrees. Previously, when
  an `if` / `unless` sat in expression position (e.g. as a
  call argument or the RHS of an `[]=`), the indexer never
  routed it through `eval_if`'s narrowing path, so inner
  nodes inherited the un-narrowed entry scope and downstream
  rules (`possible-nil-receiver`, type-of probes) saw
  spurious `T | nil`. Worked example:
  `cache[k] = if x; x.foo; else; default; end` now sees `x`
  narrowed to its non-nil fragment inside the truthy branch,
  matching the behaviour for the statement-level form
  `if x; cache[k] = x.foo; else; cache[k] = default; end`.
  Specs at
  `spec/rigor/inference/scope_indexer_spec.rb#narrows IfNode
  branches when the conditional sits in expression position`
  (and the `UnlessNode` mirror) bind both shapes.
- **`RbsLoader#instance_definition` /
  `#singleton_definition` now declared as `untyped?`.** The
  earlier sig form (`untyped`) was a workaround for the
  truthy-narrowing gap above; with that gap closed, the sig
  can faithfully reflect the impl's `nil`-on-unknown-class
  return contract.
- **Two-argument constant-fold dispatch.**
  `MethodDispatcher::ConstantFolding#try_fold` previously
  switched on `args.size` and only handled the 0- and 1-arg
  shapes; 2-arg leaf methods like `Comparable#between?(min,
  max)`, the explicit-bounds form of `Comparable#clamp(min,
  max)`, and `Integer#pow(exp, mod)` all bailed to the
  RBS-widened tier. The dispatch now grows a `when 2` arm
  routed through `try_fold_ternary`, which folds the cartesian
  product of receiver × arg0 × arg1 when every operand is a
  `Constant` (or `Union[Constant…]`) and the catalog
  classifies the method `:leaf` / `:trivial`. The same
  `UNION_FOLD_INPUT_LIMIT` cap that gates the binary path
  guards the cartesian explosion. IntegerRange operands are
  reserved for a follow-up — any range receiver or arg short-
  circuits the ternary path so the RBS tier still answers.
  Worked examples: `5.between?(0, 10)` folds to
  `Constant[true]`, `100.clamp(0, 10)` folds to
  `Constant[10]`, `100.pow(50, 17)` folds to `Constant[4]`.
  Direct payoff for the just-landed include-aware lookup:
  `between?` was the canonical 2-arg method blocked by the
  arity gate. End-to-end fixture:
  `spec/integration/fixtures/two_arg_fold.rb`.
- **`tool/catalog_diff.rb` + `make catalog-diff`.** Prints the
  surface-level diff between two
  `data/builtins/ruby_core/<topic>.yml` snapshots — per-class
  additions / removals / purity changes / cfunc renames /
  arity changes. The motivating use is a `references/ruby`
  submodule bump where the full YAML diff is noisy because it
  interleaves prose comments, RBS pulls, and `defined_at` line
  numbers; this tool extracts the catalog-semantic deltas a
  reviewer has to look at. Default invocation:
  `make catalog-diff BEFORE=… AFTER=…`.
- **C-body classifier detects pure `rb_check_frozen` wrappers
  as mutators.** Per-class wrappers like `time_modify(time)` /
  `time_gmtime(time)` whose entire body is one or more
  `rb_check_frozen(...)` calls used to be classified `:leaf`
  even though they centralise the mutation gate of the
  receiver. `CBodyIndex#mutator_helpers` now returns the set
  of indexed cfuncs whose body matches the pure-frozen-check
  pattern, and `CBodyClassifier.classify` flips the `:mutate`
  effect on when a method calls one of those helpers. The
  pattern is intentionally narrow — naive transitive
  propagation over-flagged legitimate non-mutators like
  `Array#to_a`, so only bodies that consist solely of
  `rb_check_frozen` calls qualify. Re-extraction flips two
  Time methods (`#gmtime`, `#utc`, both bound to `time_gmtime`)
  from `:leaf` to `:mutates_self`; every other catalog
  regenerates byte-identically.
- **Include-aware module-catalog fallthrough activates the
  Comparable / Enumerable imports.**
  `MethodDispatcher::ConstantFolding#catalog_allows?` walks the
  receiver class's `Module#ancestors` and consults the
  imported module catalogs (`COMPARABLE_CATALOG`,
  `ENUMERABLE_CATALOG`) when the primary class catalog has no
  entry for the method. Resolution: primary class catalog
  first (its `rb_define_method` registration is authoritative
  even when the entry is classified `:dispatch`), module
  catalogs only when the primary has no entry. The user-visible
  payoff: methods that come purely from an `include Comparable`
  / `include Enumerable` mixin without a direct
  `rb_define_method` registration now fold. Worked example:
  `5.clamp(0..10)` folds to `Constant[5]`,
  `100.clamp(0..10)` folds to `Constant[10]`. `Comparable#between?`
  and Enumerable's block-shaped methods need the dispatch
  tier's two-arg / block-parameter paths and remain unfolded
  (tracked as a follow-up). End-to-end fixture:
  `spec/integration/fixtures/include_aware_clamp.rb`.
- **Comparable and Enumerable module catalog imports.** New
  `data/builtins/ruby_core/comparable.yml` and
  `enumerable.yml` generated by
  `tool/extract_builtin_catalog.rb` from `Init_Comparable`
  (compar.c) and `Init_Enumerable` (enum.c). Catalog stats:
  Comparable ships with 7 instance methods (the `<`/`<=`/`==`/
  `>=`/`>`/`between?`/`clamp` family); Enumerable ships with 58
  instance methods (47 `:block_dependent`, 9 `:leaf`, 2
  `:mutates_self`). The matching `Builtins::COMPARABLE_CATALOG`
  / `Builtins::ENUMERABLE_CATALOG` singletons are loaded at
  boot but NOT registered in
  `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS` because
  modules are not receiver classes the dispatcher routes
  through; the data is in place for a future include-aware
  lookup that walks the receiver's ancestor chain.
- **`tool/scaffold_builtin_catalog.rb --module`.** The scaffold
  script gains a module mode that skips the
  `CATALOG_BY_CLASS` row, the fixture stub, and the
  integration `describe` block — none of those make sense
  until include-aware dispatch ships. The loader file gets a
  module-aware banner; the require_relative is still inserted
  so the singleton is reachable. The associated extractor
  upgrade (`MODULE_DEFINE_RE`) recognises
  `rb_mFoo = rb_define_module("Foo");` registrations and
  records modules in the per-topic `classes` map with
  `parent: "Module"`. Two previously-dropped module
  registrations (`FileTest` in Init_File, `UnicodeNormalize`
  in Init_String) now surface as empty-bucket class entries
  in their respective YAMLs.
- **`~refinement` negation extends to IntegerRange and
  Intersection.** `Narrowing.narrow_not_refinement` previously
  only handled `Difference[base, Constant[v]]`; the algebra
  now covers two more carrier kinds:
  - `Type::IntegerRange[a, b]` — complement is the two open
    halves `int<min, a-1>` and `int<b+1, max>`, each
    intersected with the integer-domain parts of
    `current_type`. Non-integer parts of a Union receiver
    survive unchanged. `assert n is ~int<5, 10>` over
    `n: Integer` narrows to `int<11, max> | int<min, 4>`.
    End-to-end fixture:
    `spec/integration/fixtures/assert_negation_integer_range/`.
  - `Type::Intersection[M1, M2, …]` — De Morgan: `D \ (M1 ∩
    M2) = (D \ M1) ∪ (D \ M2)`. Each member's complement is
    computed independently and unioned; members the algebra
    cannot complement (Refined, non-Constant Difference)
    contribute `current_type` itself, so the union may widen.
    `~non-empty-lowercase-string` over `String` therefore
    yields `Constant[""] | Nominal[String]` rather than the
    tighter `Constant[""]` we'd get with predicate-aware
    complement. `Refined[base, predicate]` keeps its
    conservative `current_type` answer (predicate complements
    are not finite-carrier-expressible).
- **`~refinement` negation in `assert:` / `predicate-if-*:`
  directives.** The `<target> is <RHS>` right-hand side now
  accepts the `~T` negation prefix on the refinement arm in
  addition to the existing class-name arm. The narrowing tier
  introduces `Narrowing.narrow_not_refinement` for the
  Difference + Constant-removed shape: it walks the current
  type's union members, keeps each part disjoint from the
  refinement's base, and adds the removed-value Constant
  exactly once when any current member covers it.

  ```rbs
  class Validator
    %a{rigor:v1:assert value is ~non-empty-string}
    def assert_empty!: (::String value) -> void
  end
  ```

  After `v.assert_empty!(name)` over `name: String | nil`, the
  narrowed type is `Constant[""] | NilClass` — the only
  inhabitants of the original union that are NOT non-empty
  strings. Other refinement carriers (`Refined`, `Intersection`,
  `IntegerRange`, and `Difference` whose removed is not a
  Constant) return `current_type` unchanged for now;
  predicate-complement and bounded-range complement are
  follow-up slices. End-to-end fixture:
  `spec/integration/fixtures/assert_negation_refinement/`.
- **`group_by` / `partition` / `each_slice` / `each_cons`
  block-parameter projections (placeholder; future plugin).**
  RBS already binds these methods correctly for plain
  `Array[T]` / `Set[T]` / `Range[T]` receivers via generic
  substitution; the new IteratorDispatch arms exist so Tuple-
  and HashShape-shaped receivers reach the block body with the
  precise per-position element union (or `Tuple[K, V]` pair)
  rather than the projected `Array[union]` widening.
  `group_by` / `partition` yield a single element; `each_slice`
  and `each_cons` yield `Array[element]` (the slice-size
  argument is ignored at the dispatcher tier — a tighter
  Tuple-of-`n` carrier is reserved for the plugin tier). The
  scope is intentionally narrow — the longer-term direction is
  to move Enumerable-aware projections into a plugin tier
  modelled after PHPStan's extension API (ADR-2). The
  placeholder rules will be reimplemented and removed once the
  plugin surface ships. Self-asserting fixture:
  `spec/integration/fixtures/enumerable_collect.rb`.
- **Memo-typed Enumerable block-parameter projections.**
  `IteratorDispatch` covers `#each_with_object` (yields
  `(element, memo)` where the memo type follows the second
  argument's actual type) and `#inject` / `#reduce` (yields
  `(memo, element)`). The inject family handles three call
  shapes:
  - `inject(seed) { |memo, elem| … }` — `[seed_type, element_type]`.
  - `inject { |memo, elem| … }` — both block params bind to the
    receiver's element type (Ruby's first-element-as-memo
    semantics).
  - `inject(:+)` / `inject(seed, :+)` — Symbol-call forms have
    no block; the dispatcher recognises and declines.

  Self-asserting fixture: `spec/integration/fixtures/enumerable_memo.rb`.
- **Date / DateTime catalog import.** New `data/builtins/ruby_core/date.yml`
  generated from `Init_date_core` in
  `references/ruby/ext/date/date_core.c` plus the `lib/date.rb`
  prelude. Both classes land in a single topic — DateTime
  inherits from Date and the same Init function registers both,
  so `tool/extract_builtin_catalog.rb` carries one entry with two
  RBS bindings (`date.rbs`, `date_time.rbs`). Catalog stats:
  2 classes, 96 instance methods, 60 singleton methods,
  149 `:leaf` / 2 `:mutates_self` / 3 `:block_dependent`
  classifications. The blocklist in
  `lib/rigor/inference/builtins/date_catalog.rb` covers
  `:initialize_copy` (defensive symmetry with String / Array /
  Range / Set / Time) and Date's `#ifndef NDEBUG`-only `:fill`
  helper, plus a mirrored `:initialize_copy` entry for the
  DateTime side. `MethodDispatcher::ConstantFolding` routes
  `Date` and `DateTime` receivers through the new
  `DATE_CATALOG`; the DateTime row precedes Date in
  `CATALOG_BY_CLASS` so subclass receivers hit their dedicated
  entry first. Self-asserting fixture
  `spec/integration/fixtures/date_catalog/` exercises the
  Integer-typed reader surface (`#year` / `#month` / `#day` /
  `#wday` / `#hour` / `#min` / `#sec`), the boolean predicate
  surface (`#leap?` / `#julian?` / `#sunday?`), the String-typed
  formatters (`#to_s` / `#iso8601` / `#strftime`), and the
  navigation methods (`#next_day` / `#prev_day` / `#next_month` /
  `#prev_year` / `#succ` / `#>>` / `#<<`) that return brand-new
  Date objects rather than mutating the receiver. No
  `RBS::Extended rigor:v1:return:` overrides this slice — the
  reader surface is in the same situation as Time, where
  per-method ranges (`#month` ∈ `int<1, 12>`) would need a
  parameterised IntegerRange overlay that's out of scope.

### Fixed

- **Cross-line block comments in `tool/extract_builtin_catalog.rb`.**
  `CInitParser#join_continuations` walks the Init function body
  line by line and tracks paren depth to merge multi-line
  registration macros into a single logical line. The previous
  `strip_line_comments` helper only stripped `/* … */` runs that
  fit on one line, so multi-line rdoc blocks (very common above a
  `rb_define_class` call — `cDateTime = rb_define_class("DateTime", cDate);`
  in `date_core.c` is preceded by a 200-line `/* … */` block)
  contributed unbalanced parens to the depth counter and made the
  next code line merge into a comment buffer. The fix
  pre-strips block comments from the entire C source while
  preserving newlines so per-line indexing remains valid. Without
  the fix DateTime's class-registration line was silently dropped
  and the catalog only saw `Date`.

## [0.0.4] - 2026-05-02

The fourth preview. Theme: **finish the OQ3 refinement-carrier
strategy and broaden the RBS::Extended directive surface**.

The OQ3 carrier triple (`Type::Difference` from v0.0.3 plus the
new `Type::Refined` and `Type::Intersection`) is feature-complete
against the imported-built-in catalogue ([`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md)),
so authors can express the full set of refinement names from
`%a{rigor:v1:…}` annotations and the analyzer projects them
through method dispatch, acceptance, and the `argument-type-mismatch`
check rule symmetrically.

The `RBS::Extended` directive surface picks up `rigor:v1:param:`
(both at the call boundary and inside the method body via
`MethodParameterBinder`) and the existing `assert*` /
`predicate-if-*` family now accepts refinement payloads on the
right-hand side.

The built-in catalog import pipeline gains four more classes
(Hash / Range / Set / Time) plus a `tool/scaffold_builtin_catalog.rb`
script that automates the mechanical 70 % of each new import.

Test count: 1148 → 1250 examples (+102), RuboCop clean,
`bundle exec exe/rigor check lib` reports 0 diagnostics.

### Added

#### OQ3 refinement carriers

- **`Type::Refined` carrier (predicate-subset half).** Sibling
  of `Type::Difference`. Wraps `(base, predicate_id)` where
  `predicate_id` is a Symbol drawn from
  `Type::Refined::PREDICATES`. Construction goes through
  `Type::Combinator.refined(base, predicate_id)` and the
  per-name factories listed below. RBS erasure folds the carrier
  back to its base nominal. Gradual-mode acceptance mirrors the
  conservative `accepts_difference` policy — same-predicate
  `Refined` plus recognised `Constant` values get `:yes`, every
  other shape gets `:no`.
- **`Type::Intersection` carrier — composed refinement names.**
  Closes the OQ3 carrier strategy by adding the Intersection
  peer alongside `Union` / `Difference` / `Refined`. The carrier
  represents the meet of its members' value sets. Construction
  performs the deterministic normalisation in
  `docs/type-specification/value-lattice.md` —
  flatten / drop-Top / Bot-absorb / dedupe / sort / 0-1 collapse
  — so two equal intersections compare equal regardless of
  construction order. Acceptance is conjunctive on the LHS and
  disjunctive on the RHS, plus a top-level structural-equality
  short-circuit. `ShapeDispatch.dispatch_intersection` combines
  per-member projections through an IntegerRange meet when every
  result is bounded-integer, so `(non_empty_string ∩
  lowercase_string).size` resolves to `positive-int` rather than
  the looser `non-negative-int`.
- **Fourteen imported built-in refinement names.** All resolvable
  through `Builtins::ImportedRefinements` (and through the
  per-name factories on `Type::Combinator`):
  - **Point-removal** (already in v0.0.3): `non-empty-string`,
    `non-zero-int`, `non-empty-array[T]`, `non-empty-hash[K, V]`.
  - **IntegerRange aliases** (already in v0.0.3): `positive-int`,
    `non-negative-int`, `negative-int`, `non-positive-int`.
  - **Predicate** (new): `lowercase-string`, `uppercase-string`,
    `numeric-string`, `decimal-int-string`, `octal-int-string`,
    `hex-int-string`. The base-N int-string predicates are
    disjoint by design — `:octal_int` and `:hex_int` REQUIRE
    their conventional prefix (`0o` / `0O` / leading `0`;
    `0x` / `0X`), so a bare `"755"` is `decimal-int-string`,
    not `octal-int-string`.
  - **Composed Intersection** (new):
    `non-empty-lowercase-string`, `non-empty-uppercase-string`.
- **Catalog-tier projections over `Refined[String, …]`.**
  `String#downcase` / `String#upcase` fold per predicate:
  case-fold idempotence for `:lowercase` / `:uppercase` /
  `:numeric` and the three base-N int-string predicates, plus
  the lift `lowercase ↔ uppercase` for the cross calls. Size-tier
  projections still apply through the predicate carrier so
  `String#size` over a `Refined[String, *]` tightens to
  `non-negative-int`.
- **Self-asserting fixtures.** `predicate_refinement/`,
  `intersection_refinement/`, `parameterised_refinement/`, plus
  the existing `refinement_return_override/` from v0.0.3.

#### `RBS::Extended` directive surface

- **`rigor:v1:return:` accepts parameterised refinement payloads.**
  In addition to the bare-name shapes, the directive now accepts
  `non-empty-array[T]` / `non-empty-hash[K, V]` (type-arg payloads
  where `T` / `K` / `V` may be a kebab-case refinement name or a
  Capitalised RBS class name) and `int<min, max>` (bounded-integer
  range with signed integer literals). Parsing lives in a new
  `Builtins::ImportedRefinements::Parser` recursive-descent parser
  exposed through `ImportedRefinements.parse(payload)`. Failure is
  fail-soft — any parse miss returns nil and the directive site
  falls back to the RBS-declared type.
- **`rigor:v1:param: <name> [is] <refinement>` directive.**
  Symmetric to the `return:` route landed in v0.0.3 and
  feature-complete on both sides of the method boundary:
  - **Call-site half.** `OverloadSelector` and the
    `argument-type-mismatch` check rule consult
    `RbsExtended.param_type_override_map(method_def)` and prefer
    the override over the RBS-translated type so a too-wide call
    site is flagged.
  - **Body-side half.** `MethodParameterBinder` reads the same
    override map and replaces the RBS-translated parameter
    binding with the refinement, so projections through the
    carrier (e.g. `id.size` resolving to `positive-int` over a
    `non-empty-string` parameter) are observable inside the
    method body during inference.

  The optional `is` glue word matches the existing
  `assert` / `predicate-if-*` surface; authors MAY write
  `param: id non-empty-string` instead. End-to-end fixture:
  `spec/integration/fixtures/param_extended/`.
- **`rigor:v1:assert:` and `rigor:v1:predicate-if-*:` accept
  refinement payloads.** The `<target> is <RHS>` right-hand side
  now matches either a Capitalised class name (existing
  behaviour) or a kebab-case refinement payload. Both
  `AssertEffect` and `PredicateEffect` gain a `refinement_type`
  field; the narrowing tier substitutes the carrier when
  present, keeping the legacy `narrow_class` path for class-name
  directives. Refinement-form directives do not yet support
  `~T` negation — that would require a
  difference-against-refinement algebra and is reserved for a
  future slice.

#### CLI / display

- **CLI `type-of` confirms the kebab-case canonical-name
  contract.** New regression specs in `spec/rigor/cli_spec.rb`
  drive `bundle exec exe/rigor type-of` through the harness over
  both a `Difference`-backed refinement (`non-empty-string`) and
  `Refined`-backed refinements (`lowercase-string`,
  `numeric-string`), and assert that human-readable text and
  `--format=json` output both render the refinement in its
  kebab-case spelling while erasure folds back to the base
  nominal.

#### Built-in catalog imports

- **`Hash` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/hash.yml` is generated from
  `references/ruby/hash.c`. `Builtins::HASH_CATALOG` consumes
  it; the constant-fold dispatcher routes Hash receivers
  through it. Pure readers (`size` / `[]` / `include?` /
  `dig` / `invert` / `compact` / …) clear the catalog tier;
  block-yielding helpers that the C-body classifier mis-flags
  as `:leaf` (`each` / `select` / `transform_values` / `merge`,
  …) are blocklisted.
- **`Range` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/range.yml` covers 30 instance
  methods. Methods that fold today on a `(begin..end)` literal
  include `#begin`, `#end`, `#size`, `#exclude_end?`,
  `#include?`, `#cover?`, `#member?`. The block-iterating
  surface (`#each`, `#step`, `#first`, `#min`, `#max`,
  `#minmax`, `#count`) classifies as `block_dependent` and is
  blocked by the foldable-purity check. The Range slice also
  taught `tool/extract_builtin_catalog.rb` to recognise
  `rb_struct_define_without_accessor` so future struct-defined
  topics become drop-in additions.
- **`Set` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/set.yml` is generated from
  `Init_Set` in `references/ruby/set.c` (Set was rewritten in
  C and folded into CRuby for Ruby 3.2+). Per-class blocklist
  drops false-positive `:leaf` classifications for the
  indirect mutators (`initialize_copy`, `compare_by_identity`,
  `reset`), the block-yielding helpers (`each`, `classify`,
  `divide`), and `disjoint?`.
- **`Time` joins the catalog-driven inference pipeline.**
  `data/builtins/ruby_core/time.yml` is generated from
  `Init_Time` in `references/ruby/time.c` plus the
  `references/ruby/timev.rb` prelude (compiled into
  `timev.rbinc` and `#include`d at the bottom of `time.c`); the
  prelude path carries `Time.now` / `Time.at` / `Time.new` into
  the singleton-method bucket. The catalog records 58 instance
  methods (48 `:leaf`, 8 `:dispatch`, 3 `:mutates_self`, 3
  `:unknown`), 4 singleton methods, and the
  `iso8601` ↔ `xmlschema` alias. Per-class blocklist catches
  `localtime` / `gmtime` / `utc` (all call `time_modify(time)` to
  mark the receiver mutable but the C-body classifier mis-flags
  them `:leaf`).

#### Enumerable-aware projections

- **`#each_with_index` block-parameter typing.**
  `IteratorDispatch` generalises beyond Integer iteration to
  project the element type per receiver shape (Array / Set /
  Range nominals, Tuple, HashShape, Hash nominal,
  Constant<Array>, Constant<Range>) and tightens the index slot
  to `non-negative-int` over the RBS-declared `Integer`.
  Self-asserting fixture: `spec/integration/fixtures/each_with_index.rb`.

#### Tooling

- **`tool/scaffold_builtin_catalog.rb`.** Automates the
  mechanical 70 % of a new built-in catalog import: writes the
  TOPICS entry, the optional `BASE_CLASS_VARS` row, the loader
  file with a TODO blocklist marker, the `CATALOG_BY_CLASS` row
  + `require_relative`, the integration fixture stub, and the
  describe block. Manual follow-ups (blocklist curation,
  fixture body, CHANGELOG bullet) are printed as a checklist on
  exit. `--dry-run` previews the planned edits;
  `--init-fn` / `--rbs` / `--rb-prelude` override defaults for
  upstream layouts that diverge. Documented as Stage 0 of the
  `rigor-builtin-import` skill.

### Changed

- **`MethodDispatcher::ConstantFolding#catalog_for` is table-
  driven.** A `CATALOG_BY_CLASS` array of
  `(receiver_class, [catalog, class_name])` pairs replaces the
  growing `case` statement. Adding a class catalog is now a
  one-line addition rather than another `when` arm, and the
  dispatcher's cyclomatic complexity stays bounded as the
  catalogue grows.

### Fixed

- **`accepts_nominal` projects refinement carriers to base.** A
  Nominal accepting a `Difference` or `Refined` previously fell
  through to `:no` because `accepts_nominal`'s case statement had
  no branch for refinement kinds. The carrier's value set is
  contained in its base nominal's, so projecting to `other.base`
  and re-running acceptance is sound — a latent bug surfaced
  while wiring the Intersection conjunction.
- **`provably_disjoint_from_removed?` for nested Difference.**
  `Difference[A, R].accepts(Difference[B, R])` previously
  required the inner difference's BASE to be provably disjoint
  from `R`, which never holds (a Nominal base contains the
  removed value by construction). Same-`removed` now suffices
  because the disjointness is exhibited at the inner difference
  layer.

## [0.0.3] - 2026-05-02

The third preview. v0.0.3 makes the inference engine "see literal
values where it can prove them" across a far wider surface than
v0.0.2: aggressive constant folding (unary + binary + Union[Constant]
cartesian + integer-range arithmetic + Tuple-shaped divmod), a
PHPStan-style imported-built-in refinement carrier
(`non-empty-string`, `positive-int`, `non-zero-int`,
`non-empty-array[T]`, `non-empty-hash[K, V]`, `negative-int`,
`non-positive-int`, `non-negative-int`), an extracted built-in
method catalog driving the fold dispatcher (Numeric / String /
Symbol / Array / IO / File auto-extracted from CRuby), iterator-
block-parameter typing, scope-level integer-range narrowing,
case/when range narrowing, an `always-raises` diagnostic for
provable Integer division-by-zero, and end-to-end opt-in of the
new refinement carrier through `RBS::Extended`'s new
`rigor:v1:return:` directive.

The robustness principle (Postel's law for types — strict on
returns, lenient on parameters) is now a normative section of the
type specification with ADR-5 as the design rationale.

### Added

- **Aggressive constant folding through user methods.**
  `Rigor::Inference::MethodDispatcher::ConstantFolding` invokes
  the real Ruby method on `Constant` receivers and arguments
  whenever the method is in a curated allow-list, the operation
  cannot raise on the receiver's domain, and the result is a
  scalar that round-trips through `Type::Combinator.constant_of`.
  Combined with inter-procedural inference (v0.0.2 #5):

  ```ruby
  class Parity
    def is_odd(n) = n.odd?
  end
  Parity.new.is_odd(3)   # was `false | true` in v0.0.2
                         # is now `Constant[true]`
  ```

- **Cartesian fold over `Union[Constant…]`.** Binary arithmetic
  and comparison fold pairwise across Union receivers and
  arguments, deduplicate, and rebuild a precise `Union[Constant…]`
  result. Bounded by `UNION_FOLD_INPUT_LIMIT = 32` and
  `UNION_FOLD_OUTPUT_LIMIT = 8`; when the output cap is exceeded
  for an Integer-only result set, the analyzer gracefully widens
  to the bounding `IntegerRange[min, max]` instead of giving up.

- **`Type::IntegerRange` carrier and range arithmetic.** PHPStan-
  style `int<min, max>` family with named aliases `positive-int`
  (`1..`), `non-negative-int` (`0..`), `negative-int` (`..-1`),
  `non-positive-int` (`..0`), and `int<a, b>`. Erases to
  `Integer` in RBS. Binary `+`, `-`, `*`, `/`, `%` and unary
  `succ` / `pred` / `abs` / `-@` / `even?` / `odd?` /
  `bit_length` / `zero?` / `positive?` / `negative?` all fold
  precisely. Single-point intersections (`int<5, 5>`) collapse
  to `Constant[5]`.

- **Scope-level range narrowing through comparisons and
  predicates.** `if x > 0 ... end` narrows `x` to `positive-int`
  on the truthy edge, `non-positive-int` on the falsey edge.
  Same for `<`, `<=`, `>=`, the reversed forms (`0 < x`),
  `x.positive?` / `x.negative?` / `x.zero?` / `x.nonzero?`, and
  `x.between?(a, b)`. The narrowing intersects with an existing
  `IntegerRange` bound when one is already in scope.

- **`case/when` integer-range narrowing.** `case n when 1..10
  then …` narrows `n` to `int<1, 10>` inside the body;
  `when 1...10` narrows to `int<1, 9>` (exclusive end);
  `when (100..)` narrows to `int<100, max>`; `when (..-1)`
  narrows to `negative-int`; `when 0` narrows to `Constant[0]`.

- **Iterator block-parameter typing.** `5.times { |i| … }` types
  `i` as `int<0, 4>`; `1.times { |i| … }` collapses to
  `Constant[0]`; `3.upto(7) { |i| … }` and `7.downto(3)
  { |i| … }` both type `i` as `int<3, 7>`. Wider Integer
  receivers (`Nominal[Integer]`, `positive-int`) fall back to
  `non-negative-int`.

- **Branch elision on provably-truthy/falsey predicates.**
  `if 4.even? ; :even ; else ; :odd ; end` resolves to
  `Constant[:even]` only — the dead branch is skipped — when
  the predicate's narrow_truthy / narrow_falsey collapses one
  side to `Bot`. `Constant[true]` / `Constant[false]` /
  `Nominal[Integer]` (always truthy) all qualify; `Union[true,
  false]` keeps both branches active as before.

- **`Tuple`-shaped `Integer#divmod` / `Float#divmod` folds.**
  `5.divmod(3)` lifts to `Tuple[Constant[1], Constant[2]]` so
  multi-target destructuring threads the per-slot type into
  locals (`q, r = 11.divmod(4)` binds `q: 2`, `r: 3`).
  Float / mixed Integer-Float divmod produces a mixed
  `Tuple[Constant<Integer>, Constant<Float>]`.

- **Built-in method catalog extraction pipeline.**
  `tool/extract_builtin_catalog.rb` parses CRuby's
  `Init_<Topic>` blocks (Numeric / Integer / Float / String /
  Symbol / Array / IO / File), classifies each cfunc body
  statically (leaf / leaf-when-numeric / dispatch /
  block-dependent / mutates-self / raises / unknown), and
  joins the result with the matching `references/rbs/core/*.rbs`
  signatures. Output lives at `data/builtins/ruby_core/<topic>.yml`
  (regenerated via `make extract-builtin-catalogs`). Generated
  YAML ships with the gem.

  `Rigor::Inference::Builtins::NumericCatalog` /
  `STRING_CATALOG` / `ARRAY_CATALOG` consume the catalogs at
  runtime and gate the constant-fold dispatcher on
  per-method purity. Per-class blocklists guard against
  classifier false positives (the C-body regex does not
  follow indirect mutators like `rb_str_replace` →
  `str_modifiable`); bang-suffixed selectors are universally
  blocked.

  Folds unlocked in v0.0.3 include: `Integer#**`, `&`, `|`,
  `^`, `<<`, `>>`, `===`, `div`, `fdiv`, `modulo`,
  `remainder`, `pow`; `Float#**`; `String#[]`, `include?`,
  `start_with?`, `end_with?`, `index`, `count`, `inspect`;
  `Symbol#length`, `empty?`, `casecmp?`.

- **`Type::IntegerRange` returns from container `#size` /
  `#length` / `#bytesize`.** `Nominal[Array]#size`,
  `Nominal[String]#length`, `Nominal[Hash]#size`,
  `Nominal[Set]#size`, `Nominal[Range]#size` now return
  `non_negative_int` instead of the RBS-declared `Integer`.
  Composes with the comparison-narrowing tier so `if
  arr.size > 0` narrows the local to `positive-int` and
  `arr.size - 1` evaluates as `non-negative-int`.

- **`File` path-manipulation folding (opt-in).**
  `File.basename`, `#dirname`, `#extname`, `#join`,
  `#split`, `#absolute_path?` over `Constant<String>`
  arguments fold to a precise `Constant` (or
  `Tuple[Constant, Constant]` for `split`) when
  `fold_platform_specific_paths: true` is set in
  `.rigor.yml`. Default mode is platform-agnostic — these
  methods read `File::SEPARATOR` / `ALT_SEPARATOR` and would
  otherwise bake the analyzer-host's platform into the
  inferred type — so the RBS tier answers with
  `Nominal[String]` / `Tuple[String, String]` / `bool`.
  Single-platform projects opt in for the precision payoff;
  cross-platform projects keep the safe envelope.

- **`Type::Difference` carrier (OQ3 point-removal half).**
  `Difference[base, removed]` represents `base` minus a
  finite removed value set, the structural primitive every
  imported-built-in refinement of the "non-empty / non-zero /
  non-empty-array / non-empty-hash" family uses. Acceptance
  is conservative: only `Constant` and same-removed
  `Difference` candidates can be proved disjoint from the
  removed set, so `Difference[String, ""].accepts(Nominal[String])`
  correctly returns `no` (the wider Nominal could be `""`).
  `MethodDispatcher::ShapeDispatch` projects the
  empty-removal case directly: `nes.size` →
  `positive-int`, `nes.empty?` → `Constant[false]`,
  `nzi.zero?` → `Constant[false]`. Erases to the base
  nominal in RBS.

- **`Rigor::Builtins::ImportedRefinements` registry.** Maps
  every imported-built-in kebab-case name
  (`non-empty-string`, `non-zero-int`, `non-empty-array`,
  `non-empty-hash`, `positive-int`, `non-negative-int`,
  `negative-int`, `non-positive-int`) to its Rigor type
  carrier. Single integration point for `RBS::Extended` and
  for future tokeniser slices.

- **`rigor:v1:return:` `RBS::Extended` directive.** Overrides
  a method's RBS-declared return type with one of the
  imported-built-in refinements. Annotation in the sig
  file:

  ```rbs
  class User
    %a{rigor:v1:return: non-empty-string}
    def name: () -> String

    %a{rigor:v1:return: positive-int}
    def age: () -> Integer
  end
  ```

  At call sites the override propagates: `User.new.name.size`
  is `positive-int`, `User.new.name.empty?` is
  `Constant[false]`, `User.new.age.zero?` is
  `Constant[false]`. The RBS erasure stays at the base
  nominal so the round-trip to ordinary RBS is unaffected.
  Unknown refinement names degrade to the RBS-declared
  return (silent miss, no crash).

- **`always-raises` diagnostic rule.** `5 / 0`, `5 % 0`,
  `5.div(0)`, `5.modulo(0)`, `5.divmod(0)`, and
  `rand(100) / 0` all surface as `:error` diagnostics under
  rule `always-raises` ("always raises ZeroDivisionError").
  Float arithmetic (`5.0 / 0` returns `Infinity`) and
  `Integer#fdiv(0)` stay silent. Suppressible per-line via
  `# rigor:disable always-raises`.

- **Implicit-self calls prefer in-source `def` over RBS dispatch.**
  When `node.receiver` is nil (true implicit self) and the
  file has a same-named top-level `def` (or DSL-block-nested
  `def`, e.g. inside `RSpec.describe ... do ... end`), the
  engine routes through inter-procedural inference on that
  body before consulting the receiver class's RBS. When the
  local def's parameter shape is too complex for the binder
  (kwargs / optionals / rest), the engine returns
  `Dynamic[Top]` instead of falling through to (incorrect)
  RBS dispatch.

- **RSpec matcher narrowing.** The engine recognises a
  small catalogue of RSpec matcher patterns as
  assert-shaped narrows on the local passed to
  `expect(...)`. `expect(x).not_to be_nil` /
  `expect(x).to_not be_nil` drop `NilClass` from `x`'s
  type; `expect(x).to be_a(C)` / `be_kind_of(C)` narrow `x`
  to `C` (subtype-permitting); `be_an_instance_of(C)` /
  `be_instance_of(C)` narrow exactly. Pattern matching is
  purely AST-shape — no RBS for RSpec is required.

- **`fold_platform_specific_paths` configuration option.**
  Boolean in `.rigor.yml`, default `false`. Enables File
  path-manipulation folds (see above) for projects that
  target a single platform.

- **Robustness principle (Postel's law) for types.** New
  ADR ([`docs/adr/5-robustness-principle.md`](docs/adr/5-robustness-principle.md))
  and normative spec section
  ([`docs/type-specification/robustness-principle.md`](docs/type-specification/robustness-principle.md))
  document the asymmetric authorship rule: Rigor-authored
  return types should be as strict as can be proved;
  Rigor-authored parameter types should be as permissive as
  the body's correct behaviour permits. Hand-written RBS
  authorship binds; the principle directs Rigor's defaults
  only.

- **ADR-3 working decisions.** OQ1 (Constant scalar shape):
  Option C (hybrid). OQ2 (Trinary-returning predicate
  naming): Option A (drop the `?`). OQ3 (refinement carrier
  strategy): Option C (two-tier hybrid — `Difference` for
  point-removal, `Refined` for predicate-subset; the latter
  ships in v0.0.4).

### Fixed

- `Rigor::Analysis::CheckRules` `arity_eligible?` /
  `argument_check_eligible?` no longer raise when the RBS
  function is `RBS::Types::UntypedFunction` (e.g. `(?) ->`
  or certain stdlib variadic sigs). Both predicates now
  return `false` for untyped functions — the conservative
  outcome — instead of crashing the file's analysis.

- `ConstantFolding`'s union fold no longer silently drops
  members for which the method is unsupported. The previous
  behaviour folded `Union[Constant[String], Constant[nil]].nil?`
  to `Constant[true]` because `String#nil?` was not in
  `STRING_UNARY` and the partial fold dropped the String
  pair. The fold now requires every receiver's method to be
  in the allow set; partial coverage bails to RBS instead
  of producing a wrong answer.

## [0.0.2] - 2026-05-01

The second preview. v0.0.2 closes the must-have envelope around the
v0.0.1 pipeline: a richer `RBS::Extended` directive surface
(`assert` / `assert-if-true` / `assert-if-false`, `~T` negation,
`target: self`), inter-procedural inference for user-defined
methods, an `argument-type-mismatch` rule, per-rule diagnostic
suppression (project-level + in-source comments),
configuration passthrough for stdlib libraries and signature
paths, and a `--explain` mode that surfaces fail-soft fallback
events.

### Added

- **`rigor check --explain` mode.** Surfaces fail-soft inference
  fallbacks as `:info` diagnostics so users can see where the
  engine degraded to `Dynamic[Top]`. Driven by
  `Rigor::Inference::CoverageScanner` so each event is attributable
  to the leaf node that triggered it (pass-through wrappers like
  `ProgramNode` / `StatementsNode` / `ParenthesesNode` are not
  double-counted). Each diagnostic carries `rule: "fallback"`,
  `severity: :info`, and a short message naming the node class
  and the type the engine fell back to. Info diagnostics do not
  fail the run.

- **`.rigor.yml` `libraries:` and `signature_paths:` keys.** The
  configuration layer now passes through to
  `Rigor::Environment.for_project`:
  - `libraries:` lists stdlib libraries to load on top of
    `Environment::DEFAULT_LIBRARIES` (e.g. `["csv", "set"]`). Each
    entry must be a name accepted by
    `RBS::EnvironmentLoader#has_library?`; unknown libraries
    fail-soft.
  - `signature_paths:` is an explicit list of `sig/`-style
    directories. Leaving the key unset (or `null`) preserves the
    auto-detect-`<root>/sig` default; `[]` disables project-RBS
    loading entirely.

  Wired through `rigor check`, `rigor type-of`, and `rigor type-scan`
  (the latter two gain a `--config=PATH` option matching `check`).

- **Per-rule diagnostic suppression.** Two mechanisms compose:
  - **Project-level**: `.rigor.yml`'s new `disable:` key
    accepts a list of `rigor check` rule identifiers
    (`undefined-method`, `wrong-arity`,
    `argument-type-mismatch`, `possible-nil-receiver`,
    `dump-type`, `assert-type`); matching diagnostics are
    silenced project-wide.
  - **In-source**: `# rigor:disable <rule>` (or
    `<rule1>, <rule2>`) at the end of an offending line
    silences per-line. `# rigor:disable all` suppresses
    every rule on that line.

  `Rigor::Analysis::Diagnostic` gains a `rule:` field
  carrying the source rule's stable identifier. Parse
  errors / path errors / internal analyzer errors leave
  `rule` as `nil` and stay unsuppressible.

- **Inter-procedural inference for user-defined methods.**
  When a call's receiver is `Nominal[T]` for a user-defined
  class without an RBS sig and the method has been
  discovered as an instance `def`, the engine re-types the
  method's body at the call site with the call's argument
  types bound to the parameters and returns the body's
  last-expression type. The `user_methods.rb` integration
  fixture now resolves `Parity.new.is_odd(3)` to
  `false | true` (was `Dynamic[top]` in v0.0.1) without
  requiring an RBS sig.

  First iteration accepts only the simplest parameter shape
  (required positionals, no optionals / rest / keywords /
  block params); receiver must be `Nominal` (not Singleton);
  recursion is guarded by a per-thread inference stack so
  mutually recursive helpers fall back to `Dynamic[Top]`
  rather than infinite-looping.

- `rigor check` ships an **argument-type-mismatch** rule. For
  every explicit-receiver `Prism::CallNode` whose method has
  exactly one RBS overload (no `rest_positionals`, no
  required keywords, no trailing positionals), the rule
  routes each positional argument's inferred type through
  `Rigor::Inference::Acceptance.accepts(parameter, argument,
  mode: :gradual)` and emits an `:error` for the first
  argument the parameter does not accept. Argument or
  parameter types known only as `Dynamic` skip the check
  (the call cannot be statically refuted). The receiver
  must be `Nominal` / `Singleton` / `Constant`; user-class
  fallback / shape carriers behave as in the wrong-arity
  rule. The rule respects RBS even when the user has both a
  `def` and a sig: the sig is the authoritative parameter
  contract.

- `Rigor::Inference::Acceptance` now treats `Singleton[T]`
  as a subtype of `Module`, `Class`, `Object`, and
  `BasicObject`. Without this rule a method whose parameter
  is typed `Class | Module` (e.g. `Object#is_a?`,
  `Module#define_method`) rejected every singleton receiver,
  producing systemic false positives across both `lib/` and
  `spec/`.

- `RBS::Extended` `target: self` directives now actually
  narrow the receiver local on the matching edge (was: parser
  accepted but engine discarded). Covers all three rule
  shapes:
  - `predicate-if-true self is LoggedInUser` /
    `predicate-if-false self is User` — narrows the receiver
    local on the truthy / falsey edge of an `if` / `unless`
    predicate.
  - `assert-if-true self is AdminUser` — same shape, applied
    when the call is observed as a truthy predicate.
  - `assert self is RegisteredUser` — narrows the receiver
    local unconditionally at the post-call scope.

  Narrowing only fires when the call's receiver is a
  `Prism::LocalVariableReadNode` (the engine's narrowing
  surface) AND the receiver type is statically known
  (Nominal / Singleton / Constant — required for the engine
  to even resolve which class's method carries the
  annotation).

- `RBS::Extended` recognises **negation** in predicate / assert
  directives via the `~ClassName` syntax:
  - `predicate-if-true value is ~NilClass` narrows `value`
    AWAY from `NilClass` on the truthy edge.
  - `assert value is ~NilClass` narrows `value` AWAY from
    `NilClass` in the post-call scope.

  `Rigor::RbsExtended::PredicateEffect#negative?` and
  `AssertEffect#negative?` are new boolean predicates; the
  parser sets them when the directive's type literal starts
  with `~`. The engine routes negative effects through
  `Narrowing.narrow_not_class` instead of `narrow_class` so
  the union loses the named class on the active edge.

- `RBS::Extended` recognises three additional directives:
  - `rigor:v1:assert <target> is <Class>` — refines the
    matching argument's local in the post-call scope
    unconditionally. Wires through
    `StatementEvaluator#eval_call`.
  - `rigor:v1:assert-if-true <target> is <Class>` — refines
    the argument when the call is observed as a truthy
    predicate (e.g. `if call_node`). Wires through
    `Narrowing.predicate_scopes` alongside `predicate-if-*`.
  - `rigor:v1:assert-if-false <target> is <Class>` —
    symmetric for falsey.

  The three directives complement `predicate-if-true` /
  `predicate-if-false` — together they cover the
  `must_be_string!` / `validate!` / `valid_string?` /
  `integer?` patterns common in Ruby. `Rigor::RbsExtended::AssertEffect`
  is the new data class returned by
  `RbsExtended.read_assert_effects(method_def)`.

- `Rigor::Environment::DEFAULT_LIBRARIES` now includes
  `tmpdir`, `stringio`, `forwardable`, `digest`, and
  `securerandom`. Common stdlib calls
  (`Dir.mktmpdir`, `StringIO.new`, `Forwardable#def_delegator`,
  `Digest::SHA256.hexdigest`, `SecureRandom.hex`) resolve
  through their RBS sigs without the user having to enumerate
  the libraries themselves.

### Changed

- `Rigor::Analysis::CheckRules` `dump_type` / `assert_type`
  rules are suppressed when the call site's `self_type` is
  `Rigor` or `Rigor::Testing`. The reflexive
  `Testing.dump_type(value)` / `Testing.assert_type(...)` calls
  inside Rigor's own stub no longer surface diagnostics on
  `rigor check lib`.

## [0.0.1] - 2026-05-01

The first preview release. Rigor can be pointed at a real Ruby
project, infer types end-to-end through a flow-sensitive scope,
and emit diagnostics for a small but practical rule catalogue.

The gem is published to RubyGems as **`rigortype`** (the
`rigor` name was already taken). The Ruby module name remains
`Rigor`, so user code uses `require "rigor"` and references
`Rigor::Scope`, `Rigor::Testing`, etc. — only the
`gem install` / `Gemfile` line uses `rigortype`.

### Added

- **`rigor check` end-to-end pipeline.** Parses Ruby through
  Prism, builds a per-node scope index, and runs a three-rule
  catalogue against it:
  - undefined method on a typed receiver,
  - wrong number of positional arguments,
  - possible nil receiver (with safe-navigation and
    early-return narrowing exclusions).
  False positives on reopened classes, `define_method`-defined
  methods, constant-decl-aliased classes (`YAML` → `Psych`),
  and dynamic / unknown receivers are suppressed.
- **`rigor type-of FILE:LINE:COL`** — probes the inferred
  type at any source position.
- **`rigor type-scan PATH...`** — coverage report over a tree.
- **`rigor init`** — writes a header-commented `.rigor.yml`.
- **Type model.** `Top`, `Bot`, `Dynamic[T]`, `Constant[v]`,
  `Nominal[Class, type_args]`, `Singleton[Class]`,
  `Union[A, B, ...]`, `Tuple[T1, ..., Tn]`, and `HashShape`
  carriers with required / optional / read-only key
  policies. `Trinary` (`yes`/`no`/`maybe`) and
  `AcceptsResult`.
- **Inference engine.** Local, instance, class, and global
  variable bindings tracked through `Rigor::Scope`.
  Cross-method ivar / cvar accumulators populated by a
  `ScopeIndexer` pre-pass; program-wide globals.
- **Compound writes** (`||=`, `&&=`, `+=`, `-=`, `*=`, ...)
  thread through scope for every variable kind, with
  operator dispatch via `MethodDispatcher`.
- **`self` typing.** Class- and method-body boundaries inject
  `Singleton[T]` / `Nominal[T]`; implicit-self call dispatch
  routes through the enclosing class's RBS.
- **Lexical constant lookup.** Project sig, RBS-core, common
  stdlib bundle (pathname, optparse, json, yaml, fileutils,
  tempfile, uri, logger, date, prism, rbs), in-source class
  discovery, and in-source constant value tracking.
- **Predicate narrowing.** Truthiness, `nil?`, `is_a?` /
  `kind_of?` / `instance_of?`, finite-literal equality,
  case-equality (`===`) for Class / Module / Range / Regexp,
  and `case` / `when` integration.
- **Block parameter binding** including destructuring
  (`|(a, b), c|`) and numbered parameters (`_1`, `_2`, ...).
  Block-return-type uplift through generic methods so
  `[1, 2, 3].map { |n| n.to_s }` resolves to `Array[String]`.
- **Closure escape analysis.** A core-and-stdlib catalogue of
  block-accepting methods is classified as `:non_escaping`
  (Array#each / map / select / ...), `:escaping`
  (Module#define_method, Thread.new, Proc.new, ...), or
  `:unknown`. Escaping calls drop narrowed types of captured
  outer locals the block can rebind and record a
  `closure_escape` fact in the FactStore.
- **`RBS::Extended` predicate effects.** Methods whose RBS
  signature carries `%a{rigor:v1:predicate-if-true target is T}`
  / `predicate-if-false` annotations narrow the matching
  argument on the corresponding edge.
- **PHPStan-style typing helpers.** `Rigor::Testing.dump_type`
  surfaces the inferred type as an `:info` diagnostic;
  `Rigor::Testing.assert_type("expected", value)` errors when
  the inferred type's short description does not match. Use
  in fixtures to make them self-asserting.
- **Self-asserting integration suite.** Fixture-driven
  examples under `spec/integration/fixtures/` covering
  parity / case-when / compound writes / is_a? narrowing /
  Tuple and HashShape access / Array#map block-return uplift
  / early-return narrowing / RBS::Extended predicates /
  user-defined method dispatch.

### Known limitations (deferred to v0.0.2)

- Inter-procedural inference for user-defined methods. A
  helper like `def is_odd(n) = n.odd?` types correctly inside
  the def, but the caller observes `Dynamic[top]` until an
  RBS sig is supplied. The `spec/integration/fixtures/user_methods*`
  pair pins both shapes (no sig vs project sig).
- `RBS::Extended` ships only the predicate-effect surface.
  `assert` / `assert-if-true` / `assert-if-false`, negation
  (`~T`), self-targeted narrowing, intersection / union
  refinements, `param` / `return` / `conforms-to` directives
  are deferred.
- No persistent cache — every `rigor check` run re-parses
  and re-types the project.
- No plugin contribution layer past the bundled
  `RBS::Extended` reader.
- Per-rule severity is hard-coded to `:error` (with `:info`
  reserved for `dump_type`); per-rule configuration and
  suppression comments are deferred.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rigortype/rigor/compare/v0.0.9...v0.1.0
[0.0.9]: https://github.com/rigortype/rigor/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/rigortype/rigor/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/rigortype/rigor/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/rigortype/rigor/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/rigortype/rigor/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/rigortype/rigor/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/rigortype/rigor/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/rigortype/rigor/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/rigortype/rigor/releases/tag/v0.0.1
