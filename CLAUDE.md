# CLAUDE.md

Project-level briefing for Claude (and any other agent that reads top-level docs by convention). The authoritative agent contract for this repository is [`AGENTS.md`](AGENTS.md) — read it first; this file is a navigation index that points at the documents an agent typically needs and the per-task skills bundled with the project.

## Read these first

| Document | Purpose |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Development environment (Flake mandate, target Ruby), common commands, directory layout, references/ submodule rules, implementation guidelines, commit-message style, release cadence, and verification protocol. **Required reading.** |
| [`README.md`](README.md) | User-facing project overview (CLI, what `rigor check` does today). |
| [`docs/handbook/`](docs/handbook/README.md) | Twelve-chapter (plus six appendices) end-user walkthrough of the type model. Reach for this when you need to explain Rigor concepts to a Ruby programmer (or to yourself) without diving into the spec corpus. Informational; the spec binds. |
| [`docs/types.md`](docs/types.md) | One-page quick guide to the Rigor type system. Faster mental-model warm-up than the handbook when you only need the carrier zoo. |
| [`docs/manual/`](docs/manual/README.md) | **User Manual** — the operational reference companion to the handbook. Installation, CLI command reference, configuration, diagnostics, baselines, plugins, editor / LSP integration, CI, caching, troubleshooting. Reach for this when a user is asking *how to operate* Rigor rather than *what its types mean*. |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Forward-looking commitment envelope. Holds the active in-flight cycle in full detail + future-cycle plans + open questions. Released versions are reduced to one-line pointers to `CHANGELOG.md` (which is the authoritative "what shipped" record). Update entries in the same commit when scope changes. |
| [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) | Resume bookmark for the next implementer. Names the current ship-readiness state, the next-session entry slice, parallel tracks, and open engineering items. Transient — refresh when you take a substantial change set across the finish line. |
| [`docs/design/20260508-rails-plugins-roadmap.md`](docs/design/20260508-rails-plugins-roadmap.md) | Roadmap for the `rigor-*` Rails ecosystem plugins. Tier table, dependency graph, per-plugin sketches, subtree-split readiness checklist. Use when planning new Rails-side plugin work. |
| [`plugins/README.md`](plugins/README.md) | **Production plugin catalogue** for real gems / frameworks (Rails, RSpec, dry-rb, Sorbet, Devise, Sidekiq, etc.). Where to send users who want to install plugins. The count drifts as new plugins land — consult here rather than hard-coding in upstream docs. |
| [`examples/README.md`](examples/README.md) | **Plugin-contract walkthroughs** — tutorials over deliberately simplified virtual use cases (`rigor-deprecations`, `rigor-lisp-eval`, `rigor-pattern`, `rigor-routes`, `rigor-units`). Each spotlights a single architectural surface. Reach for this when authoring a NEW plugin or answering "how do I use surface X of the plugin contract?". |

## Authoritative specifications

When a change touches type-language behaviour or analyzer-internal contracts, the spec binds. ADRs record design rationale and rejected/deferred alternatives.

### Type specification (normative)

