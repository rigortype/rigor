# Rigor Roadmap

Forward-looking commitments: what's actively in flight, what's
planned next, what's deliberately out of scope.

This file is **planning material**, not a release log. For the
"what shipped" record, see [`CHANGELOG.md`](../CHANGELOG.md)
(active `0.1.x` cycle) and
[`docs/CHANGELOG-0.0.x.md`](CHANGELOG-0.0.x.md) (archived `0.0.x`).

When this file disagrees with an ADR or spec, the ADR / spec
binds and this file is out of date.

## Released milestones (pointers only)

Full release notes live in `CHANGELOG.md`; the planning envelopes
that shaped each cut are preserved in git history (see
`docs/MILESTONES.md` at the commit that renamed it to `ROADMAP.md`).

| Version | Released | Theme |
| --- | --- | --- |
| v0.0.3 — v0.0.9 | 2026-05-02 → 2026-05-05 | Type vocabulary, inference engine, persistent cache. See [`docs/CHANGELOG-0.0.x.md`](CHANGELOG-0.0.x.md). |
| v0.1.0 | 2026-05-07 | First plugin contract (six slices); seven worked examples. See `CHANGELOG.md` § `[0.1.0]`. |
| v0.1.1 | 2026-05-08 | Literal-string narrowing depth, cross-plugin API, plugin authoring DX. See `CHANGELOG.md` § `[0.1.1]`. |
| v0.1.2 | 2026-05-09 | Example plugin return-type migration, engine depth follow-up. See `CHANGELOG.md` § `[0.1.2]`. |
| v0.1.4 | 2026-05-14 | ADR-10 / ADR-11 / ADR-13 deferred queues, ADR-14 `rigor sig-gen` end-to-end, `Type::BoundMethod` carrier, eighteen worked plugin examples. (The v0.1.3 commitment envelope absorbed extra tracks before cut and shipped as v0.1.4.) See `CHANGELOG.md` § `[0.1.4]`. |
| v0.1.5 | 2026-05-16 | ADR-15 Ractor migration end-to-end (Phases 1–4c + 4b.x), real-world Rails survey (14 projects, 31,840 files) driving production improvements (vendored gem RBS, ActiveSupport core_ext opt-in bundle, Bundler-aware sig discovery), ADR-16 macro / DSL expansion substrate (closes O2 at the WD13 floor), O4 Layer 3 slices 1+2+3 (`Gemfile.lock` parse + `rbs_collection.lock.yaml` awareness + missing-gem `:info` diagnostic), DEFAULT_LIBRARIES stdlib coverage expansion (1,273 → 1,427 RBS classes), `is_a?(C)` lexical-nesting constant resolution, twenty-four worked plugin examples. See `CHANGELOG.md` § `[0.1.5]`. |
| v0.1.6 | 2026-05-19 | ADR-12 / ADR-17 / ADR-18 floors + worked consumers; editor mode v1 + Language Server v1/v2; ADR-20 Lightweight HKT; ecosystem plugins + the `rigor-rails` meta-gem scaffold. See `CHANGELOG.md` § `[0.1.6]`. |
| v0.1.7 | 2026-05-20 | ADR-22 baseline mechanism (slices 1+2) + project-onboarding groundwork; survey-driven plugin / engine false-positive fixes; Pillar 2 "your specs are types" slices 1+2+3. See `CHANGELOG.md` § `[0.1.7]`. |
| v0.1.8 | 2026-05-21 | Mastodon-survey false-positive reduction: ADR-15 fork-based worker pool (the active `workers > 0` backend), ADR-23 `rigor triage` diagnostic-triage subcommand, ADR-24 implicit-self method-call resolution. See `CHANGELOG.md` § `[0.1.8]`. |

## Release strategy — the road to v0.2.0

The `0.1.x` line is the **preview** line. The `0.2.x` line opens
the **evaluation** line — still not a formal / GA release, but the
first publicly announced version meant for trial deployment in
real products.

| Line | Role |
| --- | --- |
| `0.1.x` | Preview. **v0.1.9 is the last preview cut — a near-complete (準完成版) release** that closes the outstanding preview-track commitments. |
| `v0.2.0` | **First evaluation release.** Publicly announced as the first version intended for real-product trial deployment; opens the evaluation period and invites outside feedback. |
| `0.2.x` | Evaluation line. Not yet a formal version, but the goal is to bring **every planned feature except the Ractor concurrency track** to high completion / production quality. |

### v0.1.9 — last preview (near-complete)

The final `0.1.x` cut. It closes the preview-track commitments so
v0.2.0 starts the evaluation line from a near-complete base:

- The **external-user SKILL trio** — `rigor-project-init`,
  `rigor-baseline-reduce`, and the external-author
  `rigor-plugin-author` variant (see § "Agent workflows / SKILLs"
  below; [ADR-22 WD8](adr/22-baseline-and-project-onboarding.md)).
- **ADR-22 baseline slice 5** — `rigor baseline regenerate` plus
  the `--baseline-strict` CI gate.
- Tightening defaults (plugin / severity / baseline-rule
  recommendations) against the empirical project-survey data
  collected across the v0.1.7 / v0.1.8 cycles.

Treated as a release candidate for the v0.2.0 evaluation line:
the bar is "no known release-blocking defect", not "every
demand-driven backlog item closed".

### v0.2.0 — first evaluation release

The first publicly announced version, intended for trial
deployment in real products. v0.2.0 is an **evaluation** release,
not a GA / formal version — it opens the evaluation period and
solicits outside feedback. Gating conditions (the v0.1.x
"out of scope today" list this release absorbs):

- The ADR-2 plugin-contract surface stabilised enough to support
  external `rigor-*` gems outside this monorepo.
- The subtree-split / RubyGems publishing flow exercised for at
  least the `rigor-rails` family.
