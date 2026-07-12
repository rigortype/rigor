# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Older release notes are archived under [`docs/`](docs/) when the leading version digit moves up. The active file holds the current `[Unreleased]` section plus the most recent leading-digit cycle (currently `0.2.x`); past cycles live in dedicated archives:

- [`docs/CHANGELOG-0.0.x.md`](docs/CHANGELOG-0.0.x.md) — `0.0.1` through `0.0.9`.
- [`docs/CHANGELOG-0.1.x.md`](docs/CHANGELOG-0.1.x.md) — `0.1.0` through `0.1.19`.

## [Unreleased]

### Added

- **[perf]** `rigor check` and `rigor coverage` now enable YJIT once a run outlasts a short amortization deadline, cutting wall time on large projects with no penalty to quick runs.
  - Ruby ships YJIT but leaves it off, and enabling it up front is a net loss on short runs because the JIT compile cost never amortizes (measured: a ~4s run regressed ~20%). Rigor now arms a background thread at the start of a check / coverage run that enables YJIT only after 5s, so a run that finishes first never pays the compile cost while a long run JITs its dominant tail. Measured cold on Mastodon `app`+`lib`: 25.4s → 15.1s (1.7×), matching always-on YJIT; the short-run cases (kramdown, Mastodon `app/models`, mail) stay at parity. The long-lived `rigor lsp` / `rigor mcp` servers enable YJIT at boot. Set `RIGOR_DISABLE_YJIT=1` to opt out, or `RIGOR_YJIT_DEADLINE=<seconds>` to tune the deadline. Diagnostics and allocations are unchanged.

### Changed

- **[rigor-dry-types]** The dry-types alias scan is now cached across runs, so a warm `rigor check` re-validates file digests instead of re-parsing the whole project ([ADR-60](docs/adr/60-pre-freeze-plugin-contract-consolidation.md) WD3).
  - The plugin's `#prepare` used to Prism-parse every `.rb` file under the project's `paths:` on every invocation — cold and warm alike — to find `include Dry.Types()` declarations, which dominated warm-run wall time on large Rails apps (measured at roughly a third of GitLab `app/models` warm time). The scan now rides a cached `producer` with a `watch:` glob covering the same tree: a warm run re-globs and re-digests the watched files (a cheap SHA over file bytes, no AST build) and reuses the cached alias table, recomputing only when a source file under those paths is edited, added, or removed. The empty result for a project that ships no dry-types module is cached too. `--no-cache` recomputes fresh, exactly as before.
- **[engine]** AST tree walks no longer allocate a throwaway array per node visited, cutting total allocations on every `rigor check` run — most sharply on leaf-heavy sources.
  - `Prism::Node#compact_child_nodes` builds a fresh `Array` on every call, and Rigor's walkers called it unconditionally on every node of every walk. On a Ragel-generated parser (mail's `lib`, with hundreds of thousands of integer-literal leaf nodes) those arrays were over half of all allocations. Loading `Rigor::Source::NodeChildren` now compiles a `#rigor_each_child` method onto each Prism node class that yields the same children in the same order without the array — reading each child field directly and reusing list fields' stored arrays — and the engine's tree walkers (the shared node walker, the plugin/check-rule walk, the scope-discovery seed pass, the collectors, and the sig-gen / dependency / mutation scanners) call it in place of `compact_child_nodes.each`. Diagnostics are byte-identical; the field map is derived from `Prism::Reflection` so it tracks the installed `prism`.


## [0.2.9] - 2026-07-11

v0.2.9 sharpens Rigor on large Rails applications, with GitLab-scale projects as the proving ground: PostgreSQL `db/structure.sql` is accepted as a schema source, the strong-parameters chain stays typed, several route-helper and ActiveSupport coverage gaps close, and module facades now resolve across files. Protection-coverage tooling gets faster with a fork-parallel scan and more actionable — it now names when a missing-RBS gem is the cause of a hole ([ADR-82](docs/adr/82-dynamic-provenance-wiring.md)). Other fixes strengthen control-flow narrowing around `present?` / `blank?` guards and in-body mutation, and make the persistent cache robust across upgrades.

### Added

- **[rigor-activerecord]** A PostgreSQL `db/structure.sql` is now accepted as a schema source, so `schema_format = :sql` projects (GitLab-class apps) are no longer inert.
  - When `db/schema.rb` is absent the plugin parses `db/structure.sql` (configurable via `structure_sql_file`) into the same schema table the Ruby-DSL parser produces — column names, types, and Postgres array columns. Previously such a project loaded no schema at all, so every ActiveRecord check was skipped and relation chains cascaded false diagnostics. An unmappable column type (custom enum, `tsvector`) degrades to `Object` rather than being dropped.
  - A `serialize` / `mount_uploader` / custom-`attribute` column reads leniently rather than being narrowed to its SQL scalar type, so `note.position.diff_refs` and `diff.external_diff.store!` no longer read as `undefined-method`. Column existence checks (`where(col:)`) are unaffected.
- **[rigor-actionpack]** The strong-parameters fluent chain now stays typed, so `coverage --protection` counts the chained sites as protected.
  - `params.require(:user)` / `.permit(:name)` previously returned `Dynamic` at the first hop (the class ships no bundled RBS), leaking every downstream site. `require` / `permit` / `permit!` on a `Parameters` receiver now re-type to the same lenient nominal, keeping the chain a concrete receiver end-to-end. It types the container, never a caller's argument.
- **[engine]** A `module` constant now resolves to its module object across files, so calls on a module facade (`Feature.enabled?`, `Gitlab::Utils.to_boolean`) are typed instead of dynamic ([ADR-57](docs/adr/57-self-call-return-adoption.md) WD3).
  - Rigor's per-file pass always typed `module M` as the module object, but the project-wide discovery seed registered only classes, so the same constant read from a sibling file fell back to `Dynamic`. Both halves now agree: a call to a `def self.x` / `class << self` / `module_function` method declared in another file re-types the callee's body as it already did in-file. On GitLab, `Feature.enabled?` alone is 695 previously-unprotected sites.
- **[rigor coverage]** `coverage --protection` now tells you which holes an external gem's missing RBS causes, instead of filing them under "engine gap" ([ADR-82](docs/adr/82-dynamic-provenance-wiring.md) WD9).
  - When an unresolved constant (`Faraday`, `I18n`) is declared by a gem locked in your `Gemfile.lock` that ships no RBS, the whole chain rooted at it is labeled `external_gem_without_rbs` → `add_rbs` — the one answer a user can act on directly (`rbs collection install`, or write the signature). Ownership is established by parsing the gem's entry file for its declared constants, never guessed from the gem's name, and no gem code runs; a constant no locked gem declares keeps the generic cause, so the failure mode is a missing label, never a wrong one.

### Changed

- **[rigor coverage]** `coverage --protection` now runs in parallel and honours the same worker knob as `rigor check`, so a large project's protection scan is no longer stuck single-threaded.
  - The parameter-inference pre-pass and the per-file protection scan are each fork-mapped over worker processes built from one parent-side environment (RBS env, plugin registry, and cross-file seed built once and copy-on-write inherited). Worker count resolves exactly as `check` does (`--workers=N` › `RIGOR_RACTOR_WORKERS` › `.rigor.yml` `parallel.workers:` › `0`), and the output is byte-identical to a sequential run. Measured on Mastodon `app lib`: 61 s → 43 s at four workers, with peak memory roughly halved.
- **[rigor coverage]** `rigor coverage` with no path argument now falls back to the configured `paths:` (default `lib`), matching `rigor check`, instead of erroring.
- **[repo]** The `rigor-playground` browser-playground backend moved from `plugins/` to `apps/rigor-playground/` (it is a standalone Rack/Puma application, not an analyzer plugin), so its Fly.io / Docker deploy commands now reference the new path.

