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

**In flight (post-v0.1.15, accumulating in `[Unreleased]`): plugin-contract interface segregation + ergonomics (ADR-37 / ADR-38 / ADR-39) — release gates MET.** A pre-1.0 plugin-mechanism review prompted a large refactor splitting the two fat plugin hooks (`flow_contribution_for`, `diagnostics_for_file`) into narrow, declaratively-gated, engine-indexed, per-interface-testable extension surfaces (PHPStan-style), with an author-helper layer cutting the cross-plugin boilerplate. **The release gates are closed and three ADRs ratified (37/38/39 Accepted):**
- **ADR-37/38** — all 14 bundled diagnostic-emitting plugins migrated onto `node_rule` (the last, `rigor-actionpack`, via `NodeContext.ancestors`); Slice 2 (`dynamic_return`/`type_specifier`) carries its cleanly-fitting consumers; Slice 3 shipped `rigor plugins --capabilities`; ADR-38 `additional_initializers:` (def-form).
- **ADR-39 (new this session) — plugins may invoke a trusted target library's pure allow-listed methods directly** (PHPStan-style), with a **selectable isolation strategy** (`Plugin::Isolation`: `none`/`ruby_box`/`process`, **`process` the default** — a forked persistent worker, crash-contained, falls back to `none` without `fork`). Worked consumer `Plugin::Inflector` (real `ActiveSupport::Inflector`) — `rigor-rails-routes`/`activerecord`/`actionpack`/`actionmailer`/`factorybot` migrated off hand-rolled inflection; validated byte-identical on Redmine + Mastodon + the full spec suite. `Base.suggest` (DidYouMean) retired the levenshtein copies. `activesupport` + `rack` added as `rigortype` **dev** deps (prod dep belongs on each plugin gem). The `ruby_box` strategy is gated experimental — blocked on an upstream `Ruby::Box` VM segfault (bug-report draft at [`docs/notes/20260602-ruby-box-segfault-bug-report.md`](notes/20260602-ruby-box-segfault-bug-report.md)).
- **Docs reflected**: `docs/internal-spec/plugin.md` + both `rigor-plugin-author` SKILLs (gem-shipped `skills/` + in-repo `.claude/skills/`) teach the ADR-37 narrow protocols + the ADR-39 target-library rule.

Only non-gating ergonomics follow-ons remain — see Branch D below.

## Reading order for a returning implementer

`make verify` is clean. **`[Unreleased]` holds the now-substantially-complete plugin-mechanism interface-segregation + ergonomics effort** (ADR-37 / ADR-38 / ADR-39 — see § "Status"); the release gates are met and all three ADRs are Accepted. Branch D below is the residual (non-gating) ergonomics — the two largest boilerplate items are now done: **0a (`Source::Literals`) LANDED** (grid completed + ten plugins + one example migrated) and **0d (`config_schema` defaults, [ADR-40](adr/40-config-schema-defaults.md)) LANDED** (mechanism + thirteen plugins migrated off `DEFAULT_*`). What remains in Branch D is smaller and demand-driven (ADR-39 inflection follow-ons, `dynamic_return` generalisation, ADR-38 block-form, per-interface test harnesses). Branches A–C are the other queued tracks. **Next-session entry point: the remaining Branch-D items are independent demand-driven slices; the bigger strategic lever is Branch A's single remaining gate — v0.2.0 gate 1, plugin-contract stabilisation for *external* third-party `rigor-*` gems (the subtree-split/publish gate is superseded by the single-bundled-gem model). That needs explicit planning rather than another incremental slice.**

### Branch D — plugin interface segregation (ADR-37 / ADR-38): release gates DONE; only ergonomics remain

The full landed-vs-remaining picture lives in [`docs/ROADMAP.md`](ROADMAP.md) § "Plugin contract — interface segregation + ergonomics (ADR-37 / ADR-38) — RELEASE GATES MET". One-screen summary:

**Landed this session** (all in `[Unreleased]`; full detail in ROADMAP § "Plugin contract … RELEASE GATES MET" + CHANGELOG):
- ADR-37/38 node_rule migration (all 14 walker plugins, `rigor-actionpack` last) + Slice 2 (`dynamic_return`/`type_specifier`) + Slice 3 (`rigor plugins --capabilities`); both ADRs Accepted.
- **ADR-39** (target-library invocation, Accepted): the rule + `Plugin::Inflector` over real `ActiveSupport::Inflector` + `Plugin::Isolation` selectable strategy (`none`/`ruby_box`/`process`, **`process` default**, forked-once persistent worker, crash-contained, `none` fallback without fork) + `Plugin::Box` (the `ruby_box` wrapper). Consumers migrated: rails-routes/activerecord/actionpack/actionmailer/factorybot. `rigor-rspec-rails` validates `have_http_status` against the real `Rack::Utils` table.
- **Boilerplate 0c** — `Base.suggest` (DidYouMean class method) retired the levenshtein copies (statesman/rails-routes/activerecord).
- **Boilerplate 0b/c adoption** — `Diagnostic.from_node`/`from_location` adopted in the production analyzers (activerecord/activestorage/hanami/sorbet); example plugins' own `def diagnostic` removed (pattern/routes → inherited `Base#diagnostic`; web → `from_location`). Examples `rigor-lisp-eval`/`rigor-pattern` also migrated onto `node_rule` (deleted their hand-rolled `Walker`s).
- Docs: `plugin.md` + both `rigor-plugin-author` SKILLs updated for ADR-37 + ADR-39.

