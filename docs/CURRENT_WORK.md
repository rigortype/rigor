# Current Work — Resume Bookmark

A transient bookmark for the next implementer: the immediate next-session entry point plus engine-internal items not fully captured elsewhere. The **normative** contracts live in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md); the forward-looking commitment envelope (release strategy + full backlog) lives in [`docs/ROADMAP.md`](ROADMAP.md); the released-version record is [`CHANGELOG.md`](../CHANGELOG.md). If this file disagrees with any of those, the spec / ADR / roadmap binds and this file is out of date.

## Status

**v0.1.15 released (2026-05-29).** The preview line was extended past the v0.1.12 OSS-realism cut with three further patch cuts:

- **v0.1.13** — AI-assisted onboarding (`rigor skill`) + single-file script analysis: `call.unresolved-toplevel` ([ADR-34](adr/34-toplevel-unresolved-self-call-default.md)) + the `pre_eval:` project monkey-patch pre-evaluation mechanism ([ADR-17](adr/17-monkey-patch-pre-evaluation.md)).
- **v0.1.14** — machine-readable install guide (`docs/install.md`, [ADR-27](adr/27-tool-distribution-model.md)); `RBS::DuplicatedDeclarationError`-after-`rbs collection install` fix.
- **v0.1.15** — Liskov override-compatibility diagnostic family (`def.override-*`, [ADR-35](adr/35-override-signature-compatibility.md), slices 1–4); `rigor plugin` source-browsing command; sharper undefined-method reporting for uninstalled project monkey-patches / generated DSLs.

`bundle exec rake release` has been run for each; the gems are on RubyGems. Per-version detail lives in `CHANGELOG.md` § `[0.1.13]` / `[0.1.14]` / `[0.1.15]`.

Cumulative survey results (measured at the v0.1.12 OSS-realism cut; still the headline realism numbers — v0.1.13–v0.1.15 added onboarding + the `def.override-*` family rather than running new full surveys, though ADR-35 slice 4 re-verified the Mastodon corpus):

| Project | Scope | Before | After | Delta |
|---|---|---:|---:|---:|
| Mastodon | `app + lib` | 789 | 6 | **−99.2%** |
| Redmine | full plugin set | 163 | 79 | −51% |
| GitLab FOSS | `app/{controllers,mailers,workers,services}` | ~670 | ~140 | ~−79% |

The 6 remaining Mastodon errors are all unrelated to engine precision: 5 nil-receiver in test fixtures + 1 upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass-narrowing gap (see [`docs/notes/20260528-rbs-upstream-pr-resolv-typeclass.md`](notes/20260528-rbs-upstream-pr-resolv-typeclass.md)).

**In flight (post-v0.1.15, accumulating in `[Unreleased]`): plugin-contract interface segregation (ADR-37 / ADR-38) — release gates MET.** A pre-1.0 plugin-mechanism review prompted a large refactor splitting the two fat plugin hooks (`flow_contribution_for`, `diagnostics_for_file`) into narrow, declaratively-gated, engine-indexed, per-interface-testable extension surfaces (PHPStan-style), with an author-helper layer cutting the cross-plugin boilerplate. **The release gates are now closed:** all 14 bundled diagnostic-emitting plugins are migrated onto `node_rule` (the last, `rigor-actionpack`, landed via `NodeContext.ancestors` with its golden-master spec green); Slice 2 (`dynamic_return`/`type_specifier`) carries its cleanly-fitting consumers; Slice 3 shipped the `rigor plugins --capabilities` catalogue; and **ADR-37 / ADR-38 are Accepted**. Only non-gating ergonomics follow-ons remain — see Branch D below.

## Reading order for a returning implementer

`make verify` is clean. **`[Unreleased]` holds the now-substantially-complete plugin-mechanism interface-segregation effort** (ADR-37 / ADR-38 — see § "Status"); the release gates are met and the ADRs are Accepted. Branch D below is the residual (non-gating) ergonomics; Branches A–C are the other queued tracks.

### Branch D — plugin interface segregation (ADR-37 / ADR-38): release gates DONE; only ergonomics remain

The full landed-vs-remaining picture lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Plugin contract — interface segregation + ergonomics (ADR-37 / ADR-38) — RELEASE GATES MET". One-screen summary:

