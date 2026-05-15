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

## Future cycles (not committed to a specific release)

Items that have surfaced across v0.1.x work and that the next implementer benefits from seeing without re-reading the full thread.

### Type-language / engine
- **O2 — macro-template + heredoc-Ruby expansion.** Substrate floor + precision promotion delivered through [ADR-16](adr/16-macro-expansion.md) slices 1–5a + 7 (commits 584ae85…56706a5) + slice 6a-TierB / 6b-TierC precision (commits d174fff / d7b1943): Tier A (block-as-method) + Tier B (trait-inlining registry) + Tier C (heredoc template) engine integration through a new `SyntheticMethodIndex` + pre-pass scanner; Tier D (external-file inclusion) ships contract only with engine integration deferred per the slice-5a deferment; Concern (`included do`) re-targeting handled in the scanner; **slice 6** precision promotion routes Tier B emissions through their `origin_module:` provenance via `RbsDispatch.try_dispatch` (Devise's `valid_password?` returns `bool` now, not `Dynamic[T]`) and Tier C plain-class-name `returns:` strings via `environment.nominal_for_name`. Three worked consumers landed: `rigor-sinatra` (Tier A), `rigor-dry-struct` (Tier C), `rigor-devise` (Tier B). Remaining items: **slice 5b** (Tier D engine — narrows top-level `self_type` and pre-binds `bound_ivars` for matched external files; queued, demand-driven), **full ADR-13 resolver-chain wiring** (routes parameterised forms `Array[String]` / `Hash[K, V]` and plugin-supplied utility-type names `Pick<T, K>` through the resolver chain; queued, demand-driven). Grounding survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](notes/20260515-macro-expansion-library-survey.md).
- **Lightweight HKT (higher-kinded types) in DSL signatures.** Replace `untyped` boundaries with type-level `eval` per the `docs/type-specification/rigor-extensions.md` conditional / indexed-access rows. First reference site is the rigor-lisp-eval demo. Exploratory, no committed milestone.
- **`rigor:v1:conforms-to` directive.** Originally queued for v0.1.1's "Out of scope"; still open. Lets a method param accept any value satisfying a named structural interface.
- **LRU eviction for `Cache::Store`.** Per [ADR-6](adr/6-cache-persistence-backend.md), the persistent cache is sharded "no eviction" by design. Long-lived clones with config / dependency churn accumulate stale slots that only `make cache-clean` releases. LRU is queued, not committed.
- **Project-side monkey-patch pre-evaluation.** [ADR-17](adr/17-monkey-patch-pre-evaluation.md) accepted (2026-05-16). `pre_eval:` config axis (explicit file list MVP — pattern-based / full-project 2-pass / plugin-API hook stay demand-driven), populates `Inference::ProjectPatchedMethods` registry consulted at a new dispatcher tier between plugins and dependency-source inference. Implementation queued (no committed milestone); slice 1 (configuration plumbing) is the natural first commit.
- **ADR-13 resolver-chain wiring for the synthetic-method tier (ADR-16 follow-up).** ADR-13's `Plugin::TypeNodeResolver` chain is wired for `%a{rigor:v1:…}` payloads but NOT for substrate manifest `returns:` strings. Routing the synthetic-method tier through the chain unlocks utility-type-shaped Tier C returns (`Array[String]`, `Hash[K, V]`, `Pick<T, K>`). Deferred to demand from utility-type-shaped substrate consumers.

### Plugins / ecosystem
- **`rigor-graphql`** — last remaining Tier 3 plugin. GraphQL schema DSL parsing is non-trivial; author when there is concrete user demand.
- **dry-rb adapter plugins** — [ADR-12](adr/12-dry-rb-packaging.md) accepted (2026-05-16): per-gem plugins + planned `rigor-dry-rb` meta umbrella, matching the Rails plugin family pattern. `rigor-dry-struct` (LANDED v0.1.5) is the first concrete; next slice is `rigor-dry-types` as the Tier A foundation. Survey under [`docs/design/20260509-dry-plugins-roadmap.md`](design/20260509-dry-plugins-roadmap.md).
- **ADR-10 — per-call return-type precision from gem source.** Walker currently catalogs only `(class_name, method_name) → kind` triples. Inferring per-method return types from gem source (so `mode: :full` could contribute richer than `Dynamic[Top]`) is a larger walker enhancement deferred until concrete user demand surfaces.
- **`rigor-sorbet` follow-ups beyond per-call-site sigil gating** — landed in v0.1.4. No outstanding queue items.

### Performance / scalability
- **O4 Layer 3 — `Gemfile.lock` parse + `gem_rbs_collection` version matching.** Sits on top of v0.1.5's `BundleSigDiscovery` MVP. The MVP's auto-skip list (`SKIPPED_GEMS_BY_DEFAULT`) becomes a versioned resolution table; rigor consumes `Bundler::LockfileParser` output + queries `ruby/gem_rbs_collection` for the best-matching version. Unblocked by O7's failure-memo (conflicts now warn rather than hang).
- **Fork-based file-level parallelism for `rigor check`.** Stackprof of warm `rigor check lib` shows ~50% inference, ~22% `Marshal.load`, ~17% GC. The Phase 4b Ractor path is the v0.1.5 parallelism story; a fork-based path remains a parallel (non-exclusive) option for hosts where Ractors are unavailable or where COW sharing of pre-warmed `Environment` blobs would beat per-Ractor env build.
- **In-memory `Analysis::Runner.run_source` entry point (test-only).** The `RunnerHelpers#analyze` test helper materialises a tmpdir per call. At ~25-50ms per call × hundreds of runner-spec calls, an in-memory entry point could shave ~5% sequential / ~3% parallel from the suite. Not worth doing standalone, but a natural complement if test-suite expansion continues.

### Sig-gen (ADR-14)
- **`update_existing` does not yet collapse sibling parent / child class blocks.** Gap (c)'s tree-builder fix lives in `Writer#render_new_file` (the create-new path). When updating an existing target file, `merge_class` resolves each candidate's `class_name` independently — flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout would require parsing the existing decl tree and rewriting it, which is out of scope for a follow-up fix. Users who want the canonical nested layout regenerate from scratch (delete the target sig file and rerun).

### Open research questions queued in ADRs
- **ADR-15 § OQ1** — per-Ractor `Cache::Store`-shared facade. Today each worker builds its own RBS env from cache; OQ1 explores sharing the in-memory env across workers via a shareable facade. Would lower the pool wall-clock crossover with sequential (currently around 1.3–1.8 K files).
- **ADR-13 § "Open questions"** — extending the shape-projection surface beyond the five core functions (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`). Authoritative when adding new mapped-type vocabulary.

## Rails ecosystem plugins (running track, parallel to v0.1.x core work)

The full roadmap is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Summary of the running track:

**Already landed (released through v0.1.4 / accumulating on `master` for v0.1.5):**

- **Tier 1**: [`rigor-rails-routes`](../examples/rigor-rails-routes/) (publishes `:helper_table`), [`rigor-rails-i18n`](../examples/rigor-rails-i18n/), [`rigor-actionmailer`](../examples/rigor-actionmailer/), [`rigor-activejob`](../examples/rigor-activejob/).
- **Tier 2**: [`rigor-activerecord`](../examples/rigor-activerecord/) (publishes `:model_index`; associations / enums / scopes / validations / callbacks all landed in v0.1.5); [`rigor-actionpack`](../examples/rigor-actionpack/) (4 phases: routes / filters / renders / strong-params); [`rigor-factorybot`](../examples/rigor-factorybot/) (Phase 1 (a) + (c)).
- **Tier 3**: [`rigor-pundit`](../examples/rigor-pundit/), [`rigor-sidekiq`](../examples/rigor-sidekiq/), [`rigor-rspec`](../examples/rigor-rspec/), [`rigor-actioncable`](../examples/rigor-actioncable/), [`rigor-activestorage`](../examples/rigor-activestorage/) (landed v0.1.5).
- **Opt-in non-plugin bundles**: [`rigor-activesupport-core-ext`](../examples/rigor-activesupport-core-ext/) (v0.1.5; opt-in RBS bundle for top ~50 AS core_ext selectors). [`rigor-typescript-utility-types`](../examples/rigor-typescript-utility-types/) (ADR-13 slice 6).
- **ADR-16 substrate consumer plugins (v0.1.5)**: [`rigor-sinatra`](../examples/rigor-sinatra/) (Tier A — block-as-method), [`rigor-dry-struct`](../examples/rigor-dry-struct/) (Tier C — heredoc template), [`rigor-devise`](../examples/rigor-devise/) (Tier B — trait-inlining registry). Three purely declarative plugins exercising the macro expansion substrate end-to-end.

**Pending Tier 3 (specialised, author when there is concrete user demand):**

- `rigor-graphql`.
- `rigor-dry-types` companion (Tier-C-as-`const_set` constant emit). Discussed in [ADR-16](adr/16-macro-expansion.md) survey as the natural follow-up to `rigor-dry-struct`. The current Tier C substrate emits methods, not constants — adding a constant-emit primitive is a separate slice. Gated on demand.

Each plugin is staged in `examples/rigor-<id>/` per the [`rigor-plugin-author`](../.codex/skills/rigor-plugin-author/SKILL.md) SKILL discipline and extracted via `git subtree split` once its contract is stable. The eventual `rigor-rails` meta-gem will declare the Tier 1+2 plugins as gem dependencies so a single Gemfile line opts the user into the whole stack.

[ADR-9](adr/9-cross-plugin-api.md) (cross-plugin API) landed in v0.1.4 via the `:helper_table` (rails-routes → actionpack) and `:model_index` (activerecord → actionpack + factorybot) publish-and-consume cycles. Slicing per ADR-9 § "Implementation slicing" allows partial landings.

[ADR-16](adr/16-macro-expansion.md) (macro / DSL expansion substrate) landed in v0.1.5 (`master`, release pending). Three worked consumers exercise the substrate end-to-end — `rigor-sinatra` (Tier A), `rigor-dry-struct` (Tier C), `rigor-devise` (Tier B). The substrate ships at the WD13 floor + precision promotion for the common cases (Tier B origin-module RBS dispatch, Tier C plain class-name `nominal_for_name`); Tier D engine integration + ADR-13 resolver-chain wiring for utility-type returns stay demand-driven.