- The SKILL trio shipped (v0.1.9) so newcomers have an onboarding
  path.

### v0.2.x — high-completion evaluation line

Across the `0.2.x` series the goal is to bring the planned
feature set to high completion / production quality. The
demand-driven backlog under § "Future cycles" below is, under
this plan, the **v0.2.x completion target** rather than an
open-ended queue — every item there is in scope for `0.2.x`
**except the Ractor concurrency track**.

**Ractor is deliberately excluded.** ADR-15's Ractor worker pool
was found unusable on Ruby 4.0.x (Ruby Bug #22075 plus a
deterministic `Ractor::IsolationError`); v0.1.8's fork-based pool
is the active backend. The Ractor pool stays parked behind
`RIGOR_POOL_BACKEND=ractor` and ADR-15 § OQ1; completing it is
NOT a `0.2.x` goal and waits on upstream CRuby fixes.

## v0.1.6 — shipped 2026-05-19 (planning envelope retained below)

Theme: **three accepted-and-implemented ADRs unlock per-call-site precision uplift through cross-plugin facts, project-side monkey-patch recognition, and a foundation dry-rb plugin — plus the first two cuts of editor / IDE integration (editor mode v1 + Language Server v1), substantial LSP / spec-suite performance wins, and four new ecosystem plugins (rigor-dry-schema, rigor-graphql, rigor-dry-validation) plus the `rigor-rails` meta-gem scaffold.** Commits `3c99eed` → `8530856`.

Full slice-by-slice detail in `CHANGELOG.md` § `[Unreleased]`. Six v0.1.6 tracks:

1. **ADR-12 / ADR-17 / ADR-18 floors + worked consumers** — `rigor-dry-types` slices 1–4 (full alias coverage incl. transitive); `rigor-dry-schema` slices 1+2 (recognition + `each` list slot); `rigor-dry-validation` slice 1 (Contract recognition + RBS overlay); ADR-17 slices 1+2+3a+4 (pre-eval plumbing, monkey-patch registry, dispatcher tier, glob); ADR-18 slices 1+2+3+5 (`returns_from_arg:` DSL + end-to-end dry-struct uplift); ADR-10 Phase B heuristic return-type extraction.
2. **Editor mode v1 + Language Server v1/v2 + LSP polish/performance** — `--tmp-file`/`--instead-of` paired flags + `BufferBinding`; `rigor lsp` subcommand (8-slice v1; packaging per [ADR-19](adr/19-language-server-packaging.md)); v2 type-aware hover + `textDocument/completion`; LSP follow-ups (signatureHelp + hash-key completion + editor guide [`docs/lsp-integration.md`](lsp-integration.md) + e2e spec); LSP polish (6 slices; 9 capabilities total); LSP performance trifecta (`ProjectScan` pre-pass snapshot cache + Environment sharing + plugin cache descriptor correctness fix). Design docs: [`docs/design/20260516-editor-mode.md`](design/20260516-editor-mode.md), [`docs/design/20260517-language-server.md`](design/20260517-language-server.md), [`docs/design/20260517-lsp-hover-completion.md`](design/20260517-lsp-hover-completion.md).
3. **Ecosystem plugins** — `rigor-graphql` slices 1+2a–2d (Schema::Object / Enum / InputObject / Mutation; four cross-plugin facts; Tier 3D — closes the last pending Tier 3 slot); `rigor-dry-schema` 1+2; `rigor-dry-validation` 1; `rigor-rails` meta-gem scaffold; `rigor-minitest`; `rigor-rspec-rails`; `rigor-shoulda-matchers`. 29 `plugins/` + `examples/` entries total.
4. **ADR-20 Lightweight HKT** — 32 commits; carrier + parser + full § D3 conditional grammar; `JSON.parse` / `YAML.safe_load` / `CSV.parse` / `CSV.read` `METHOD_RETURN_OVERRIDES`; three user-authoring paths (`.rbs` directives / plugin manifest / builtins). Handbook chapter 12. See [ADR-20](adr/20-lightweight-hkt.md).
5. **Engine improvements** — receiver-affinity pre-sort + `Acceptance` ancestor-chain fallback (BigDecimal/Numeric false positives −25); `StaticReturnRefinements` tier; parameter default scope fix (−97% false positives on prism-1.9.0); `Module.new`/`Class.new` block walk; module-mixin `self_type`; cross-file class discovery pre-pass; `FlowContribution::Fact :local`; Pillar 2 slices 1+2+3 (rigor-rspec matcher narrowing + `let`/`subject` cross-binding + factory model-class); RBS overlays (prism / bundler / rubygems / did_you_mean). References survey (`references/ruby/lib`) 1756 → 354 errors (−80%).
6. **Spec-suite + repository layout** — parallel-by-default (`217s → 60s` on 12-core); content-keyed sig dir (runner_spec 39.6s → 25.4s); opt-in shared plugin cache (sorbet_plugin_spec 13.1s → 4.7s); repository layout split (`plugins/<id>/` for 27 production plugins; `examples/<id>/` for 5 walkthroughs).

Every committed v0.1.6 track is purely additive (no behaviour change for existing CLI consumers); the substrate amendment (ADR-18) preserves the pre-v0.1.6 `returns:` semantics under the new three-tier fallback.

### Out of scope for v0.1.6 (queued, demand-driven)