- **Landed** (`[Unreleased]`): ADR-38 `additional_initializers:` (Accepted, def-form); the author-helper layer (`Source::Literals`, `Diagnostic.from_node`/`from_location`, `Base#diagnostic`); ADR-37 Slice 1/1c/1d (`node_rule` engine-owned walk + `node_file_context` + `NodeContext`) with **all 14 bundled diagnostic-emitting plugins migrated** off the `diagnostics_for_file` walker — `rigor-actionpack` (the last; 4 phases, namespace-qualification-sensitive, controller name re-derived from `NodeContext.ancestors`, golden-master spec green) closed the set; Slice 2 (`dynamic_return` + `type_specifier`) + 3 consumers (mangrove / minitest / rspec-matcher); Slice 3 (`rigor plugins --capabilities` catalogue). **ADR-37 Accepted.**
- **Remaining (all non-gating, demand-driven; each its own behaviour-preserving slice — verify before committing):** boilerplate Phase 0c (`Base#suggest`/SpellChecker — message-text-only, FP-safe, 3 plugins + spec churn), 0d (`config_schema` `{kind:,default:}` defaults — needs a small ADR, ~17 plugins), 0e (`Plugin::Inflector` — **LANDED via [ADR-39](adr/39-plugin-target-library-invocation.md), Accepted:** real `ActiveSupport::Inflector` behind an allow-list+rescue harness, all 3 consumers migrated, byte-identical on Redmine+Mastodon; **remaining:** ADR-39 slice 3 (static `config/initializers/inflections.rb` ingestion for project-custom inflections) + ADR-39 slice 5 (the **`Ruby::Box` isolation layer** — chosen first-priority isolation for target-library invocation; validated feasible in Flake Ruby 4.0.5 via `RUBY_BOX=1`; needs launcher re-exec; isolates target-gem monkey-patches/version from Rigor's main space + unlocks the exact-version path; current pinned-dep path stays until it lands)); `Source::Literals` symbol-only variants; the `dynamic_return` generalisation (escape-valve-consumer migration path); ADR-38 block-form; `NodeRuleTest` / `DynamicReturnTest` harnesses.
- **Explicitly out of scope** (leave as-is): escape-valve consumers (sorbet/activerecord/activestorage/rspec-let — `flow_contribution_for` is the supported deprecated valve for their method-gated-return / dynamic-receiver shapes), pure-FactProvider plugins (dry-*/graphql), hanami/web (ADR-28 base, separate axis).
- **Verification discipline** (the established migration pattern, for the remaining boilerplate slices): each is behaviour-preserving — run the touched plugins' `spec/integration/plugins/<id>_plugin_spec.rb` then `make verify` (inside the Flake) before committing; the analyzer/main-plugin split is `Analyzer.diagnose` → `Analyzer.*_violations_for` (per-node, no walk) returning location-free `Violation`s, with the main plugin wrapping via `node_rule` + `Base#diagnostic`.

The pre-1.0 review that motivated all of this: [`docs/design/20260601-plugin-mechanism-pre-1.0-review.md`](design/20260601-plugin-mechanism-pre-1.0-review.md); the phased plan: [`docs/design/20260602-plugin-boilerplate-reduction-plan.md`](design/20260602-plugin-boilerplate-reduction-plan.md).

### Branch A — v0.2.0 evaluation release

v0.1.12 leaves the preview line in a strong RC posture for v0.2.0. The remaining gates are the three documented in [`docs/ROADMAP.md`](ROADMAP.md) § "v0.2.0 — first evaluation release":

1. ADR-2 plugin-contract surface stabilised enough to support external `rigor-*` gems outside this monorepo.
2. Subtree-split / RubyGems publishing flow exercised for at least the `rigor-rails` family.
3. SKILL trio shipped (v0.1.9, ✓).

Gate 3 is met. Gates 1 and 2 need explicit planning — not just any slice will count. The 99.2% Mastodon error reduction + the all-three-G2-cases-closed story is a defensible publicity moment for the cut.

### Branch B — continue closing residual errors

Mastodon `app + lib` residue at v0.1.12 is 6 errors; closing those requires NEW scope rather than another rails-routes iteration:

1. **Genuine nil-chain bugs in spec fixtures (5 errors)** — these are mostly `*_for_nil`-style fixtures in `spec/models/` / `spec/lib/`. They are real diagnostics, not false positives. A Mastodon-side fix; Rigor has no work here.
2. **Upstream `ruby/rbs` `Resolv::DNS#getresources` typeclass-narrowing (1 error)** — the `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` is staged. Branch push + `ruby/rbs` PR creation are the user's task.

Beyond Mastodon, the Redmine / GitLab FOSS residues are larger surfaces; each warrants its own survey cycle if the user wants to chase those numbers down.

### Branch C — engine-internal items not driven by surveys

These are the queued engine items unaffected by the v0.1.12 cycle:

1. **ADR-24 slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. See "ADR-24 — implicit-self method-call resolution, remaining" below.
2. **AR scope-body lambda `self`** — `scope :x, -> { select(...).group(...) }` inside an instance lambda still needs the lambda's `self` rebound to the model class. v0.1.12 closed the implicit-self class-side resolution for ordinary method bodies; lambda bodies remain. The empirical case is in [`docs/notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) § "What is increasing" item 2 / ADR-26 territory.

### Reference reading

When in doubt, the canonical entry points:

1. [`CHANGELOG.md`](../CHANGELOG.md) § `[0.1.13]` – `[0.1.15]` — release-notes for the latest cuts (onboarding, `pre_eval:`, the `def.override-*` family); § `[0.1.12]` for the OSS-realism cycle.
2. [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to v0.2.0" — what gates v0.2.0.
3. [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — public-vs-internal stability boundary. v0.2.0 stabilises the plugin-contract surface for external `rigor-*` gems; cross-reference `spec/rigor/public_api_drift_spec.rb` before extending any pinned namespace.
4. [`docs/adr/2-extension-api.md`](adr/2-extension-api.md) — the plugin contract v0.2.0 must stabilise.

## Open engineering items

Engine-internal items the next implementer benefits from seeing directly. The full demand-driven backlog (editor mode, LSP capabilities, dry-rb continuations, ADR-10/13/16 follow-ups, performance levers) lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles" and is the v0.2.x completion target. This section holds only items with engine-internal detail not captured there.

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4** — gated `undefined-method` / arity diagnostics on resolved closed-class self-calls. Its own FP-evaluation gate ([ADR-24 WD4](adr/24-self-method-call-resolution.md)) — a large new false-positive surface on metaprogramming-dense code, so v1 was deliberately precision-additive only.
- **Non-`Bot` general adoption inside class bodies** — resolved self-call return type is adopted ONLY when it is `Bot`. Unconditional adoption of precise non-`Bot` returns regressed `rigor check lib` by 16 diagnostics (pre-existing callee-return-inference imprecisions surfacing downstream); this follow-up needs callee-return inference precise enough that adopting precise types does not surface those imprecisions.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred). (`receiver_type` / `method_name` structured fields on `Analysis::Diagnostic` shipped in v0.1.8; the SKILL integration shipped with the v0.1.9 trio.)

### Flow-folding — all G1 / G2 cases now closed (v0.1.12)

**Status: closed.** v0.1.12 sealed the three remaining G2 cases:

- **`retry` flow edge** — `eval_begin` widens rebound locals / ivars to their Nominal envelope and re-evaluates the begin body under the widened entry.
- **Intervening method-call invalidation** — an implicit-self / `self.foo` call widens each ivar back to its class-wide seed.
- **Read-before-write nil** — the class-ivar pre-pass contributes `nil` when a method body reads an ivar before any write to the same ivar (gated by `initialize` writes / class-body-level writes / existing-entry-only).

No queued items in this area.

### Stdlib RBS coverage-gap pattern

When an upstream `ruby/rbs` RBS gap is surfaced by a single internal Rigor call site, prefer **(a')** an in-source `# rigor:disable` directive + load the library; when it surfaces across multiple call sites or in user-facing code, escalate to **(b)** a focused RBS overlay under Rigor's own `sig/`, or **(c)** an upstream `ruby/rbs` fix. The `references/rbs` branch `widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged for an upstream PR — branch push + `ruby/rbs` PR creation are the user's task.

### Smaller queued items

- **Sig-gen `update_existing`** does not collapse sibling parent / child class blocks — `merge_class` resolves each candidate's `class_name` independently, so flat-sibling layouts stay flat. Re-flowing an existing file into the nested layout is out of scope; workaround is to delete the target sig file and regenerate from scratch.
- **`Hash === expr` case-equality narrowing** (`open3.rb:226` shape) — still open.
- **In-memory `Analysis::Runner.run_source(source:, path:, …)` entry point** — bypasses the per-call tmpdir + chdir in `RunnerHelpers#analyze`; ~5 % spec-suite win plus a clean public API for embedders (LSP / editor mode). Demand-driven.
- **Sig-gen remaining gaps after `--params=observed`** — `attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still produce `:untyped_return`; fix is a hand-written sig annotation. Deep chains on untyped receivers → `rbs collection install` or ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin (escalation path A in the SKILL). These are documented in `skills/rigor-project-init/references/04-sig-uplift.md` § "Step 5-d" and are the natural next action after `--params=observed` still leaves gaps.

### Type-coverage uplift — line status (2026-05-23)

Phases 1–4 landed (String / Integer / Float / Comparable / Math / HashShape / Date / DateTime / Time). Remaining items, all **release undetermined**:

- **Struct / Data value folding** — deferred ADR-worthy feature (needs two new carriers). See `docs/ROADMAP.md` § "Future cycles" → "Type-language / engine" and [`docs/notes/20260523-struct-encoding-coverage.md`](notes/20260523-struct-encoding-coverage.md). `Encoding` value folding recorded in the same audit as a *permanent exclusion*.
- **`MathFolding` result refinements** — the 28-function fold is value-precise; attaching range refinements to the results (`Math.exp` → `positive-float`, `Math.sqrt` / `hypot` → `non-negative-float`) is the demand-driven follow-up ([`docs/notes/20260522-stdlib-deterministic-module-coverage.md`](notes/20260522-stdlib-deterministic-module-coverage.md) § 1).
- **Hash `rassoc` shape handler** — the one open low-priority Hash handler ([`docs/notes/20260522-hash-method-coverage.md`](notes/20260522-hash-method-coverage.md)); value → `[k, v]` reverse lookup, foldable when every value is a `Constant`. Demand-driven.

## Post-release follow-ups

- **`data/oss-sweep/mastodon-thresholds.json`** — refresh the stored thresholds against v0.1.12's baseline so the weekly OSS sweep gate reflects the new ~6 baseline. The current file is uncalibrated (`max_diagnostics: 999999`).