| Document | Scope |
| --- | --- |
| [`docs/type-specification/README.md`](docs/type-specification/README.md) | Reading order + RFC 2119 conventions for the spec corpus. |
| [`docs/type-specification/overview.md`](docs/type-specification/overview.md) | Core principle (RBS superset), design priorities. |
| [`docs/type-specification/robustness-principle.md`](docs/type-specification/robustness-principle.md) | Postel's law for types — strict on returns, lenient on parameters. The asymmetric authorship rule every Rigor-authored type observes. |
| [`docs/type-specification/relations-and-certainty.md`](docs/type-specification/relations-and-certainty.md) | Subtyping (`<:`) and gradual consistency, trinary certainty. |
| [`docs/type-specification/value-lattice.md`](docs/type-specification/value-lattice.md) | Lattice identities and `Dynamic[T]` algebra. |
| [`docs/type-specification/special-types.md`](docs/type-specification/special-types.md) | `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`, `bool`/`boolish`. |
| [`docs/type-specification/rbs-compatible-types.md`](docs/type-specification/rbs-compatible-types.md) | RBS forms accepted by Rigor. |
| [`docs/type-specification/rigor-extensions.md`](docs/type-specification/rigor-extensions.md) | Refinements and other internal-only forms beyond RBS. |
| [`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md) | Reserved built-in refinement names (`non-empty-string`, `positive-int`, …). |
| [`docs/type-specification/type-operators.md`](docs/type-specification/type-operators.md) | `~T`, `T - U`, indexed access, display contract. |
| [`docs/type-specification/structural-interfaces-and-object-shapes.md`](docs/type-specification/structural-interfaces-and-object-shapes.md) | RBS interfaces, inferred object shapes, capability roles. |
| [`docs/type-specification/control-flow-analysis.md`](docs/type-specification/control-flow-analysis.md) | Edge-aware narrowing, equality semantics, fact stability, mutation effects. |
| [`docs/type-specification/rbs-extended.md`](docs/type-specification/rbs-extended.md) | `%a{rigor:v1:…}` annotations, predicate / assertion / return-override grammar. |
| [`docs/type-specification/normalization.md`](docs/type-specification/normalization.md) | Deterministic normalization rules. |
| [`docs/type-specification/rbs-erasure.md`](docs/type-specification/rbs-erasure.md) | Conservative erasure to RBS. |
| [`docs/type-specification/inference-budgets.md`](docs/type-specification/inference-budgets.md) | Budget table and boundary contracts. |
| [`docs/type-specification/diagnostic-policy.md`](docs/type-specification/diagnostic-policy.md) | Diagnostic identifier taxonomy and suppression markers. |

### Analyzer-internal contracts (normative)

| Document | Scope |
| --- | --- |
| [`docs/internal-spec/README.md`](docs/internal-spec/README.md) | Index of analyzer-side surfaces. |
| [`docs/internal-spec/internal-type-api.md`](docs/internal-spec/internal-type-api.md) | Public type-object surface (the contract every `Rigor::Type::*` carrier satisfies). |
| [`docs/internal-spec/inference-engine.md`](docs/internal-spec/inference-engine.md) | Engine surface (`Scope`, fact store, effect model, capability-role inference, normalization, RBS erasure routing). |
| [`docs/internal-spec/implementation-expectations.md`](docs/internal-spec/implementation-expectations.md) | Engine-surface stability and public-API contract. |

### Architecture decision records (rationale)

ADRs record design rationale and rejected / deferred alternatives. **The canonical index — title + current implementation status for every ADR — is [`docs/adr/README.md`](docs/adr/README.md)**; open the individual ADR for its full working-decision detail. When an ADR and the spec disagree on analyzer behaviour, the spec binds.

The list below is an **index, not a summary**: one line per ADR, topic only, capped at 100 characters and carrying no status, dates, or measurements — it answers only *does a decision about this exist, and on what subject*. Go to `docs/adr/README.md` for status and to the ADR for detail. This file is loaded into context every session, so the cap is [ADR-97](docs/adr/97-adr-index-budgets.md)'s budget decision and `spec/docs/agent_index_spec.rb` enforces it under `make docs-check`.

- [ADR-0](docs/adr/0-concept.md) — Project concept and design boundaries
- [ADR-1](docs/adr/1-types.md) — Type model and RBS-superset strategy
- [ADR-2](docs/adr/2-extension-api.md) — Plugin extension API
- [ADR-3](docs/adr/3-type-representation.md) — Internal type-object representation
- [ADR-4](docs/adr/4-type-inference-engine.md) — Type inference engine
- [ADR-5](docs/adr/5-robustness-principle.md) — Robustness principle (Postel's law for types)
- [ADR-6](docs/adr/6-cache-persistence-backend.md) — Cache persistence backend
- [ADR-7](docs/adr/7-v0.1.0-slice-decisions.md) — v0.1.0 slice decisions
- [ADR-8](docs/adr/8-steep-inspired-improvements.md) — Steep-inspired diagnostic improvements
- [ADR-9](docs/adr/9-cross-plugin-api.md) — Cross-plugin API (`FactStore` + `prepare(services)` + `produces:` / `consumes:`)
- [ADR-10](docs/adr/10-dependency-source-inference.md) — Opt-in dependency-source inference
- [ADR-11](docs/adr/11-sorbet-input-adapter.md) — Sorbet input adapter (`rigor-sorbet`)
- [ADR-12](docs/adr/12-dry-rb-packaging.md) — dry-rb adapter packaging
- [ADR-13](docs/adr/13-typenode-resolver-plugin.md) — `TypeNodeResolver` + shape-projection type functions
- [ADR-14](docs/adr/14-rbs-sig-generation.md) — `rigor sig-gen` RBS generation
- [ADR-15](docs/adr/15-ractor-concurrency.md) — Ractor concurrency model
- [ADR-16](docs/adr/16-macro-expansion.md) — Macro / DSL expansion substrate
- [ADR-17](docs/adr/17-monkey-patch-pre-evaluation.md) — Project-side monkey-patch pre-evaluation (`pre_eval:`)
- [ADR-18](docs/adr/18-substrate-per-call-site-return-type.md) — Substrate per-call-site return type (`returns_from_arg:`)
- [ADR-19](docs/adr/19-language-server-packaging.md) — Language Server packaging (`rigor lsp`)
- [ADR-20](docs/adr/20-lightweight-hkt.md) — Lightweight HKT (`App[F, A]`)
- [ADR-21](docs/adr/21-rubydex-evaluation.md) — Rubydex evaluation
- [ADR-22](docs/adr/22-baseline-and-project-onboarding.md) — Baseline + project onboarding (`.rigor-baseline.yml`)
- [ADR-23](docs/adr/23-diagnostic-triage-command.md) — `rigor triage` diagnostic triage command
- [ADR-24](docs/adr/24-self-method-call-resolution.md) — Implicit-self method-call resolution
- [ADR-25](docs/adr/25-plugin-contributed-rbs.md) — Plugin-contributed RBS (`signature_paths:`)
- [ADR-26](docs/adr/26-activerecord-relation-typing.md) — ActiveRecord relation typing (`open_receivers:`)
- [ADR-27](docs/adr/27-tool-distribution-model.md) — Tool distribution + installation model
- [ADR-28](docs/adr/28-path-scoped-protocol-contracts.md) — Path-scoped protocol contracts (`protocol_contracts:`)
- [ADR-29](docs/adr/29-browser-playground.md) — Browser playground
- [ADR-30](docs/adr/30-rigor-ffi-plugin-shape.md) — `rigor-ffi` plugin family shape
- [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md) — Contribution + supply-chain policy
- [ADR-32](docs/adr/32-rbs-inline-comment-ingestion.md) — Inline-RBS comment ingestion (`rigor-rbs-inline`)
- [ADR-33](docs/adr/33-mcp-server.md) — MCP server packaging (`rigor mcp`)
- [ADR-34](docs/adr/34-toplevel-unresolved-self-call-default.md) — Toplevel unresolved-self-call diagnostic
- [ADR-35](docs/adr/35-override-signature-compatibility.md) — Override signature compatibility (Liskov signature rule)
- [ADR-36](docs/adr/36-mangrove-enum-nested-class-emission.md) — Macro-substrate nested-class emission tier (Mangrove `Enum`)
- [ADR-37](docs/adr/37-plugin-interface-segregation.md) — Plugin interface segregation (narrow extension protocols)
- [ADR-38](docs/adr/38-additional-initializers.md) — Plugin-declared additional initializers (`additional_initializers:`)
- [ADR-39](docs/adr/39-plugin-target-library-invocation.md) — Plugins may invoke their target library's safe methods directly
- [ADR-40](docs/adr/40-config-schema-defaults.md) — `config_schema` declared defaults (`{kind:, default:}`)
- [ADR-41](docs/adr/41-inference-budget-design.md) — Inference budget design (wiring, on-hit policy, measurement-gated defaults)
- [ADR-42](docs/adr/42-plugin-binary-operator-return-types.md) — Plugin-contributed binary-operator return types (coerce-direction)
- [ADR-43](docs/adr/43-rbs-complete-ancestor-resolution.md) — RBS-complete ancestor resolution (allow-list inherited-method dispatch)
- [ADR-44](docs/adr/44-dispatch-allocation-churn.md) — Per-dispatch / per-narrow allocation churn (Scope, CallContext)
- [ADR-45](docs/adr/45-unchanged-project-fast-path.md) — Unchanged-project fast path (run-result cache)
- [ADR-46](docs/adr/46-incremental-dependency-graph.md) — Incremental analysis via a cross-file dependency graph
- [ADR-47](docs/adr/47-narrowing-driven-clause-reachability.md) — Narrowing-driven clause reachability (`flow.unreachable-clause`)
- [ADR-48](docs/adr/48-data-struct-value-folding.md) — Struct / Data value folding (member-shape carriers)
- [ADR-49](docs/adr/49-adr-authoring-guidelines.md) — ADR authoring guidelines (a rubric for necessary-and-sufficient ADRs)
- [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) — Release engineering and stability strategy (v0.2.0 → v1.0.0)
- [ADR-51](docs/adr/51-ci-diagnostic-output-formats.md) — CI-native diagnostic output formats
- [ADR-52](docs/adr/52-compiled-plugin-contribution-dispatch.md) — Compiled plugin contribution dispatch
- [ADR-53](docs/adr/53-scope-discovery-index-separation.md) — Scope discovery-index separation + check-rule walk consolidation
- [ADR-54](docs/adr/54-cache-slimming.md) — Cache slimming: definitions-blob retirement, payload compression, default eviction
- [ADR-55](docs/adr/55-recursive-return-precision.md) — Recursive-method return-type precision
- [ADR-56](docs/adr/56-block-captured-local-mutation.md) — Block-captured local write-back and loop-body fixpoint
- [ADR-57](docs/adr/57-self-call-return-adoption.md) — Opening the implicit-self call return-adoption gate
- [ADR-58](docs/adr/58-ivar-field-typing.md) — Instance-variable field typing
- [ADR-59](docs/adr/59-spec-assertions-are-not-signatures.md) — Spec assertions are not implementation signatures
- [ADR-60](docs/adr/60-pre-freeze-plugin-contract-consolidation.md) — Pre-freeze plugin contract consolidation
- [ADR-61](docs/adr/61-agent-friendly-diagnostic-statistics.md) — Agent-friendly diagnostic statistics (structured selector axis)
- [ADR-62](docs/adr/62-mutation-testing-teeth-measurement.md) — Mutation-testing the analyzer (false-negative / teeth measurement)
- [ADR-63](docs/adr/63-type-protection-coverage.md) — User-facing type-protection coverage
- [ADR-64](docs/adr/64-non-nil-argument-type-mismatch.md) — Non-nil argument-type-mismatch and the coerce barrier
- [ADR-65](docs/adr/65-diagnostic-evidence-tier-and-doc-url.md) — Diagnostic evidence tier and documentation URL
- [ADR-66](docs/adr/66-discriminated-union-member-typing.md) — Discriminated-union member typing (tag-keyed narrowing)
- [ADR-67](docs/adr/67-parameter-type-inference.md) — Parameter type inference (the M3 frontier)
- [ADR-68](docs/adr/68-class-builder-folding.md) — Plugin-declarable class-builder folding
- [ADR-69](docs/adr/69-pluggable-mutation-substrate.md) — Pluggable mutation substrate (kill-oracle + operator seam)
- [ADR-70](docs/adr/70-fused-protection-coverage.md) — Fused static∪dynamic protection coverage
- [ADR-71](docs/adr/71-type-guided-external-mutation-testing.md) — Type-guided external incremental mutation testing
- [ADR-72](docs/adr/72-gemfile-lock-gated-rbs-overlays.md) — Gemfile.lock-gated bundled RBS overlays
- [ADR-73](docs/adr/73-skill-driven-user-experience.md) — SKILL-driven Rigor user experience
- [ADR-74](docs/adr/74-offline-doc-access-and-llms-txt.md) — Offline doc access (`rigor docs`) + `llms.txt` linkage
- [ADR-75](docs/adr/75-dynamic-provenance.md) — `Dynamic[T]` provenance and explanation
- [ADR-76](docs/adr/76-effect-modeling-freeze-dup-shape-preservation.md) — Effect modeling for `freeze` / `dup` / `clone` and shape-carrier preservation
- [ADR-77](docs/adr/77-doctor-and-upgrade-commands.md) — `rigor doctor` and `rigor upgrade` evidence-routing commands
- [ADR-78](docs/adr/78-reflexive-overfold-always-truthy.md) — Reflexive over-fold and the `flow.always-truthy-condition` envelope
- [ADR-79](docs/adr/79-rbs-version-range-over-pinned-determinism.md) — RBS version-range fidelity over checker-pinned determinism
- [ADR-80](docs/adr/80-narrowing-facts-rename.md) — Rename the `type_specifier` plugin hook to `narrowing_facts`
- [ADR-81](docs/adr/81-skill-set-optimization.md) — Skill-set optimization: per-skill freshness + the `waza` evaluation stance
- [ADR-82](docs/adr/82-dynamic-provenance-wiring.md) — `Dynamic[T]` provenance wiring: breaking the catch-all on real apps
- [ADR-83](docs/adr/83-dynamic-origin-algebra.md) — Dynamic-origin algebra: keep union arms over absorbing into `Dynamic`
- [ADR-84](docs/adr/84-cross-file-return-memo-scoping.md) — Cross-file return-memo scoping and the taint-precise store gate
- [ADR-85](docs/adr/85-seed-bundles-and-lazy-def-node-handles.md) — Per-file seed bundles and lazy def-node handles
- [ADR-86](docs/adr/86-partial-native-extensions.md) — Partial native extensions for residual hot paths (rejected; rigor-rs owns native speed)
- [ADR-87](docs/adr/87-null-build-floor.md) — The null-build floor: stat-then-digest validation and hit-path boot slimming
- [ADR-88](docs/adr/88-incremental-plugin-fact-soundness.md) — Incremental plugin-fact soundness
- [ADR-89](docs/adr/89-semantic-propagation-gates.md) — Semantic propagation gates: declaration-shape and observed-key return summaries
- [ADR-90](docs/adr/90-target-library-resolution-from-project-bundle.md) — Target-library resolution from the analyzed project's bundle
- [ADR-91](docs/adr/91-kernel-intrinsic-fold-ownership-gate.md) — Kernel intrinsic fold ownership gate + spelling-parity invariant
- [ADR-92](docs/adr/92-normative-status-fidelity.md) — Normative status fidelity: the founding-era stratum and the declare-or-mark gate
- [ADR-93](docs/adr/93-default-rbs-inline-ingestion.md) — Default rbs-inline ingestion: reconciling ADR-32's opt-in with the always-parse spec
- [ADR-94](docs/adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md) — The inline-RBS reader: `RBS::InlineParser` and the rbs 3.x floor
- [ADR-95](docs/adr/95-homebrew-tap-deferral.md) — Homebrew distribution: deferred behind the single binary
- [ADR-96](docs/adr/96-plugin-target-gems.md) — Plugin target-gem declaration, the plugin-gap advisory, and presence-gated umbrella expansion
- [ADR-97](docs/adr/97-adr-index-budgets.md) — Index entries are not summaries: the ADR-index budgets and their gate

## Skills available in this repository

Skills follow the [Anthropic Agent Skills](https://agentskills.io/) shape — a directory with a `SKILL.md` carrying YAML `name:` + `description:` frontmatter. All SKILLs live under [`.claude/skills/`](.claude/skills/) and are auto-discovered by Claude Code inside this repo. They are **contributor workflows** that assume the monorepo's `Makefile`, `spec/integration/`, `.rubocop.yml`, and `plugins/` / `examples/` layout. A separate **external-author** SKILL (for writing a parallel `rigor-foo` gem in your own repo per [ADR-31 WD4](docs/adr/31-contribution-and-supply-chain-policy.md)) is queued for v0.2.0; until then `rigor-plugin-author`'s Phase 0.5 routes non-maintainer plugin requests to ADR-31's third-party path.

| Skill | Use when |
| --- | --- |
| [`rigor-release-prep`](.claude/skills/rigor-release-prep/SKILL.md) | Preparing a RubyGems release: bump `Rigor::VERSION`, update `CHANGELOG.md`, regenerate `Gemfile.lock`, build, and `bundle exec rake release`. |
| [`rigor-builtin-import`](.claude/skills/rigor-builtin-import/SKILL.md) | Importing a Ruby core / stdlib class into the catalog-driven inference pipeline (the nine-stage flow + its non-mechanical decision points). |
| [`rigor-add-reference`](.claude/skills/rigor-add-reference/SKILL.md) | Adding a new upstream repo as a `references/` submodule (the three-file atomic change + full vs. sparse checkout choice). |
| [`rigor-ruby-version-bump`](.claude/skills/rigor-ruby-version-bump/SKILL.md) | Bumping the development Ruby version across every project marker (`flake.nix`, `.ruby-version`, `Gemfile` / `Gemfile.lock`, `AGENTS.md`), with the files that stay untouched. |
| [`rigor-dependency-update`](.claude/skills/rigor-dependency-update/SKILL.md) | Refreshing both dependency layers in one pass — bundled gems (`bundle update`, `Gemfile.lock`) and the Nix Flake dev env (`nix flake update`, `flake.lock`'s nixpkgs pin) — one commit per layer, plus the native-extension rebuild a nixpkgs bump forces. Not for a Ruby-version bump or a `references/` submodule. |
| [`rigor-plugin-author`](.claude/skills/rigor-plugin-author/SKILL.md) | "Create a Rigor plugin for X." Phase 0.5 routes non-maintainers to [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md); maintainers follow requirements → template → scaffold → walker → integration spec → CHANGELOG. |
| [`rigor-ffi-plugin-author`](.claude/skills/rigor-ffi-plugin-author/SKILL.md) | FFI sibling of `rigor-plugin-author`. Starts by *talking you out of* a plugin when core `rigor-ffi` suffices; otherwise routes through ADR-31. |
| [`rigor-regression-sweep`](.claude/skills/rigor-regression-sweep/SKILL.md) | Multi-version baseline-drift sweep against a real OSS Ruby project; tabulates the surfaced-diagnostic curve and grows the `docs/notes/` corpus. |
| [`rigor-adr-author`](.claude/skills/rigor-adr-author/SKILL.md) | "Write an ADR for X." The procedure for adding a `docs/adr/` record: tag archetype + stakes, pick the matching skeleton, write sized-to-stakes (economy is the corpus's one drift), then the mechanical wiring (next number, the ascending-order `docs/adr/README.md` index row, the `CLAUDE.md` bullet, verify). Defers to [ADR-49](docs/adr/49-adr-authoring-guidelines.md) for the binding quality rubric. |
| [`rigor-docs-review`](.claude/skills/rigor-docs-review/SKILL.md) | "Review the docs / manual / handbook" / "査読して". The multi-lens review battery over `docs/manual/` + `docs/handbook/`: L0 mechanical gate (`make docs-check`) → L1 fidelity → L2 reader lenses → L3 bloat (inverted) → L4 copyedit, run as independent-context subagents, parallel-within / sequential-across, findings to `docs/notes/`. Methodology freeze; design in [`docs/notes/20260610-user-docs-review-battery-design.md`](docs/notes/20260610-user-docs-review-battery-design.md). |
| [`rigor-prior-art`](.claude/skills/rigor-prior-art/SKILL.md) | "過去に評価/調査したことある?" / "what does the corpus say about X?". Corpus archaeology with citation-grade output: the corpus map (CLAUDE.md ADR bullets first; archived CHANGELOGs — currently `docs/CHANGELOG-0.1.x.md` — are the comparative-evidence trove), a three-class source taxonomy (first-party evaluation / external material incl. `deep-research/` / mere mention), verify-before-cite (`cat -v`), and an output contract that reports absences ("no head-to-head run exists") to prevent overclaiming. Use before publishing any comparative claim about Rigor. |

### Evaluating skills with `waza`

`waza` is an Agent-Skill evaluation CLI in the Flake. Run `waza check <skill-path>` **once after authoring a new SKILL.md** as a spec-compliance sanity check (frontmatter / required fields / name-matches-directory). Treat everything else it reports as **informational** — its token-budget, module-count, complexity, and `USE FOR:` / `**UTILITY SKILL**` markers are calibrated for agentskills.io publication and do not apply to these comprehensive single-file contributor skills. Do **not** run `waza dev --auto`: it injects frequently-false `USE FOR:` / `INVOKES:` boilerplate. The hand-written `name:` + `description:` pair is the binding surface.

## Commit, release, and verification

These mirror [`AGENTS.md`](AGENTS.md) — it is authoritative; the essentials:

- **Commits**: plain imperative subject in sentence case, no `type:` / `area:` prefixes; why-not-diff body wrapped at ~72 cols. Version bumps use `Bump up version to x.y.z`. See AGENTS.md §§ "Commit Messages", "Release Cadence", "CHANGELOG Style".
- **Verification**: after non-trivial changes run, inside the Flake, `make verify` then `git diff --check`. `make verify` chains `test` / `lint` / `check` / `check-plugins`; the `check` target (`bundle exec exe/rigor check lib`) is Rigor's own self-check and `check-plugins` (`rigor check plugins/*/lib examples/*/lib`, ADR-43) is the plugin-contract self-check — both MUST stay clean. Fix the cause (engine regression, a missing per-class blocklist entry, or a genuine plugin contract misuse), never disable the rule. Mention any skipped verification when the Flake shell is unavailable.

## Notes for delegated agents

- Do NOT bypass the Flake. `bundle`, `rake`, `rspec`, `rubocop`, and `exe/rigor` MUST run inside `nix … develop` per AGENTS.md.
- Do NOT modify `references/` submodules unless the task is "bump references/<name>". The vendored sources are read-only; engine changes happen against Rigor's own code.
- Do NOT run `bundle exec rake release` without explicit user authorisation. The release task tags `vx.y.z`, pushes to origin, and publishes to RubyGems.
- Prefer `rigor sig-gen` (ADR-14) over AI-authored RBS in this repo — gaps in sig-gen are the more valuable signal than freehand RBS. Full policy + the `tighter-return` no-overwrite rule live in [`AGENTS.md`](AGENTS.md) § "RBS Authorship".
- The reading order for a returning implementer is in [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md); treat it as the resume bookmark, not a normative spec.