- **ADR-17 slice 3b** (per-file cache descriptor), slices 5 / 6 (full-project 2-pass / plugin-API hook).
- **ADR-18 slice 4** (TraitRegistry parity for `returns_from_arg:`) + chained-call argument extension (`Types::String.constrained(...)` chain-head resolution).
- **ADR-12** continuations: `rigor-dry-types` slice 4 + `rigor-dry-schema` slice 1+2 + `rigor-dry-validation` slice 1 ALL LANDED (CHANGELOG `[Unreleased]` § Added). Remaining: `rigor-dry-schema` slice 2+ surface beyond `each` (typed `result.to_h` synthesis via ADR-16 Tier C / per-row diagnostics; demand-driven), `rigor-dry-validation` slice 2 (params-block typing via `:dry_schema_table` consumption) + slice 3 (`json { ... }` parity); `rigor-dry-monads` (still needs `Result[T, E]` / `Maybe[T]` carrier decision — see slicing plan).
- **ADR-10 option C** (lazy / on-demand per-call gem-source inference).
- **ADR-13 resolver-chain wiring** for synthetic-method tier `returns:` strings (utility-type returns).
- **ADR-16 slice 5b** (Tier D engine integration).
- **Editor mode follow-ups** ([`docs/design/20260516-editor-mode.md`](design/20260516-editor-mode.md) § "Out of scope for v1"): per-file diagnostic cache (the lever to upgrade single-file scope (option A) → project-scope with substitution (option B)), project-context snapshot cache for pre-pass reuse, multi-buffer (`--buffer A=B --buffer C=D`), `--also=dep1,dep2` caller-declared dependents, LSP daemon / file-watch.
- **`rigor-graphql` slices 1+2a+2b+2c+2d ALL LANDED** (Tier 3D — `Schema::Object` + list wrappers + `Schema::Enum` + `Schema::InputObject` + `Schema::Mutation` recognition, publishing four cross-plugin facts; CHANGELOG `[Unreleased]` § Added). Remaining future slices (resolver-method type-check, `<Type>.array` / `<Type>!` chain forms, string-form `field :foo, "User"` diagnostic, `Schema.execute(...)` result typing) demand-driven.
- **O4 Layer 3 per-gem-version cache** (slice 3 architecture; future Ruby::Box-style Bundler extension would raise priority).

## v0.1.7 / v0.1.8 — user-facing positioning track (shipped)

A three-pillar messaging framework drives README / handbook
front matter and shapes the v0.1.7 / v0.1.8 release narrative.
**Pillars 1 and 3 already ship-back from v0.1.5 / v0.1.6
inference + plugin / substrate work and are reflected in the
README lead from v0.1.6 onward; Pillar 2 needs the
implementation slices below before being promoted into the
README.**

| Pillar | Tag line | Status |
| --- | --- | --- |
| 1. Types as facts, not wishes | "Are the types in your code asserting facts, or are they lagging behind the implementation?" | Shipped (inference-first + `rigor sig-gen` + `tighter-return`). README lead reflects this from v0.1.6. |
| 2. Your specs are types | "Do you really need to write types? `spec/` is already type information." | Implementation track below. Promote into README when slices 1–3 land. |
| 3. Programmable inference beyond unions | "Union types aren't enough for type safety. Programmable inference makes metaprogramming and safety friendly." | Shipped (carrier zoo + plugin contract + ADR-16 substrate + ADR-18 per-call-site precision). README lead reflects this from v0.1.6. |

### Pillar 2 implementation track (shipped — slices 1+2+3 landed in v0.1.7)

Backing the "specs are types" narrative without overpromising
requires three concrete capabilities, additive on top of the
existing [`rigor-rspec`](../plugins/rigor-rspec/) and
[`rigor-factorybot`](../plugins/rigor-factorybot/) plugins:

- **Slice 1 — spec-derived flow facts from RSpec assertions.**
  `expect(x).to be_a(T)` / `eq(literal)` / `be_kind_of(T)` /
  `be_instance_of(T)` / `be_nil` / `be_truthy|falsey` inside
  `it` blocks contribute Rigor narrowing facts about `x` from
  the assertion onward. Closes today's gap where `rigor check`
  reads specs as opaque Ruby and misses both spec-internal
  bugs (assertions against the wrong variable) and spec-derived
  contracts (downstream calls in the same `it` body that would
  benefit from the narrowed receiver). Slice extends
  `rigor-rspec`; no core engine change. Six-matcher table the
  natural floor.
- **Slice 2 — `subject` / `let` cross-binding to the SUT.**
  When a `describe User do … end` body declares
  `subject { described_class.new(...) }` or
  `let(:user) { User.new(name: "a") }`, treat the block as
  evidence of constructor arity and per-attribute presence;
  feed back into `rigor-activerecord` / `rigor-factorybot`'s
  existing `:model_index` channel so `let`-introduced locals
  surface at the right carrier in downstream `it` bodies.
- **Slice 3 — factory definitions as struct-shape facts.**
  `rigor-factorybot` today validates factory CALLS; it does
  not publish the per-factory attribute set as an ADR-9 fact.
  Slice promotes `spec/factories/` into a `:factory_index` /
  `:factory_attributes` channel so `let(:user) {
  create(:user) }` yields a `User` carrier with the factory's
  attribute shape bound to the local. Composes with slice 2
  for the `let` ↔ factory chain.

Each slice is opt-in (manifest entry or `.rigor.yml` toggle);
no behaviour change for users not running `rigor-rspec` /
`rigor-factorybot`. Once the slices land the README's
"two design commitments" lead expands to three.

All three slices landed in the v0.1.7 cut (CHANGELOG § `[0.1.7]`),
ahead of the v0.1.8 ceiling; the README's "two design commitments"
lead has expanded to three.

## Future cycles (not committed to a specific release)

Items that have surfaced across v0.1.x work and that the next implementer benefits from seeing without re-reading the full thread.