**Remaining (all non-gating, demand-driven; each its own behaviour-preserving slice — verify before committing):**
1. **Boilerplate 0a — `Source::Literals` adoption — LANDED.** The prerequisite symbol-only + String-returning variants shipped (the extraction grid is now complete over both axes: `symbol` / `symbol_name` / `symbol_or_string_name` + the original `symbol_or_string`, pinned in the public-API drift spec + RBS sig). Ten bundled plugins + one example migrated onto the helpers (statesman / rspec / activestorage / factorybot / actionpack / rails-routes / graphql / actionmailer / dry-schema / activerecord + the pattern example), each behaviour-preserving against its golden-master spec; `make verify` clean. **Remaining tail (demand-driven):** the assoc-key *name-match* idiom (`el.key.is_a?(SymbolNode) && el.key.unescaped == "x"`) is a key comparison, not a value extraction — outside the four-helper grid; a dedicated `symbol_named?(node, name)` helper could absorb it but is its own slice.
2. **Boilerplate 0d — `config_schema` `{kind:, default:}` — LANDED ([ADR-40](adr/40-config-schema-defaults.md)).** `Base#config` merges manifest-declared defaults under the user config; thirteen bundled plugins migrated off the `DEFAULT_*`-constant idiom (statesman / pundit / actioncable / activejob / sidekiq / actionpack / activestorage / factorybot / rails-i18n / actionmailer / activerecord / rails-routes / sorbet), each behaviour-preserving; `make verify` clean. Dynamic defaults (sorbet's `paths`) stay on `fetch`-with-default by design. **Remaining tail (demand-driven):** the `rigor-playground` command (not a checker plugin) and any future configurable plugin author onto the same form.
3. **ADR-39 follow-ons:** slice 3 (statically ingest `config/initializers/inflections.rb` for project-custom inflections — the AS default ruleset already covers common cases; the open design point is per-project rule isolation in a long-lived LSP process); route the `rigor-rspec-rails` Rack catalogue through `Isolation` too (low value — one-time fetch); maximal-fidelity exact-gem-version loading (a worker pinned to the target's `Gemfile.lock`); isolation perf check (per-call IPC under the `process` default on big projects) + the fork-within-ADR-15-fork-backend nesting.
4. **`dynamic_return` generalisation** (optional `methods:` gate / dynamic-receiver predicate) — the path to migrating the escape-valve consumers off `flow_contribution_for`.
5. **ADR-38 block-form** `additional_initializers` (rspec `before`/`let` whose ivar writes live in a call block) — needs the ivar write-collector to descend declared call blocks.
6. **Per-interface test harnesses** (`NodeRuleTest` / `DynamicReturnTest`).
- **Explicitly out of scope** (leave as-is): escape-valve consumers (sorbet/activerecord/activestorage/rspec-let — `flow_contribution_for` is the supported deprecated valve for their method-gated-return / dynamic-receiver shapes), pure-FactProvider plugins (dry-*/graphql), hanami/web (ADR-28 base, separate axis).
- **Verification discipline** (the established pattern): each is behaviour-preserving — run the touched plugin's golden-master integration spec (**production plugins** under `spec/integration/plugins/<id>_plugin_spec.rb`; **examples** under `spec/integration/examples/<id>_plugin_spec.rb`) then `make verify` (inside the Flake) before committing. Two lessons from this session's boilerplate sweep: (i) not every `start_column+1` is the `Rigor::Analysis::Diagnostic` convention — `rigor-rspec`'s `Analyzer::Diagnostic` is a local `Struct` and `rigor-actionmailer`'s is a discovery-index `def_column`, so check the constructed class before swapping; (ii) the per-plugin rescue boundary swallows a raised migration bug into "0 diagnostics", so the golden-master spec is what catches it — always run it.

The pre-1.0 review that motivated all of this: [`docs/design/20260601-plugin-mechanism-pre-1.0-review.md`](design/20260601-plugin-mechanism-pre-1.0-review.md); the phased plan: [`docs/design/20260602-plugin-boilerplate-reduction-plan.md`](design/20260602-plugin-boilerplate-reduction-plan.md).

### Branch A — v0.2.0 evaluation release

v0.1.12 leaves the preview line in a strong RC posture for v0.2.0. The gates are documented in [`docs/ROADMAP.md`](ROADMAP.md) § "v0.2.0 — first evaluation release" and have been **reduced from three to two**:

1. **ADR-2 plugin-contract surface stabilised enough to support external `rigor-*` gems** (a third-party gem in its own repo, depending on `gem "rigortype"`, per [ADR-31](adr/31-contribution-and-supply-chain-policy.md) WD4) — with an external-author onboarding path and a test that an out-of-tree plugin loads and runs. **Executable evidence landed** (`spec/integration/external_plugin_spec.rb` + the `spec/fixtures/external_plugin/` fixture): an out-of-tree plugin depending only on the public surface (`node_rule` / `#diagnostic` / ADR-40 `config_schema` defaults / `Source::Literals`) loads via the **real `require`** and runs end-to-end — a standing drift guard for the external contract. A companion **structural guard** (`spec/integration/all_plugins_load_spec.rb`) enumerates every `plugins/*` and `examples/*` dir and asserts each loads + registers a valid-manifest plugin, so no bundled plugin (or future addition) escapes a load/registration check. The external-author SKILL (`skills/rigor-plugin-author`) ships the onboarding path. **Remaining for full closure:** an explicit "public vs internal" stability statement for the pinned namespaces (the drift spec already pins them; what's missing is the *documented commitment* that they won't break within 0.2.x) — that is the planning-worthy part, not another test.
2. ~~Subtree-split / RubyGems publishing flow for the `rigor-rails` family.~~ **Superseded** — the distribution model is now a single bundled `rigortype` gem (per-plugin gemspecs dropped in commit `9769f5fa`; [ADR-31](adr/31-contribution-and-supply-chain-policy.md) retracted subtree-split as a default, keeping subtree *merge* only as a rare reserved option). No per-plugin publish flow to exercise; what remains folds into gate 1 (the external third-party path).
3. SKILL trio shipped (v0.1.9, ✓).

Gates 2 and 3 are settled. **The one substantive remaining gate is gate 1** — it needs explicit planning, not just any slice. The 99.2% Mastodon error reduction + the all-three-G2-cases-closed story is a defensible publicity moment for the cut.

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