### Fixed

- **[cli]** `rigor check --format <name>` for a format listed as supported but not wired now fails loudly instead of printing nothing, so a drift between the supported-format list and the dispatch cannot pass silently.
- **[engine]** A guard like `if login.present?` / `return if content.blank?` now narrows a nilable receiver, so the guarded call no longer reads as `possible nil receiver`.
  - When a predicate's signature declares it always returns `false` for `nil` (as ActiveSupport's `NilClass#present?` does), a truthy answer proves the receiver was not nil and the nil arm is dropped on that edge, mirrored on the falsey edge for `blank?`. Only value-pinned `nil` / `true` / `false` arms participate, and a safe-navigation guard (`x&.blank?`) is deliberately left alone. Removes four false positives on Redmine and sixteen on GitLab, none introduced anywhere.
- **[engine]** A collection filled by a helper that mutates it (`items.each { |s| absorb(s, acc) }; … unless acc.empty?`) no longer reads as `flow.always-truthy-condition`.
  - When a call resolves to a user method that content-mutates one of its parameters directly in its body (`param[k] = v` / `param << x`), the matching caller argument is floored, so a later shape read stops folding against the stale empty-literal seed ([ADR-56](docs/adr/56-block-captured-local-mutation.md) / [ADR-57](docs/adr/57-self-call-return-adoption.md)). It only forgets a literal-shape fact the mutation invalidates, never invents one.
- **[rigor-actionpack]** `unknown-permit-key` no longer fires on a virtual (non-column) attribute in strong-parameters.
  - Permitting a non-column is ordinary Rails — a Devise virtual attribute (`password`, `remember_me`), a state-machine `*_event`, an `attr_accessor` setter. The check is now a typo detector: it fires only when the permit key is a near-miss edit-distance match of a real column (`emial` → `email`), never on a legitimate virtual attribute.
- **[rigor-rails-routes]** A project mounting a Grape API no longer reads its `grape-path-helpers` calls (`api_v4_groups_badges_path`) as `unknown-helper`.
  - The gem names each helper after its route's path segments from grape's runtime route table, which metaprogramming builds so no static parser can enumerate the names. The plugin reads the project's own Grape `prefix` and `version` declarations (`grape_api_paths:`, default `lib/api` + `app/api`) and treats `<prefix>_<version>_…_path` as valid-but-unenumerable. Teeth stay where the gem's contract makes them sound: it defines no `_url` helper, so `api_v4_groups_badges_url` still fires. Removes 68 of GitLab's 141 `unknown-helper` errors.
- **[rigor-rails-routes]** Two route-helper name-composition gaps that fired false `unknown-helper` on working code now match Rails' own naming.
  - A multi-segment string action inside a `member do` / `collection do` block (`collection { get 'granular/new' }`) is named the way Rails' `Mapper.normalize_name` does (`granular_new_<scope>_<plural>_path`) instead of the generic mis-ordered name.
  - A bare symbol action in a named scope (`scope(as: :user) { get :activity }`) now registers `<scope_as>_activity_path`; previously such a call registered no helper and read as `unknown-helper`.
- **[rigor-activerecord]** A nested / joined-table condition (`Model.where(assoc: { ... })`) no longer reads as an unknown column — the Hash value marks a join condition whose key names an association or joined table, not a column on the receiver.
- **[rigor-activesupport-core-ext]** More ActiveSupport core extensions are covered, so calls on them no longer read as `undefined-method`: `String#upcase_first` / `#remove` / `#titlecase` / `#dasherize`, `Object#in?`, `Date`/`Time#advance` / `#all_day`, `Date#to_time(form)`, and `ERB::Util.html_escape_once`.
- **[core RBS overlay]** Two stdlib signatures the pinned `rbs` gem omits are supplied so real calls stop false-firing: `Psych.parse` / `.parse_stream` no longer reads as `undefined-method`, and `CSV::MalformedCSVError.new(message, line_number)` (the documented two-arg constructor) no longer reads as `wrong-arity`.
- **[cache]** Persistent cache entries are now rebuilt after a Rigor upgrade, stale generations are reclaimed more aggressively, and a broken cache root degrades to memory-only instead of raising.
  - The cache root marker now folds in `Rigor::VERSION`, so Marshal payloads written by an older release are never reused after an upgrade — the first writable run after upgrading rebuilds the cache.
  - A read-only store (LSP / editor mode) now checks that marker before trusting a disk hit, closing the one path where an ABI-stale payload could still be unmarshalled after an upgrade.
  - Whole-project cache producers now keep only a few recent generations, reclaiming content-keyed orphans that sat below the global byte cap indefinitely, even when `cache.max_bytes` is unbounded.
  - A cache root that cannot be read or repaired (permission error, disk full, deleted root) no longer fails the run — analysis continues with the disk tier disabled.

## [0.2.8] - 2026-07-06

v0.2.8 makes `rigor coverage --protection` explain itself: every unprotected site now carries the reason its receiver is dynamic and the action that would close it, so the report points you at the highest-leverage fix ([ADR-82](docs/adr/82-dynamic-provenance-wiring.md)). Call-site parameter inference reaches more method shapes, protecting more sites. It also hardens the RBS environment against malformed signatures — a single unparseable `.rbs`, whether hand-written or from `rigor sig-gen`, is now contained instead of blanking every type in the run.

### Added

- **[rigor coverage]** `rigor coverage --protection` now labels every unprotected site with *why* its receiver is dynamic and which action would close it: install RBS, enable a plugin, or report an engine gap ([ADR-82](docs/adr/82-dynamic-provenance-wiring.md)).
  - The cause follows the value across variable bindings and method chains, so a bare `x` / `@x` or a chained `x.foo.bar` receiver is labelled rather than left blank, and an untyped parameter or an unbound instance variable routes to the inference that would type it ([ADR-67](docs/adr/67-parameter-type-inference.md) / [ADR-58](docs/adr/58-ivar-field-typing.md)). `--format json` reports an exact per-site `cause_site_counts` tally alongside the `tractability_summary`. Precision-additive — no type, diagnostic, or severity change.
- **[rigor coverage]** `rigor coverage --protection` infers more method parameter types from their call sites, protecting more sites ([ADR-67](docs/adr/67-parameter-type-inference.md)).
  - Call-site inference now covers a method's leading required parameters even when trailing optional / keyword / rest / block parameters follow (`def f(x, opts = {})`), a shape common on real Rails methods.

### Fixed

- **[rigor check / coverage]** A single unparseable file under `signature_paths:` is now quarantined instead of collapsing the whole RBS environment.
  - Previously one malformed `.rbs` failed the entire environment build, so every type query degraded to `Dynamic[top]` and coverage and diagnostics silently dropped — a *shrinking* diagnostic count could actually mean "your `sig/` stopped loading." Signatures now load one file at a time; a file that does not parse is skipped and named in a one-time warning, so the rest of the environment (and all bundled RBS) still loads.
- **[rigor sig-gen]** Generated RBS no longer emits an unparseable signature file that collapses the whole environment.
  - Two cases are fixed: a record-shaped return type with a non-identifier key (`{ "data-contrast" => T }`), and a constructor taking a `&block` parameter (the block now renders after the parameter parens as `?{ (*untyped) -> untyped }`). Either previously produced RBS that `rbs` rejects, which failed the whole `sig/` build; surfaced onboarding Mastodon.

## [0.2.7] - 2026-07-05