### Type-language / engine
- **O2 — macro-template + heredoc-Ruby expansion.** Substrate floor + precision promotion delivered through [ADR-16](adr/16-macro-expansion.md) slices 1–5a + 7 (commits 584ae85…56706a5) + slice 6a-TierB / 6b-TierC precision (commits d174fff / d7b1943): Tier A (block-as-method) + Tier B (trait-inlining registry) + Tier C (heredoc template) engine integration through a new `SyntheticMethodIndex` + pre-pass scanner; Tier D (external-file inclusion) ships contract only with engine integration deferred per the slice-5a deferment; Concern (`included do`) re-targeting handled in the scanner; **slice 6** precision promotion routes Tier B emissions through their `origin_module:` provenance via `RbsDispatch.try_dispatch` (Devise's `valid_password?` returns `bool` now, not `Dynamic[T]`) and Tier C plain-class-name `returns:` strings via `environment.nominal_for_name`. Three worked consumers landed: `rigor-sinatra` (Tier A), `rigor-dry-struct` (Tier C), `rigor-devise` (Tier B). Remaining items: **slice 5b** (Tier D engine — narrows top-level `self_type` and pre-binds `bound_ivars` for matched external files; queued, demand-driven), **full ADR-13 resolver-chain wiring** (routes parameterised forms `Array[String]` / `Hash[K, V]` and plugin-supplied utility-type names `Pick<T, K>` through the resolver chain; queued, demand-driven). Grounding survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](notes/20260515-macro-expansion-library-survey.md).
- **Lightweight HKT (higher-kinded types) in DSL signatures.** [ADR-20](adr/20-lightweight-hkt.md) proposed (2026-05-18). Defunctionalised tag + `App[F, A]` carrier per Yallop & White 2014 / fp-ts, built on the conditional / indexed-access rows already listed in `docs/type-specification/rigor-extensions.md`. First concrete adopter: `JSON.parse`'s `untyped` slot (six implementation slices sketched, no slice scheduled). Cross-cutting adopters queued behind it: `rigor-lisp-eval` demo, `rigor-dry-monads` `Result[T, E]` / `Maybe[T]`, schema-driven `rigor-dry-validation` results.
- **`rigor:v1:conforms-to` directive.** Originally queued for v0.1.1's "Out of scope"; still open. Lets a method param accept any value satisfying a named structural interface.
- **LRU eviction for `Cache::Store`.** Per [ADR-6](adr/6-cache-persistence-backend.md), the persistent cache is sharded "no eviction" by design. Long-lived clones with config / dependency churn accumulate stale slots that only `make cache-clean` releases. LRU is queued, not committed.
- **Project-side monkey-patch pre-evaluation.** [ADR-17](adr/17-monkey-patch-pre-evaluation.md) accepted (2026-05-16). Slices 1+2+3a+4 LANDED in v0.1.6 (`pre_eval:` plumbing + registry + dispatcher tier + heuristic return-type + duplicate-declaration `:info` + glob support). Remaining demand-driven follow-ups: slice 3b (per-file cache descriptor), slice 5 (full-project 2-pass discovery), slice 6 (plugin-API hook).
- **ADR-13 resolver-chain wiring for the synthetic-method tier (ADR-16 follow-up).** ADR-13's `Plugin::TypeNodeResolver` chain is wired for `%a{rigor:v1:…}` payloads but NOT for substrate manifest `returns:` strings. Routing the synthetic-method tier through the chain unlocks utility-type-shaped Tier C returns (`Array[String]`, `Hash[K, V]`, `Pick<T, K>`). Deferred to demand from utility-type-shaped substrate consumers. (Note: per-call-site return-type lookup via cross-plugin facts shipped in v0.1.6 via [ADR-18](adr/18-substrate-per-call-site-return-type.md); the ADR-13 wiring above is the orthogonal "parameterised-form parser" extension.)
- **Struct / Data value folding.** Audit at [`docs/notes/20260523-struct-encoding-coverage.md`](notes/20260523-struct-encoding-coverage.md) (2026-05-23), the Phase 5 artifact of the type-coverage-uplift line. Precise `Struct` / `Data` member-access folding (`Point = Struct.new(:x, :y); Point.new(1, 2).x` → `Constant[1]`) cannot be reached by a dispatch-tier entry — it needs **two new carriers**: a struct-class carrier parameterised by its ordered member-name list (+ `keyword_init:` flag), and a class-tagged struct-instance carrier shaped like a `HashShape`. Plus a degradation contract for the `Struct.new` class-body block, positional vs. `keyword_init:` structs, and struct inheritance. ADR-worthy; the immutable `Data.define` sibling is flagged as the likely better first target (frozen instances simplify the soundness story). **Release undetermined.** `Encoding` value folding is recorded in the same audit as a *permanent exclusion* — a `Constant[Encoding]` carrier could only fold a vanishingly small surface (`.name` / `.dummy?`), real programs use `Encoding` as an opaque tag, and the carrier-zoo cost is not repaid; `Nominal[Encoding]` stays the answer.
- **Coverage-aware diagnostic posture (future concept — not yet designed).** Idea: modulate diagnostic *posture* by spec / test coverage — analyse optimistically where code is exercised by tests, stay conservative (or escalate attention) where it is not. This would operationalise the [`overview.md`](type-specification/overview.md) § "False-positive discipline" value (a running, test-covered program is evidence of its own correctness) by making "working" machine-readable and *localised*: a coverage map becomes a new fact source that modulates diagnostic severity post-inference, near `severity_profile` in the WD6 pipeline — type inference itself unchanged. Distinct from Pillar 2 (specs → type facts); this is coverage → confidence. **Concerns to resolve before this is designable:** (1) *coverage ≠ correctness* — "executed" is not "the type-relevant edge case was exercised and asserted", so an optimistic posture on covered code can suppress a real bug that a test runs but never asserts on; line coverage is especially weak, branch coverage better but still partial. (2) The two halves are **asymmetric in risk** — "uncovered → escalate" only re-prioritises and suppresses nothing (safe, pure upside), while "covered → suppress" carries the false-reassurance risk; a first slice should likely be the uncovered half only. (3) The coverage artefact (SimpleCov `.resultset.json` / the `Coverage` stdlib module) is an external fact source needing provenance + staleness handling, fail-soft when absent or stale. (4) Possible synergy with the [ADR-22](adr/22-baseline-and-project-onboarding.md) baseline — coverage could rank which baseline buckets are "untested, therefore review-worthy first". No ADR, no slice, no committed milestone — recorded here as a direction.

### Plugins / ecosystem
- **`rigor-graphql`** — Tier 3D plugin LANDED in v0.1.6 across slices 1+2a+2b+2c+2d: `Schema::Object` + list wrappers + `Schema::Enum` + `Schema::InputObject` + `Schema::Mutation` recognition, publishing four cross-plugin facts (`:graphql_type_table`, `:graphql_enum_table`, `:graphql_input_object_table`, `:graphql_mutation_table`). Metadata-recorder shape rather than ADR-16 substrate consumer (graphql-ruby's `field` DSL emits no Ruby methods — see [survey § "GraphQL-Ruby"](notes/20260515-macro-expansion-library-survey.md)). Future slices (resolver-method type-check, `<Type>.array` / `<Type>!` chain forms, string-form `field :foo, "User"` diagnostic, `Schema.execute(...)` result typing) demand-driven.
- **dry-rb adapter plugins** — [ADR-12](adr/12-dry-rb-packaging.md) accepted (2026-05-16): per-gem plugins + planned `rigor-dry-rb` meta umbrella, matching the Rails plugin family pattern. **Landed**: `rigor-dry-struct` (v0.1.5; v0.2.0 in v0.1.6 with ADR-18 precision uplift), `rigor-dry-types` (slices 1+2+3+4 in v0.1.6 — full alias coverage including transitive composition references with cycle detection), `rigor-dry-schema` (slices 1+2 in v0.1.6 — Schema declaration recognition + `each(<T>)` list slot), `rigor-dry-validation` (slice 1 in v0.1.6 — Contract recognition + RBS overlay). **Remaining**: `rigor-dry-schema` slice 2+ surface beyond `each` (typed `result.to_h` synthesis via ADR-16 Tier C / per-row diagnostics), `rigor-dry-validation` slice 2 (params-block typing via `:dry_schema_table` consumption) + slice 3 (`json` parity), `rigor-dry-monads` (needs ADR-3 amendment for `Result[T, E]` / `Maybe[T]` carrier — slicing options in [the slicing plan](design/20260517-dry-validation-slicing.md) § "Open observation"). Foundation survey under [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md).
- **ADR-10 — per-call return-type precision from gem source.** Walker currently catalogs only `(class_name, method_name) → kind` triples. Inferring per-method return types from gem source (so `mode: :full` could contribute richer than `Dynamic[Top]`) is a larger walker enhancement deferred until concrete user demand surfaces.
- **`rigor-sorbet` follow-ups beyond per-call-site sigil gating** — landed in v0.1.4. No outstanding queue items.
- **Plugin-contributed RBS signatures.** [ADR-25](adr/25-plugin-contributed-rbs.md) proposed (2026-05-21): an optional `signature_paths:` `Manifest` field lets a plugin gem contribute RBS directories, resolved by `Plugin::Loader` and merged into the RBS environment. Closes the gap that today forces an RBS-only bundle gem (`rigor-activesupport-core-ext`) to be hand-wired via a non-portable `signature_paths:` path. Three slices (manifest field + loader resolution + environment merge → convert `rigor-activesupport-core-ext` to a trivial plugin → `rigor-project-init` SKILL follow-through); additive to the pre-1.0 plugin contract, safe within v0.1.x. Companion follow-up (separate, smaller): extend `Environment::BundleSigDiscovery` auto-detection beyond the `vendor/bundle` / `.bundle/config` layouts to the default `bundle install` gem path.

### Editor / IDE integration
- **LSP — Ractor pool for parallel multi-buffer publishes.** Slice 8 in the LSP design doc enumerated TWO concerns: debouncing (landed) AND Ractor pool integration. The pool half stays demand-driven — requires refactoring `Analysis::Runner` to accept a pre-built persistent `Environment` so workers can be pre-warmed once at LSP `initialize` and reused across publishes. ProjectContext (slice 7) already gives publish + hover the warm-Environment win via the read-only `Cache::Store`; the dispatch-side parallelism (multi-buffer publish across cores) is the remaining lever. Demand-driven.
- **LSP — `textDocument/definition`** (slice 9 in the design doc, deferred). Needs a `Reflection`-side symbol index keyed on `FILE:LINE`. Demand-driven.
- **LSP — incremental `didChange` sync** (slice 10 in the design doc, deferred). Currently the server advertises `TextDocumentSyncKind::Full = 1` so each keystroke resends the whole buffer. Incremental (`TextDocumentSyncKind::Incremental = 2`) requires UTF-16 offset bookkeeping + per-edit application. Bandwidth is local stdio so the cost is in the parse, not the wire; demand-driven.
- **LSP — extended capabilities still queued** (post-v2 + post-follow-ups + post-polish): `textDocument/codeAction`, `textDocument/rename`, `textDocument/semanticTokens`, `textDocument/inlayHint`, `textDocument/definition` (slice 9 from LSP v1 design — needs Reflection symbol index), incremental `didChange` sync (slice 10 from LSP v1 design — UTF-16 offset bookkeeping), Ractor pool dispatch for parallel multi-buffer publishes (slice 8 second half from LSP v1 design — Runner refactor), multi-root workspaces, TCP / Unix-socket transport, snippet expansion, bare-name (implicit-self) completion, symbol completion, `ParameterInformation` offset-tuple labels for in-signature highlighting, `completionItem/resolve` deferred-payload, plugin-side completion contributions.
- **Editor mode option B — per-file diagnostic cache.** Today's editor mode ships option A (single-file scope): only the buffer produces per-file diagnostics. Upgrading to option B (PHPStan-shape: whole-project analysis with one substituted file, "only edited file + dependents reanalysed") needs a per-file diagnostic cache keyed on `(file digest, project Environment digest)`. ADR-17 slice 3b's per-file cache descriptor is the closest existing lever. Design: [`docs/design/20260516-editor-mode.md`](design/20260516-editor-mode.md) § "Scope choice". Demand-driven.
- **CLI editor mode — disk-backed `ProjectScan` snapshot cache.** Implementation pathway documented in [`docs/design/20260518-cli-disk-snapshot-cache.md`](design/20260518-cli-disk-snapshot-cache.md). Targets `rigor check --tmp-file=X --instead-of=Y` shell-out path: persists the project's pre-pass outputs (scanners + dep-source index + plugin-published facts) to `.rigor/cache/` keyed on `(config + plugin manifest + project file mtime+size + pre_eval mtime+size)` so warm CLI invocations skip pre-passes. Expected wins: -200ms (small project) to >-1.3s (large monorepo with substrate plugins) per CLI call. New invariants: `Plugin::FactStore` snapshot API, plugin-fact Marshal-friendliness. Five phases (Marshalable scan / key derivation / cache producer / Runner integration / FactStore snapshot API). Demand-driven; the LSP path already covers most editor cases at ≤5ms / publish, so this slice picks up when a concrete CLI shell-out editor extension reports the ~1s wall as a UX problem.
- **Editor mode — project-context snapshot cache for pre-pass reuse.** LANDED for the LSP path (v0.1.6, CHANGELOG `[Unreleased]` § Added). New `Rigor::Analysis::ProjectScan` value object + `Runner#prepare_project_scan` builder + `Runner.new(prebuilt:)` adoption path; the LSP's `ProjectContext` lazy-builds the snapshot and drops it on `invalidate!`. CLI editor mode (`rigor check --tmp-file`) does NOT yet consume the snapshot because each invocation is a fresh process — a disk-backed snapshot cache keyed on `(plugin-manifest digest, project file mtime + size list)` would let one-shot CLI invocations skip the pre-passes too. Demand-driven; the LSP-side win is the typical editor consumer.
- **Editor mode — `--also=path,path` caller-declared dependents.** Editor extension currently has to issue N single-file invocations to refresh dependents. A single invocation with `--also` would batch them. Trivial CLI extension; design notes in `docs/design/20260516-editor-mode.md`. Demand-driven.
- **Multi-buffer editor mode** (`--buffer A=B --buffer C=D`). The LSP v1 supersedes this for most use cases (LSP `BufferTable` already holds N buffers); remains relevant for non-LSP batch tooling. Demand-driven.

### Performance / scalability
- **O4 Layer 3 — `Gemfile.lock` parse + `gem_rbs_collection` version matching.** Sits on top of v0.1.5's `BundleSigDiscovery` MVP. The MVP's auto-skip list (`SKIPPED_GEMS_BY_DEFAULT`) becomes a versioned resolution table; rigor consumes `Bundler::LockfileParser` output + queries `ruby/gem_rbs_collection` for the best-matching version. Unblocked by O7's failure-memo (conflicts now warn rather than hang).
- **Fork-based file-level parallelism for `rigor check`.** Stackprof of warm `rigor check lib` shows ~50% inference, ~22% `Marshal.load`, ~17% GC. The Phase 4b Ractor path is the v0.1.5 parallelism story; a fork-based path remains a parallel (non-exclusive) option for hosts where Ractors are unavailable or where COW sharing of pre-warmed `Environment` blobs would beat per-Ractor env build.
- **Spec-suite runtime breakdown (2026-05-17 investigation; partially landed).** `make verify` default switched to parallel rspec (commit `086e507`): wall time 217s → 60s (3.6× on 12-core). A follow-on cycle confirmed the real bottleneck was **per-call RBS env rebuild on every `analyze(sig: …)`**: `Cache::Store` keys the env on `(path, sha256)` per `RbsDescriptor::FileEntry`, so each call's unique `Dir.mktmpdir`-rooted sig path forced a fresh ~1.8 s env build. **Helper-side fix landed** (`spec/support/runner_helpers.rb`): content-keyed sig dir + shared workspace for source-only calls. `runner_spec.rb` 39.6s → **25.4s isolated (-36%)**, `make verify` parallel 65.6s → **52.6s (-20%)** on 12-core. The two originally-queued levers stay open with smaller remaining headroom:
  - **(a) Share `Environment` across examples in `runner_spec.rb`** via `before(:context)` or a `let_it_be`-shaped helper. Now that the cache-key fix has cleared the sig-related component of the per-call cost, the remaining win is the Environment construction itself for the ~80 % of examples that hit the source-only fast path. Plugin variance per-example still complicates the share. Demand-driven; the helper-side fix already absorbed most of the headroom.
  - **(b) In-memory `Analysis::Runner.run_source(source:, path:, ...)` entry point.** Skips path expansion + the workspace chdir on every call; also a clean public API for embedders (LSP / editor mode) that today route through `Runner.new(configuration:).run`. Smaller incremental test delta (~5%) on top of the helper fix but useful as a stable public surface. Demand-driven.
- **In-memory `Analysis::Runner.run_source` entry point (public + test-only).** Same item as "Spec-suite runtime breakdown" follow-up (b) above; kept here for legacy cross-references.

### Sig-gen (ADR-14)
- **`update_existing` does not yet collapse sibling parent / child class blocks.** Gap (c)'s tree-builder fix lives in `Writer#render_new_file` (the create-new path). When updating an existing target file, `merge_class` resolves each candidate's `class_name` independently — flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout would require parsing the existing decl tree and rewriting it, which is out of scope for a follow-up fix. Users who want the canonical nested layout regenerate from scratch (delete the target sig file and rerun).

### Open research questions queued in ADRs
- **ADR-15 § OQ1** — per-Ractor `Cache::Store`-shared facade. Today each worker builds its own RBS env from cache; OQ1 explores sharing the in-memory env across workers via a shareable facade. Would lower the pool wall-clock crossover with sequential (currently around 1.3–1.8 K files).
- **ADR-13 § "Open questions"** — extending the shape-projection surface beyond the five core functions (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`). Authoritative when adding new mapped-type vocabulary.

### Agent workflows / SKILLs (committed: v0.1.9)

Three SKILLs target **end-users newly adopting Rigor on their own projects** (gem authors, application developers, project-private plugin maintainers running `gem install rigortype`). All three live under the **top-level `skills/` tree** — the slot vacated when `rigor-plugin-author` was re-homed to `.claude/skills/` in commit `1a3c342` — and follow the [agentskills.io](https://agentskills.io/) portable-skill conventions (self-contained `SKILL.md` + `references/`, absolute GitHub URLs for cross-repo refs, kebab-case names, public CLI surface only).

The v0.1.7 / v0.1.8 cycles were the lead-up — **collecting and addressing real-project error data** by running rigor against widening project surveys (the Mastodon survey drove the v0.1.8 false-positive-reduction work), tightening defaults from observed signal, and curating the SKILL trio's plugin / severity / baseline-rule recommendations against empirical evidence rather than first-principles guesses. v0.1.9 ships the trio itself as the last preview cut (see § "Release strategy — the road to v0.2.0").

- **`skills/rigor-project-init/`** — **LANDED (v0.1.9 cycle)** ([ADR-22 § "WD8"](adr/22-baseline-and-project-onboarding.md), [§ "SKILL: rigor-project-init"](adr/22-baseline-and-project-onboarding.md)). First-time onboarding workflow: Gemfile / Gemfile.lock walk → propose plugin set matching the detected stack (Rails / dry-rb / Sinatra / plain Ruby) → **adoption-mode choice** (acknowledge / baseline vs. strict — the realised shape of the severity-profile + baseline phases) → write `.rigor.dist.yml` → run `rigor triage --format json` → (acknowledge mode) write `.rigor-baseline.yml` AND the matching `baseline: .rigor-baseline.yml` line into the config → surface concentrated rules as likely real bugs → offer two escalation paths (project-private plugin / Rigor issue). SKILL.md + three `references/` modules; carries the `rigor-project-init` half of ADR-23 slice 3. Audience: a user typing `gem install rigortype` for the first time in their project.

- **`skills/rigor-baseline-reduce/`** — **LANDED (v0.1.9 cycle)** ([ADR-22 § "WD8"](adr/22-baseline-and-project-onboarding.md), [§ "SKILL: rigor-baseline-reduce"](adr/22-baseline-and-project-onboarding.md)). Ongoing-quality workflow: prioritise with the `rigor triage` hint catalogue + `rigor baseline dump --format json` (the `rigor-baseline-reduce` half of ADR-23 slice 3) → walk `.rigor-baseline.yml` rule-by-rule → sample 3-5 sites per rule → classify each (real bug / stylistic-safe / FP) → apply fix / per-line `# rigor:disable` / open a GitHub issue against rigor → refresh the baseline with `rigor baseline drift` + `rigor baseline regenerate`. SKILL.md + two `references/` modules. Audience: same as project-init; the natural next-session SKILL once a project has a baseline.

- **`skills/rigor-plugin-author/`** — **LANDED (v0.1.9 cycle)** (external-author variant — distinct from the `.claude/skills/rigor-plugin-author/` contributor SKILL). The plugin-authoring workflow re-targeted for users writing a plugin in their own repo — a standalone `rigor-`-prefixed gem (depending on `gem "rigortype"`) or a project-private plugin. SKILL.md + three `references/` modules covering gem-vs-project-private packaging, the `rigor-<id>` gemspec / path-gem / `RUBYLIB` activation, the `Rigor::Plugin::Base` skeleton + `diagnostics_for_file` walker + optional `flow_contribution_for`, `sig/` RBS, and fixture-based testing via `rigor check --format json` under RSpec or Minitest. Threads the pre-1.0 plugin-contract caveat throughout (pin `rigortype` `< 0.2.0`).

The trio forms a coherent **onboarding → ongoing-quality → extension** progression for the v0.2.0 external-user track. Out of scope today (v0.1.x): no external `rigor-*` gems exist outside this monorepo; ADR-2 plugin contract surface still pre-1.0; the subtree-split / RubyGems publishing flow stays internal — these are the gating conditions v0.2.0 absorbs.

Companion non-SKILL deliverable, ahead of the SKILL trio:

- **Baseline mechanism core** ([ADR-22](adr/22-baseline-and-project-onboarding.md)): PHPStan-shaped `.rigor-baseline.yml` recording `(file, rule, count)` snapshots (rule-ID default + opt-in message-pattern mode per WD1); `rigor check` filters baselined diagnostics with ALL-or-NOTHING per-bucket threshold semantics (WD4); explicit-loading-only (WD2 (b)) via `baseline: <path>` in `.rigor.yml`. New CLI subcommand family: `rigor baseline {generate, regenerate, dump, drift, prune}` + `--baseline=PATH` / `--no-baseline` / `--baseline-strict` on `rigor check`. Driven by the five-project survey ([`docs/notes/20260519-oss-library-survey.md`](notes/20260519-oss-library-survey.md)) where mature codebases carry hundreds-thousands of diagnostics on first contact. Slices 1 + 2 (file I/O + drift inspection) shipped in v0.1.7 — so the v0.1.7 / v0.1.8 survey work could collect empirical baseline data before the SKILLs land. **Slice 5 (`rigor baseline regenerate` + the `--baseline-strict` CI gate) LANDED in the v0.1.9 cycle**, completing the subcommand family; the SKILL trio also lands under v0.1.9, the last preview cut.

## Rails ecosystem plugins (running track, parallel to v0.1.x core work)

The full roadmap is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Summary of the running track:

**Already landed (released through v0.1.4 → v0.1.6):**

- **Tier 1**: [`rigor-rails-routes`](../plugins/rigor-rails-routes/) (`:helper_table`), [`rigor-rails-i18n`](../plugins/rigor-rails-i18n/), [`rigor-actionmailer`](../plugins/rigor-actionmailer/), [`rigor-activejob`](../plugins/rigor-activejob/).
- **Tier 2**: [`rigor-activerecord`](../plugins/rigor-activerecord/) (`:model_index`; associations / enums / scopes / validations / callbacks); [`rigor-actionpack`](../plugins/rigor-actionpack/) (routes / filters / renders / strong-params); [`rigor-factorybot`](../plugins/rigor-factorybot/) (Phase 1 (a)+(c)).
- **Tier 3**: [`rigor-pundit`](../plugins/rigor-pundit/), [`rigor-sidekiq`](../plugins/rigor-sidekiq/), [`rigor-rspec`](../plugins/rigor-rspec/) (Pillar 2 slices 1+2+3), [`rigor-actioncable`](../plugins/rigor-actioncable/), [`rigor-activestorage`](../plugins/rigor-activestorage/) (v0.1.5); [`rigor-graphql`](../plugins/rigor-graphql/) (v0.1.6 — Tier 3D, slices 1+2a–2d, four cross-plugin facts); [`rigor-minitest`](../plugins/rigor-minitest/), [`rigor-rspec-rails`](../plugins/rigor-rspec-rails/), [`rigor-shoulda-matchers`](../plugins/rigor-shoulda-matchers/) (v0.1.6).
- **Opt-in bundles**: [`rigor-activesupport-core-ext`](../plugins/rigor-activesupport-core-ext/) (opt-in RBS bundle); [`rigor-typescript-utility-types`](../plugins/rigor-typescript-utility-types/) (ADR-13 slice 6).
- **Meta-gem**: [`rigor-rails`](../plugins/rigor-rails/) (v0.1.6 scaffold; Tier 1+2 `add_dependency` declarations; `.rigor.yml` activation stays per-plugin).
- **ADR-16 substrate consumers (v0.1.5)**: [`rigor-sinatra`](../plugins/rigor-sinatra/) (Tier A), [`rigor-dry-struct`](../plugins/rigor-dry-struct/) (Tier C; v0.2.0 ADR-18 precision uplift), [`rigor-devise`](../plugins/rigor-devise/) (Tier B).
- **dry-rb foundation (v0.1.6)**: [`rigor-dry-types`](../plugins/rigor-dry-types/) (`:dry_type_aliases` — canonical + nested + user-authored compositions + transitive references); [`rigor-dry-schema`](../plugins/rigor-dry-schema/) (`:dry_schema_table` — recognition + `each` list slot); [`rigor-dry-validation`](../plugins/rigor-dry-validation/) (`:dry_validation_contracts` + RBS overlay for `Contract#call → Result`). `rigor-dry-struct` v0.2.0 consumes `:dry_type_aliases` via ADR-18 `returns_from_arg:`.

**Pending Tier 3 (specialised, author when there is concrete user demand):**

- `rigor-graphql` slice 3+ (resolver-method type-check; `<Type>.array` / `<Type>!` chain forms beyond the bracket form; string-form `field :foo, "User"` diagnostic; `Schema.execute(...)` result typing).
- `rigor-dry-schema` slice 2+ (typed `result.to_h` synthesis via ADR-16 Tier C / per-row diagnostics), `rigor-dry-validation` slice 2+3 (params-block typing via `:dry_schema_table` consumption + `json` parity), `rigor-dry-monads` (needs ADR-3 amendment for `Result[T, E]` / `Maybe[T]` carrier — slicing options in [the slicing plan](design/20260517-dry-validation-slicing.md) § "Open observation").

Each plugin is staged in `plugins/rigor-<id>/` per the [`rigor-plugin-author`](../skills/rigor-plugin-author/SKILL.md) SKILL discipline and extracted via `git subtree split` once its contract is stable. The `rigor-rails` meta-gem scaffold (v0.1.6) is the publication-ready template for the Tier 1+2 umbrella — gemspec + `add_dependency` declarations all in place; activation in the wild waits on the sub-plugins' subtree-split + RubyGems publish.

[ADR-9](adr/9-cross-plugin-api.md) (cross-plugin API) landed in v0.1.4 via the `:helper_table` (rails-routes → actionpack) and `:model_index` (activerecord → actionpack + factorybot) publish-and-consume cycles. Slicing per ADR-9 § "Implementation slicing" allows partial landings.

[ADR-16](adr/16-macro-expansion.md) (macro / DSL expansion substrate) released in v0.1.5. Three worked consumers exercise the substrate end-to-end — `rigor-sinatra` (Tier A), `rigor-dry-struct` (Tier C), `rigor-devise` (Tier B). The substrate ships at the WD13 floor + precision promotion for the common cases (Tier B origin-module RBS dispatch, Tier C plain class-name `nominal_for_name`); Tier D engine integration + ADR-13 resolver-chain wiring for utility-type returns stay demand-driven.

[ADR-18](adr/18-substrate-per-call-site-return-type.md) (substrate per-call-site return-type DSL) accumulating on `master` for v0.1.6. Adds `Plugin::Macro::HeredocTemplate::Emit#returns_from_arg` (+ `lookup_via:` cross-plugin fact channel); `rigor-dry-struct` v0.2.0 is the first worked consumer (resolves `attribute :city, Types::String` to `Nominal[String]` via `:dry_type_aliases` published by `rigor-dry-types`). Slice 4 (TraitRegistry parity) + chained-call argument extraction stay demand-driven.