v0.2.7 sharpens type coverage on real Rails apps, from onboarding the Redmine and Mastodon survey targets: `rigor-actionpack` now types a controller's request-context readers so the single largest dispatch cluster stops reading `Dynamic`, and two fixes make `rigor coverage --protection` report the protection Rigor actually achieves. It also keeps the bundled Agent Skills current across upgrades — a new `rigor skill --full` and a per-skill directive re-fetch each skill's steps from the installed gem, so a copy installed into a project no longer goes stale ([ADR-81](docs/adr/81-skill-set-optimization.md)). A `rigor sig-gen` fix and the engine fix it surfaced (a malformed project `.rbs` no longer collapses the whole RBS environment) round out the cycle.

### Added

- **[rigor skill]** New `rigor skill --full <name>` prints a bundled skill's body followed by every `references/` file inline — the complete, version-current procedure in one call ([ADR-81](docs/adr/81-skill-set-optimization.md)).
  - Every bundled skill now opens with a "load the version-current copy" directive that re-fetches its steps through this command, so a skill installed into a project (e.g. via `npx skills add`) follows the procedure that ships with the *installed* Rigor rather than a copy frozen at install time.
- **[rigor-actionpack]** The implicit-self request-context readers `params`, `session`, `request`, `flash`, and `cookies` inside a controller now type as their Action Pack classes instead of `Dynamic[top]`, so `params[:x]` / `params.require(...).permit(...)` / `session[:x] = …` / `request.xhr?` / `flash[:notice] = …` dispatch on a concrete receiver.
  - On real Rails apps this is the single largest type-coverage hole: `params[...]` is the #1 dispatch cluster (redmine `app`+`lib`: ~2400 `[]` sites), with `session[:x] =` and `flash[...]` further large shares.
  - Each type carries no bundled RBS on purpose — the receiver is concrete (so `coverage --protection` counts the site and dispatch resolves against a named class) while its method surface stays engine-lenient, so every method stays false-positive-safe. Values read `untyped` ([ADR-5](docs/adr/5-robustness-principle.md): the container is typed, never the caller's argument).

### Fixed

- **[rigor coverage]** `rigor coverage --protection` now reports the protection Rigor actually achieves instead of systematically undercounting it (redmine `app`+`lib` 0.195 → 0.328, mastodon `app/models` 0.177 → 0.311).
  - It built its scan scope from the RBS environment alone, so a receiver a plugin types via `dynamic_return` — a controller's `params`, a `Model.where` → `ActiveRecord::Relation[Model]` — read `Dynamic` and its site was miscounted as unprotected; the scan now builds the same plugin-aware environment the runner and LSP use.
  - It also scanned each file against an empty discovery table, so a constant referring to a class defined in a sibling file (a Rails model `Account`, `User`) read `Dynamic` instead of `singleton(Account)`; the scan now seeds `discovered_classes` from the scanned paths, matching what `rigor check` resolves.
- **[rigor sig-gen]** Generated RBS for a subclass now carries its superclass — `class GitAdapter < AbstractAdapter` instead of the bare `class GitAdapter` — for plain-constant parents (`class X < Foo` / `class X < Foo::Bar`).
  - Dropping it made the sidecar `sig/` misrepresent the class (inherited members vanished, so receiver dispatch degraded to `Dynamic`) and could reference an inherited nested type that no longer resolved. A computed parent (`Struct.new` / `Data.define` / `Class.new`) is still emitted without a superclass, as before.
- **[engine]** A malformed project `.rbs` no longer collapses the entire RBS environment.
  - The referenced-type stub sweep re-declared an already-declared `class` as a `module` when stubbing an enclosing namespace (e.g. stubbing `Foo::GitAdapter::Revision` re-emitted `module Foo::GitAdapter` over the existing `class`), and the resulting `RBS::DuplicatedDeclarationError` nulled the whole env — every type-of query then degraded to `Dynamic[top]` and most diagnostics silently stopped firing. The sweep now skips names already declared in the env, mirroring the guard the missing-namespace synthesizer already applied. Surfaced onboarding redmine (2026-07-04).
- **[gem metadata]** The gem's `documentation_uri` now points at the `master` branch, fixing the 404 the RubyGems "Documentation" link returned.

## [0.2.6] - 2026-06-27

v0.2.6 sharpens how Rigor explains itself and tightens shape-aware inference. `rigor coverage --protection` now labels each untyped hole with why it is dynamic and whether a type can close it, and a new `rigor doctor` command routes setup problems to their fix. Literal hashes and arrays keep their precise shape through `freeze` / `dup` / `clone`, closing a folding gap on frozen constants. It also begins a plugin-contract cleanup ahead of the v1.0 freeze: the `type_specifier` hook is renamed to `narrowing_facts`, with the old name kept as a deprecated alias.

### Added

- **[rigor coverage]** `rigor coverage --protection` now explains why each unprotected dispatch is untyped and whether a type can close it ([ADR-75](docs/adr/75-dynamic-provenance.md)).
  - Every `add_a_type_here` entry carries a `dynamic_origin` cause (`external_gem_without_rbs`, `framework_dsl_boundary`, `analyzer_budget_cutoff`, `explicit_untyped`, `unsupported_syntax`) and a derived `tractability` axis (`add_rbs` / `enable_plugin` / `engine_gap`), in both `--format json` and the text report, so you can prioritise the holes an installed or hand-written RBS can actually close. A `tractability_summary` of per-axis dispatch-site totals is emitted in the JSON and shown as a one-line `by tractability:` breakdown in text.
  - Provenance is precision-additive: it never changes `untyped = Dynamic[top]` semantics, fires no diagnostic, and never feeds severity.
- **[rigor doctor]** New `rigor doctor` command classifies a project's existing findings into setup-problem vs clean-run and prints a routed next action for each, over a stable `checks[].id` JSON contract ([ADR-77](docs/adr/77-doctor-and-upgrade-commands.md)).
  - It is a presentation layer over data `rigor check` already produces (config resolution, RBS environment, plugin load, baseline drift) and runs no new analysis. The companion `rigor upgrade` ships as a queued skeleton (ADR-50 WD7) that reports no migration target yet.

### Changed

- **[engine]** Literal hashes and arrays now preserve their precise shape through `freeze` / `dup` / `clone` / `itself` instead of degrading to a nominal `Hash` / `Array`, so `MESSAGES = {…}.freeze; MESSAGES[reason]` and `XS = […].freeze; XS[0]` fold the precise value rather than `Dynamic` ([ADR-76](docs/adr/76-effect-modeling-freeze-dup-shape-preservation.md) WD2 / [ADR-78](docs/adr/78-reflexive-overfold-always-truthy.md) WD3).
- **[engine]** Shape-carrier methods (`tuple.any? { … }`, `.sum { … }`, `.count { … }`, and the hash-shape equivalents) no longer constant-fold a block-form call, deferring to the normal block/RBS path ([ADR-78](docs/adr/78-reflexive-overfold-always-truthy.md) WD1).
  - They previously folded the no-block result, ignoring the block; the fix is strictly precision-reducing and removed the spurious `flow.always-truthy-condition` firings that blocked the shape-preservation change above.

### Deprecated

- **[plugin contract]** The plugin hook `type_specifier` is renamed to `narrowing_facts`; `type_specifier` keeps working as a deprecated alias and will be removed in 0.3.0 ([ADR-80](docs/adr/80-narrowing-facts-rename.md)).
  - The old name read as a parallel to `dynamic_return` (which contributes a type) when it contributes post-return narrowing facts; migrate `type_specifier methods: …` → `narrowing_facts methods: …`, after which the one-time deprecation warning stops firing. The bundled `rigor-minitest` / `rigor-sorbet` / `rigor-rspec` plugins are already migrated, and the `rigor plugins --capabilities` JSON field `type_specifier_methods` is unchanged for now.

## [0.2.5] - 2026-06-24

v0.2.5 adds i18n validation for view-template lazy keys in `rigor-rails-i18n`, so `t('.title')` calls inside ERB, Haml, and Slim templates are now expanded using the Rails virtual-path convention and checked against `config/locales/*.yml` for key existence and per-locale coverage.

### Added

- **[rigor-rails-i18n]** View-template lazy `t('.title')` calls are now validated against `config/locales/*.yml`.
  - The key is expanded using the Rails virtual-path convention (partial `_`-prefixes and `+variant` suffixes are stripped) and checked for existence and per-locale coverage across ERB, Haml, and Slim templates under the configurable `view_search_paths`; results are cached and invalidated when templates change.
  - Interpolation validation is skipped — the hash may come from controller instance variables not visible in the template source.
  - Known limitation: the view scan is a project-wide pass surfaced through the per-file diagnostic hook, so under `--workers` each fork-pool worker re-emits the full set (the same once-per-run limitation the `load-error` diagnostics already carry). Default sequential `rigor check` is unaffected.
  - Plugin bumped to `0.3.0`.

## [0.2.4] - 2026-06-22

v0.2.4 is a targeted compatibility fix. Analysis was crashing on the lower end of the declared `rbs >= 3.0, < 5.0` range due to API divergences in the environment-loading surface; v0.2.4 corrects both crash paths and adds a CI job that exercises the RBS-loading surface against both RBS 3.x and 4.x on every push. Thanks to https://github.com/aki77 for the report (https://github.com/rigortype/rigor/issues/21).

### Fixed

- **[rigor check]** Fixed two crashes on RBS 3.x — `undefined method 'primary_decl'` and `uninitialized constant RBS::Source` — so the full supported range `rbs >= 3.0, < 5.0` works again, not just RBS 4.x.
  - Rigor now reads a class entry's representative declaration and walks its declarations through accessors present on both the RBS 3.x and 4.x environment APIs.
  - A new CI job runs the RBS-loading surface against both an RBS 3.x and an RBS 4.x bundle so the supported range stays honest going forward.

## [0.2.3] - 2026-06-21

v0.2.3 is a focused `rigor triage` usability fix. On a Rails project the report was dominated by plugin recognition trace, which buried the genuine error/warning signal and ranked the most *working* files as the top hotspots; triage now counts only the actionable diagnostics by default ([ADR-23 WD6](docs/adr/23-diagnostic-triage-command.md)).

### Changed

- **[rigor triage]** The distribution, selectors, and hotspot sections now count only the actionable diagnostics (`error` + `warning`); `info` is excluded from these volume views by default ([ADR-23 WD6](docs/adr/23-diagnostic-triage-command.md)).
  - On a Rails project `info` is dominated by plugin recognition trace (`plugin.activerecord.model-call`, `plugin.rails-routes.helper`) — positive "Rigor resolved this call" records that previously buried the genuine error/warning signal and ranked the files with the most *working* code as the top hotspots. The summary line still reports the full `info` count and the heuristic hints still see every diagnostic, so the useful `gem-without-rbs` notice survives.
  - This is a behaviour change to the default `triage` text and `--format json` output: the volume views no longer sum to `summary.total`, and the JSON gains a top-level `include_info` boolean. Pass `--include-info` to restore the previous behaviour.

## [0.2.2] - 2026-06-21

v0.2.2 centres on a SKILL-driven onboarding experience. A new `rigor docs` command serves the documentation bundled with the gem offline, `rigor skill describe` recommends what to do next on a project, and a family of new Agent Skills — led by `rigor-next-steps` and `rigor-ask` — give an AI coding agent (or you) a current, version-coupled entry point into Rigor ([ADR-73](docs/adr/73-skill-driven-user-experience.md), [ADR-74](docs/adr/74-offline-doc-access-and-llms-txt.md)). A 2026-06-20 onboarding field trial drove a round of clearer diagnostics and configuration warnings so a broken setup no longer reads as a clean run. Constant folding reaches several more pure scalar and structural methods, the analyzer's seed pass allocates less on definition-dense projects, and a cross-tree documentation audit fixes a batch of spec and handbook contradictions.

### Added

- **[cli]** `rigor skill describe` (also spelled `rigor skill --describe`) recommends what to do next on the current project: it probes the project's state — config / baseline / `sig/` / CI, all from cheap presence checks without running `rigor check` — prints a recommended next skill with a one-line reason, and lists every bundled skill with its current description ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
- **[cli]** `rigor docs` serves Rigor's documentation bundled with the gem **offline**, so once Rigor is installed an AI coding agent (or you) can read the drive-Rigor guidance the skills route to with no network round-trip — the doc twin of `rigor skill` ([ADR-74](docs/adr/74-offline-doc-access-and-llms-txt.md)).
  - `rigor docs` prints the bundled `llms.txt` index, `rigor docs <name>` a manual or handbook page (addressed by a category-qualified path like `handbook/03-narrowing`, a prefixed name like `02-cli-reference`, or a unique short name like `cli-reference`), `rigor docs --path <name>` its absolute path, and `rigor docs --list [category]` the discovery list (optionally filtered to `manual` or `handbook`).
  - The gem now ships `docs/install.md`, `docs/llms.txt`, and the full `docs/manual/` and `docs/handbook/`; the `rigor-editor-setup`, `rigor-mcp-setup`, and `rigor-next-steps` skills prefer `rigor docs <chapter>` over a GitHub raw URL, keeping the web link only as a pre-install fallback.
- **[skills]** New `rigor-next-steps` Agent Skill — the single "what should we do next with Rigor?" entry point ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
  - It resolves the `rigor` command (installing it via the guide if missing), onboards an unconfigured project, then routes through `rigor skill describe`, so its guidance stays current to your installed Rigor instead of being frozen into the skill file.
- **[skills]** New `rigor-ask` Agent Skill — the question companion to `rigor-next-steps`, so the user-facing surface collapses to two skills worth remembering: *"what should we do next?"* (`rigor-next-steps`) and *"answer this about Rigor"* (`rigor-ask`) ([ADR-73](docs/adr/73-skill-driven-user-experience.md) / [ADR-74](docs/adr/74-offline-doc-access-and-llms-txt.md)).
  - Ask anything about Rigor in plain language — why a diagnostic fired or whether it's a false positive, how the type model works, what a flag or config key does, how Rigor compares to Sorbet / Steep / mypy / PHPStan, whether it handles a given gem or framework, or how to type a method.
  - Because Rigor is niche and version-specific, the skill investigates instead of answering from memory: it reads the bundled handbook and manual offline via `rigor docs` (and `rigor explain` for a diagnostic id), and for a question about your own code runs `rigor check` / `annotate` / `type-of`, then answers from the page or the inferred type.
  - It is catalogue-only — triggered by a question, never presence-recommended — and a "do X for me" request (set up CI, reduce a baseline) gets a short orientation and a hand-off to the matching skill.
- **[skills]** New `rigor-protection-uplift` Agent Skill — closes the type-protection holes `rigor coverage --protection` surfaces, sig-gen first and minimal hand-authored residuals, under a double gate that keeps `rigor check` clean (productizes [ADR-63](docs/adr/63-type-protection-coverage.md) WD5).
- **[skills]** New `rigor-rbs-setup` Agent Skill — installs community RBS for the project's gems (`rbs collection install`) so Rigor stops typing RBS-less dependencies as `Dynamic`; `rigor skill describe` recommends it when a `Gemfile.lock` is present but no `rbs_collection.lock.yaml` has been set up yet ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
- **[skills]** New `rigor-editor-setup` Agent Skill — wires the bundled `rigor lsp` language server into the developer's editor (Neovim, VS Code, Helix, Emacs) for live diagnostics, hover types, and completion, routing to the manual's editor-integration chapter for the per-editor config; `rigor skill describe` recommends it when a project commits a `.vscode/` config without a Rigor reference ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
- **[skills]** New `rigor-mcp-setup` Agent Skill — wires the bundled `rigor mcp` server into an AI coding agent (Claude Code, Claude Desktop, Cursor, Cline) so it can call Rigor's read-only analysis tools, routing to the manual's MCP chapter for the per-client config; `rigor skill describe` recommends it when a project commits an MCP config (`.mcp.json` / `.cursor/mcp.json`) without a Rigor reference ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
- **[skills]** Four more catalogue skills round out the `rigor skill describe` set ([ADR-73](docs/adr/73-skill-driven-user-experience.md)).
  - `rigor-monkeypatch-resolve` wires a project's own monkey-patch files into `pre_eval:` to clear `undefined-method` clusters; `rigor-plugin-tune` re-matches `Gemfile.lock` to the bundled plugin catalogue and enables the right plugins (verifying with `rigor plugins --strict`); `rigor-upgrade` adopts a new Rigor version by diffing against the baseline and sorting genuine new catches from sig-quality false positives; and `rigor-doctor` validates the setup via the existing `config_warnings`, `rigor plugins --strict`, and `rigor baseline drift`.
  - These are catalogue-only: their trigger is an event or a run-time check, not a file-presence signal, so `describe` lists them for the agent to offer rather than recommending them from a state probe.
- **[skills]** The bundled user-facing skills are now installable via [vercel-labs/skills](https://github.com/vercel-labs/skills) (`npx skills add rigortype/rigor`, or per-skill) in addition to `rigor skill`. A new `skills/README.md` catalogues them and documents both install channels; the contributor-only skills under `.claude/skills/` are marked `metadata.internal: true` so a bulk install does not ship them.
- **[inference]** A few more pure, deterministic methods on literal receivers now fold to a precise `Constant` or `Tuple` instead of the widened RBS type.
  - `Integer#allbits?` / `#anybits?` / `#nobits?` fold to a `Constant[bool]` against a concrete Integer mask (e.g. `0b1010.allbits?(0b1000)` → `Constant[true]`) — the bit-test siblings of the already-folded bit-reference `[]`. A literal mask never routes through the user-overridable `to_int` the catalog conservatively flags, so the fold is pure here.
  - `Array#slice` on an array literal now folds exactly like `[]` across the index, start-length, and Range forms (it is the same method), so `[10, 20, 30].slice(1, 2)` yields `Tuple[20, 30]`.
  - `Pathname#/` (the idiomatic path-join operator, `dir / "file"`) folds like its exact alias `Pathname#+`, and `Pathname#basename(suffix)` folds the extension-stripping form (`Pathname.new("x.rb").basename(".rb")` → `Constant[#<Pathname:x>]`) — both pure `@path` manipulation, no filesystem read.
  - The n-arg `min(n)` / `max(n)` forms on an array literal or integer Range lift to a `Tuple` in Ruby's order (`min(n)` ascending, `max(n)` descending) — e.g. `[3, 1, 4].max(2)` → `Tuple[4, 3]`, `(1..10).min(3)` → `Tuple[1, 2, 3]` — the n-arg siblings of the already-folded `first(n)` / `last(n)`.
  - `Set#&` and its alias `Set#intersection` between two literal sets now fold to a `Constant[Set]` (e.g. `Set[1, 2, 3] & Set[2, 4]` → `Constant[Set[2]]`), joining their already-folding siblings `|` / `-` / `^` — the intersection was the lone gap because the catalog conservatively flags its C body block-dependent.
  - `Float#numerator` / `#denominator` fold to the float's exact rational decomposition (`2.5.numerator` → `Constant[5]`, `2.5.denominator` → `Constant[2]`), and `Float#arg` / `#angle` / `#phase` to its complex argument (`Constant[0]` for a non-negative receiver, `Constant[Math::PI]` for a negative one) — the Float siblings of the already-folded Rational accessors. Non-finite edges stay sound (an `Infinity` receiver folds to the value Ruby returns; a `NaN` result declines to the RBS tier).
  - `Pathname#split` lifts the `[dirname, basename]` pair to a `Tuple` of `Pathname` constants (`Pathname.new("/usr/bin/ruby").split` → `Tuple[#<Pathname:/usr/bin>, #<Pathname:ruby>]`) — the Array-returning sibling of the already-folded scalar `dirname` / `basename`, pure `@path` manipulation with no filesystem read.
  - `String#shellescape` folds to a `Constant[String]` and `String#shellsplit` lifts its token list to a `Tuple` (`"ls -la".shellsplit` → `Tuple["ls", "-la"]`) — the String-receiver twins of the already-folded `Shellwords.escape` / `Shellwords.split`. An unmatched quote raises at fold time and declines to the RBS tier.

### Changed

- **[cli]** The `target_ruby` configuration-error diagnostic now names the supported floor and where to read the right value. When a configured `target_ruby` is below Prism's minimum (e.g. `"3.0"`), the message reads *"is not supported by this Rigor build (Prism accepts 3.3.0 and newer). Set target_ruby to your project's Ruby version (>= 3.3.0) — read it from Gemfile.lock's `RUBY VERSION` or .ruby-version"* instead of a bare *"not accepted by Prism"*, so the fix is obvious without a guess-and-retry loop (the floor is probed live, not hard-coded). Surfaced by the 2026-06-20 onboarding field trial.
- **[plugins]** The plugin load error for a convenience meta-gem (e.g. listing `plugins: [rigor-rails]`) is now actionable. Instead of a bare *"registered multiple plugins; disambiguate with an explicit `id:` field"*, it explains the gem is a meta-gem, lists the bundled plugins, and tells you to list the individual `rigor-*` plugin gems in `plugins:` (with an example) — so the intuitive-but-wrong `plugins: [rigor-rails]` no longer dead-ends. Surfaced by the 2026-06-20 onboarding field trial.
- **[cli]** `rigor skill describe`'s "For the agent" section now teaches **check-aware routing**. The recommendation itself stays presence-only (it never runs `rigor check`, per [ADR-73](docs/adr/73-skill-driven-user-experience.md) WD2), but the guidance tells the agent to refine the choice from `rigor check` findings it already has — errors → `rigor-baseline-reduce`, a monkey-patch `undefined-method` cluster → `rigor-monkeypatch-resolve`, Dynamic framework calls with no matching plugins → `rigor-plugin-tune`, `RBS classes available: 0` / a `configuration-error` → `rigor-doctor` — closing the field trial's headline gap (the presence-only headline was often less apt than what `check` reveals).
- **[cli]** `rigor describe` now works as a top-level alias for `rigor skill describe` (the field trial saw the bare form tried and met "Unknown command").
- **[cli]** `rigor skill` and `rigor docs` moved their discovery subcommands to flags so the positional slot is unambiguously a skill / doc *name*: `rigor skill <name>` (print) / `--list` / `--path <name>`, and `rigor docs <name>` (print) / `--list [category]` / `--path <name>`. `rigor skill describe` / `--describe` (and the top-level `rigor describe`) are unchanged. The legacy verb spellings — `rigor skill list` / `print <name>` / `path <name>` and `rigor docs list` / `path <name>` — still work but now print a one-line stderr deprecation notice and are **removed in v0.3.0** ([ADR-73](docs/adr/73-skill-driven-user-experience.md) / [ADR-74](docs/adr/74-offline-doc-access-and-llms-txt.md); see [ROADMAP](docs/ROADMAP.md) § "Scheduled CLI deprecations").
- **[cli]** `rigor check` now warn-and-skips a non-existent path when another path yields files, instead of aborting the whole run with exit 1. `rigor check app lib` on a project with no `lib/` now analyses `app` and emits `lib:1:1: warning: no such file or directory (skipped)`. A path that leaves *nothing* to analyse still errors, so a lone typo (`rigor check typo.rb`) is not silently masked. Surfaced by the 2026-06-20 onboarding field trial.
- **[cli]** `rigor skill describe` now recommends `rigor-plugin-tune` ahead of `rigor-rbs-setup` for a *configured* Rails project with no Rails plugins enabled — wiring the ActiveRecord / routes / i18n plugins resolves more than community RBS would (the 2026-06-20 field trial's strap case). The cue is presence-only: Rails in `Gemfile.lock` plus no `rigor-rails-*` plugin in the config.
- **[cli]** `rigor check` now prints a prominent WARNING when the RBS environment is empty (`RBS classes available: 0`). A normal run always loads the bundled core + stdlib RBS, so zero means the environment failed to build — usually a duplicate declaration in `signature_paths:` — and fell back to empty, leaving an otherwise-"successful" run with near-useless type coverage (most diagnostics and coverage cannot fire). Surfacing it stops a broken setup from being mistaken for a clean analysis — the field trial's redmine case would otherwise have wired a 0-coverage check into CI.

### Performance

- **[inference]** The `ScopeIndexer` seed pass walks each file's AST fewer times. The discovery pre-pass ran a separate full-tree descent per table; in particular the discovered-methods walk and the instance-method def-node walk had byte-identical class / module / singleton traversals yet ran independently, and the cross-file pre-pass walked the def-node tree *twice* (once in `merge_discovered_defs`, once in `record_class_sources`). One combined `walk_methods_and_def_nodes` descent now produces both tables at once, and the def-node table is threaded to its second consumer instead of recomputed. Definition-dense libraries benefit most — cold `rigor check --no-cache` on the `mail` gem (196 files) allocates ~8% fewer objects (20.6M → 18.9M); Mastodon and Redmine drop ~0.5–1%. Diagnostics are byte-identical across the survey corpus ([profiling note](docs/notes/20260620-corpus-cold-warm-reprofile.md)).

### Documentation

- **[docs]** A cross-tree consistency audit of the handbook, manual, and the internal / type specifications corrected a batch of contradictions surfaced against the implementation.
  - Severity and grammar: the handbook errors chapter listed the wrong default severity for two rules (`call.possible-nil-receiver` is `error`, not `warning`; `def.ivar-write-mismatch` is `warning` under `balanced`, not `error`); the `RBS::Extended` directive grammar carried a spurious colon on the `assert` / `assert-if-*` / `predicate-if-*` / `conforms-to` directives (only `return:` and `param:` take one) and documented a non-existent `assertion-on` directive, while the real `assert-if-true` / `assert-if-false` directives are now in the directive table; and handbook chapter 9 plus several appendices still presented the removed `flow_contribution_for` plugin hook as current, now `dynamic_return` / `type_specifier` ([ADR-52](docs/adr/52-compiled-plugin-contribution-dispatch.md)).
  - Catalogues and counts: the examples count ("sixteen" → six) and production-plugin count ("Thirty" → thirty-one) were corrected; the reserved-refinement catalogue forbade the implemented `int<min, max>` form and omitted `non-empty-hash[K, V]`; and the narrowing catalogue gained the `respond_to?` and `empty?` / `any?` / `none?` predicate shapes it already implements (the handbook had claimed `respond_to?` is never narrowed).
  - Caching, API, and rendering: the caching chapter claimed adding/removing a file forces a full run (it is handled incrementally); `plugin-cache-producers.md` claimed plugin caches are unbounded (they share the 256 MB-capped LRU store per [ADR-54](docs/adr/54-cache-slimming.md)); `public-api.md` named a non-existent `protocols` manifest member (now `protocol_contracts`); `diagnostic-shape.md`'s "before v0.1.0" lock note was updated to the [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) v1.0 freeze; `Dynamic[Top]` was normalised to the engine's actual `Dynamic[top]` rendering throughout; and two stale source comments that had seeded doc errors were corrected in the same pass.

## [0.2.1] - 2026-06-19

v0.2.1 continues the 0.2.x evaluation line with detection and configuration polish. The headline is a `Gemfile.lock`-gated ActiveSupport RBS overlay that silences the systematic core-extension false positives a Rails project saw on `3.minutes` and friends, resolving the v0.2.0 evidence-tier feedback at its source ([ADR-72](docs/adr/72-gemfile-lock-gated-rbs-overlays.md)). `rigor check` now warns when a configuration value silently resolves to nothing, and `rigor coverage` gains a fused static-plus-dynamic protection map ([ADR-70](docs/adr/70-fused-protection-coverage.md)). Constant folding reaches a few more pure scalar and structural methods, and fixes include a gem-packaging bug that left installed gems without their bundled RBS data.

### Added

- **[inference]** Rigor now auto-loads a bundled ActiveSupport core-ext RBS overlay when `activesupport` is in your `Gemfile.lock` but ships no RBS, so core-extension calls like `3.minutes`, `6.days`, `"x".underscore`, and `hash.symbolize_keys` stop firing a false `call.undefined-method` on a Rails project with no plugin or config ([ADR-72](docs/adr/72-gemfile-lock-gated-rbs-overlays.md)).
  - It is gated on the gem actually being locked, so a plain-Ruby project with no `activesupport` still gets the genuine `undefined method 'minutes' for 3`, and a real typo on a core type (`5.minuets`) keeps firing at `evidence_tier: high`.
  - This resolves the v0.2.0 `evidence_tier` calibration report at its source rather than relabelling the firings — the tier never feeds severity, so a down-tier would have left the false error on screen.
  - The overlay stands down automatically when the opt-in [`rigor-activesupport-core-ext`](plugins/rigor-activesupport-core-ext/) plugin is loaded, and is bypassed if you supply ActiveSupport RBS yourself (via `rbs collection install` or `signature_paths:`).
- **[inference]** A few more pure, deterministic methods on literal receivers now fold to a precise `Constant` or `Tuple` instead of the widened RBS type.
  - `Symbol#name` / `#id2name` fold to `Constant[String]` and `#intern` to `Constant[Symbol]`, the natural siblings of the already-folded `to_s` / `to_sym`.
  - `Integer#finite?` / `#infinite?` / `#nonzero?` fold (closing the consistency gap with `Float`, which already folded `finite?` / `infinite?`), as do `Float#nonzero?` / `#integer?`.
  - `String#grapheme_clusters` lifts to a per-grapheme `Tuple`, the extended-grapheme-cluster sibling of the already-folded `chars`.
- **[cli]** `rigor check` now warns when a configured value silently resolves to nothing — the typo class that loads zero signatures or leaves a suppression inert, where the only symptom is a confusing downstream error.
  - Previously each of these was filtered without a word: a missing RBS path, for instance, turned every call into the types it was meant to cover into a `call.undefined-method` at `evidence_tier: high`, so a one-character mistake could read as hundreds of real errors.
  - The audit covers `signature_paths:` (missing, a non-directory, or holding no `.rbs`), `libraries:` (a name RBS does not recognize), `disable:` / `severity_overrides:` (a rule id naming no actual rule under a built-in family; plugin and `rbs_extended.*` ids are left alone), and `bundler.bundle_path` / `bundler.lockfile` / `rbs_collection.lockfile` (a configured path that does not exist).
  - Each finding is emitted per entry on STDERR and rides into the `--format=json` payload under a `config_warnings` array (each tagged with a `kind`), so CI and framework consumers can assert on them.
  - It stays a warning, not a hard error: an unset default (auto-detected `<root>/sig`, auto-detected bundle) is never warned about, so a correctly-configured project sees nothing.
- **[cli]** `rigor coverage --protection --mutation --with-tests` adds a *dynamic* protection axis: for every type-visible mutation Rigor's analysis misses, it runs your test suite and reports whether a test catches it, fusing static type-protection and dynamic test-protection into one map ([ADR-70](docs/adr/70-fused-protection-coverage.md)).
  - Each dispatch site is classified type-protected, test-protected, or unprotected (the ranked "add a type or a test here" list), so the report names the cheaper missing axis instead of a single number.
  - The test runner is the `--test-command` hook (default `bundle exec rake`) run with Bundler's environment stripped; the suite must pass on clean code first, and the expensive run is paid only for mutants the type checker did not already kill.
  - `--include-dynamic` extends the overlay to `Dynamic`-receiver call sites, where a test is the only possible protection, and `--limit N` (with `--seed`) caps the measurement to a deterministic per-file sample.

### Fixed

- **[cli]** A `severity_overrides:` (or `disable:`) value written as a bare `off` in `.rigor.yml` no longer crashes `rigor check` with a raw `NoMethodError` backtrace.
  - YAML 1.1 parses unquoted `off` / `on` / `no` / `yes` as booleans, so `flow.dead-assignment: off` reached the loader as `false`; it now raises a clear `ArgumentError` that names the key and tells you to quote the severity (e.g. `"off"`).
- **[inference]** An option hash populated through a helper inside an escaping block — the `OptionParser.new { |opts| define_options(opts, options) }` idiom — no longer keeps its literal default values, so a later guard like `if options[:mutation] && !options[:protection]` stops folding to a false `flow.always-truthy-condition` warning.
  - The escaping-block content floor ([ADR-57](docs/adr/57-self-call-return-adoption.md)) now also follows a self-call in the block body that escape-mutates one of its arguments, not just direct writes in the block itself.
- **[packaging]** The published gem now ships Rigor's bundled RBS data — the `data/vendored_gem_sigs/` per-gem stubs (nokogiri, pg, redis, mysql2, and others) and the `data/core_overlay/` core reopenings, including the v0.2.0 StringScanner fix.
  - The gemspec's `spec.files` glob matched only `data/builtins/**/*.yml`, so an installed `rigortype` gem silently lacked these `.rbs` files and produced extra `call.undefined-method` false positives a from-source checkout did not.

## [0.2.0] - 2026-06-17

v0.2.0 is Rigor's first publicly-announced (general / evaluation) release, governed by [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md): it publishes the enumerated public-compatibility surface ([`docs/compatibility.md`](docs/compatibility.md)) as a trial commitment toward the v1.0.0 freeze, and ships a bleeding-edge opt-in for previewing a future major's diagnostics. The headline is detection "teeth" — `call.undefined-method` and `call.argument-type-mismatch` now reason about union, refinement, and multi-overload receivers they used to bail on, surfaced by a new analyzer self-testing harness ([ADR-62](docs/adr/62-mutation-testing-teeth-measurement.md)) and measured by a new type-protection coverage report ([ADR-63](docs/adr/63-type-protection-coverage.md)). It also widens constant folding to more builtin methods and predefined constants, folds `Struct.new` value objects, and adds agent-facing diagnostic metadata (an evidence tier and a documentation URL). Fixes include several real-world false-positive removals plus a handful of crash and packaging issues from developer feedback.

### Added

- **[inference]** `call.undefined-method` now fires on a *union* receiver when the method is absent on every arm (`String | Symbol` responds to a method only if both do), where the scalar existence check previously bailed on any union.
  - Conservative by construction: any arm that is `Dynamic`, an unknown / open / source-declared class, the generic `Class` / `Module` metaclass, or `nil`-bearing suppresses it, and the union must have at least two distinct arm classes (a same-class shape join like `Hash[K1, V1] | Hash[K2, V2]` is left to the scalar rule).
- **[inference]** Refinement and difference receivers now get call-rule teeth: a bounded-integer (`positive-int`, `int<1,5>`), string-family (`non-empty-string`), or non-empty / non-zero (`non-empty-array`, `non-zero-int`) receiver resolves to its base class for dispatch, so `call.undefined-method`, `call.wrong-arity`, and `call.argument-type-mismatch` reason about it instead of bailing on "no single concrete class".
- **[inference]** `call.argument-type-mismatch` now fires on an argument to a multi-overload method that no overload accepts — both a `nil` argument to a parameter that rejects nil and a wrong-*typed* (non-nil) argument — closing the largest false-negative cluster the mutation sweep surfaced ([ADR-64](docs/adr/64-non-nil-argument-type-mismatch.md)).
  - The nil channel reports `5 * nil`, `"a" + nil`, and `[1, 2, 3].fetch(nil)`, deciding nil-admittance on the RBS parameter type so it sees through interface aliases (`string`, `int`) and generic aliases (`range[int?]`); a declaration-sourced ivar `nil` stays excused ([ADR-58](docs/adr/58-ivar-field-typing.md)).
  - The non-nil channel reports `[1, 2, 3].fetch("x")` while leaving `.fetch(2.0)` clean (`Float#to_int`), excludes the `coerce`-dispatch operators (`+ - * / < …`, where a non-`Numeric` argument may still be valid), and fires only on an argument typing to a single concrete RBS-known class that every overload rejects.
- **[inference]** RBS class aliases (`class Mutex = Thread::Mutex`, and any `X = Y`) now resolve to their target's method surface, so dispatch types precisely and a genuinely missing method on the alias fires `call.undefined-method`.
- **[inference]** The constant-folding catalogue covers more pure builtin methods, so more statically-known expressions fold to a precise `Constant` or `Tuple` (each verified against the live MRI value).
  - Scalar folds: `Integer#[]` / `#ceildiv` / `#to_r` / `#to_c`, `Float#quo` / `#to_r` / `#rationalize`, `String#casecmp` / `#casecmp?` / `#sum`, `Symbol#succ` / `#next`, and the full `Rational` and `Complex` arithmetic / comparison surfaces.
  - Collection folds lift to a `Tuple`: `String#codepoints`, `Integer#digits(base)` / `#gcdlcm`, `String#partition` / `#rpartition`, `Range#sum` / `#first(n)` / `#last(n)` / `#take(n)`, and `Array#minmax` / `#join`.
  - A NaN-defence guard declines any fold whose result is a NaN `Float` (or a NaN-bearing `Complex`), whose non-reflexive `==` would corrupt union dedup.
- **[inference]** Predefined Ruby / stdlib constants now receive refined types instead of the widest RBS declaration.
  - Tier 1 folds the cross-implementation-invariant numerics — `Math::PI`, `Math::E`, and the IEEE 754 limits `Float::INFINITY` / `MAX` / `MIN` / `EPSILON` — to `Constant[Float]`, so `Math::PI * 2` folds precisely (`Float::NAN` is excluded).
  - Tier 2 resolves core / stdlib constants like `RUBY_VERSION` to a refined `String` carrier via the analyzer's own runtime, while project-defined constants fall through unchanged.
- **[inference]** `Struct.new` value objects now fold member reads to precise types, the mutable sibling of the `Data.define` folding from v0.1.17 ([ADR-48](docs/adr/48-data-struct-value-folding.md)).
  - `Struct.new(:x, :y).new(1, 2).x`, `Point.new(1, 2).x`, and a bound `p = Point.new(1, 2); p.x` all type `1`, with positional and `keyword_init: true` construction and the `.members` / `.to_h` / `.deconstruct` / `.with` projections.
  - Because a `Struct` is mutable, a read off a fresh instance always folds but a read off a bound local folds only when the local is provably never mutated, aliased, or escaped — anything written, aliased, or passed away widens to `Dynamic[top]` rather than fold a stale value.
- **[cli]** `rigor coverage --protection` reports type-protection coverage — not how precise the types are but whether Rigor could catch a bug at each dispatch site — with a ranked "add a type here" list, a `--threshold` gate, and `--format json` ([ADR-63](docs/adr/63-type-protection-coverage.md)).
- **[cli]** `rigor coverage --protection --mutation` measures protection directly by introducing type-visible breakages at each dispatch site and reporting how often Rigor catches them, defaulting to the git-changed files ([ADR-63](docs/adr/63-type-protection-coverage.md) Tier 2).
  - The framing is always effectiveness / where-to-add-a-type, never raw "survival"; it productizes a supported subset of the dev-only mutation harness ([ADR-62](docs/adr/62-mutation-testing-teeth-measurement.md)).
- **[inference]** `rigor coverage --protection` now credits call-site-inferred parameter types, so an undeclared `def` parameter that flows into a receiver counts as protected instead of reading as `Dynamic` ([ADR-67](docs/adr/67-parameter-type-inference.md)).
  - The inference is precision-additive — it lives only as a method-body local, never an RBS contract, so it cannot fire a parameter-boundary diagnostic at a caller — and a `check` run stays byte-identical (only the protection scan consults it).
- **[cli]** `rigor check --bleeding-edge[=ids]` / `--no-bleeding-edge` override the configured `bleeding_edge:` selection for a single run, with the same CLI-over-config precedence as `--workers` ([ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) § WD2).
  - The overlay is empty in this release, so the flag is a no-op on diagnostics today; inspect the overlay and the active selection with `rigor show-bleedingedge`.
- **[cli]** Every built-in diagnostic now carries an `evidence_tier` (`high` / `medium` / `low`) and a stable `documentation_url` on `rigor check --format json` and via `rigor explain` ([ADR-65](docs/adr/65-diagnostic-evidence-tier-and-doc-url.md)).
  - The tier is Rigor's own confidence that a firing is a true positive, derived from the rule's gates; it is orthogonal to severity and never feeds gating, only routing attention (filter with `jq '.diagnostics[] | select(.evidence_tier == "high")'`).
- **[cli]** `rigor check --coverage` adds a type-precision coverage block to a check run, so one run reports both what fired and how much of the analyzed surface Rigor could type; it is off by default.
- **[environment]** `bundler.auto_detect` now also honours a user-global Bundler path (`~/.bundle/config`) as a last resort when a project has no in-tree bundle, resolving it relative to the project root and only when it points at a real directory.

### Changed

- **[inference]** `numeric-string` now means any single complete Ruby numeric literal — exactly the syntax that evaluates to a `Numeric` — rather than the previous signed-decimal-only definition, by delegating the predicate to the Prism parser.
  - It accepts hex / octal / binary integers, underscore separators, scientific floats, and the `r` / `i` suffixes while rejecting doubled signs, partial literals, and non-ASCII digits; two narrowings that relied on the old digit-only meaning (`Integer(numeric-string)` and `numeric-string#to_i`) were made sound for the wider grammar.

### Fixed

- **[inference]** A reference to a constant resolved through a `const_missing` hook whose optional library is absent (e.g. `Digest::UUID`) no longer crashes the whole run with `LoadError`; the lookup now resolves each path segment without triggering autoload side effects and rescues `LoadError` as a safety net.
- **[inference]** A `StringScanner` named-capture access (`scanner[:key]`) no longer false-fires `call.argument-type-mismatch`; a core overlay supplies the `(Integer | String | Symbol)` index overload that the pinned `rbs` 4.0.2 gem omits (newer `ruby/rbs` already carries it), so the new multi-overload argument check sees the `Symbol` / `String` form as valid.
- **[inference]** A local conditionally assigned across an `if / elsif / else: raise` chain is no longer false-flagged as possibly `nil` when one arm is `Dynamic`-typed and another concrete.
  - The inner `elsif … else raise` returned the bare predicate-narrowing scope with the local unbound, so the outer `if`'s merge nil-injected it; both the `if` and `unless` early-exit paths now carry the executed then-body's scope forward, mirroring the `case`/`when` rule. Surfaced by the [liquid v5.x regression sweep](docs/notes/20260616-liquid-v5.x-regression-sweep.md).
- **[inference]** A `break`-path binding inside a `for` / `while` / `until` loop is no longer dropped from the post-loop scope, fixing a false `flow.always-truthy-condition` on the common "set a flag and break" search idiom.
  - The scope at each `break` is joined into the loop continuation — precise, not a syntactic over-approximation, and lexically scoped so a `break` in a nested loop or block does not leak. Design in [`docs/notes/20260615-loop-break-binding-propagation-design.md`](docs/notes/20260615-loop-break-binding-propagation-design.md).
- **[inference]** Non-reproducible builtin results are no longer folded to a `Constant`: `#hash` (salted with a per-process SipHash seed) and `String#crypt` (the platform `crypt(3)`).
  - Folding either baked one analysis process's value into the inferred type and the on-disk cache, wrong in every other process; a universal guard now blocks `hash` / `object_id` / `__id__` across every catalogued class, while the deterministic siblings (`inspect`, `to_s`) still fold.
- **[inference]** `Integer(decimal-int-string)` and `decimal-int-string#to_i` / `#to_int` no longer narrow to `non-negative-int`, since the carrier admits a leading sign (`Integer("-7") == -7`); they now yield the full signed `int` range, keeping a precise `IntegerRange` for downstream narrowing.
- **[inference]** The opt-in `call.self-undefined-method` rule ([ADR-24](docs/adr/24-self-method-call-resolution.md) slice 4, off by default) sheds three false-positive classes its corpus evaluation surfaced — universal-base receivers (`Object` / `Kernel`), abstract / template-method base classes (suppressed when the missed method is defined on a known subclass), and dynamic non-constant superclasses (`< DelegateClass(Array)`).
  - All three are pure narrowings (a genuine typo still fires); the rule still ships off by default, since the evaluation found further false-positive classes (C-extension and metaprogrammed surfaces) the per-class scan cannot enumerate.
- **[sig-gen]** `rigor sig-gen --write` no longer emits a `module` wrapper where the source declares a compact-path `class` (`class Foo::Bar`), a `class` / `module` collision that aborted the whole RBS env build with `RBS::DuplicatedDeclarationError`.
  - The writer now folds every candidate's per-file namespace-kind map into one run-level view before grouping, so an authoritative `class Foo` recorded elsewhere governs the wrapper keyword. Surfaced by the 2026-06-16 protection-uplift pilot sweeping the `parser` gem.
- **[cli]** `rigor explain call.unresolved-toplevel` now resolves — the [ADR-34](docs/adr/34-toplevel-unresolved-self-call-default.md) rule was missing from the catalogue despite being live since v0.1.14 — and a completeness spec now asserts every rule has a catalogue entry.
- **[packaging]** The Docker build-context ignore file is scoped to the Dockerfile (`Dockerfile.dockerignore`) instead of a repo-wide `.dockerignore`, so external tools embedding the rigor source via BuildKit `--build-context` no longer get an empty context.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.2.9...HEAD
[0.2.9]: https://github.com/rigortype/rigor/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/rigortype/rigor/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/rigortype/rigor/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/rigortype/rigor/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/rigortype/rigor/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/rigortype/rigor/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/rigortype/rigor/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/rigortype/rigor/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/rigortype/rigor/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/rigortype/rigor/compare/v0.1.19...v0.2.0
