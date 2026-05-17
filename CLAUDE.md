# CLAUDE.md

Project-level briefing for Claude (and any other agent that reads top-level docs by convention). The authoritative agent contract for this repository is [`AGENTS.md`](AGENTS.md) — read it first; this file is a navigation index that points at the documents an agent typically needs and the per-task skills bundled with the project.

## Read these first

| Document | Purpose |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Development environment (Flake mandate, target Ruby), common commands, directory layout, references/ submodule rules, implementation guidelines, commit-message style, release cadence, and verification protocol. **Required reading.** |
| [`README.md`](README.md) | User-facing project overview (CLI, what `rigor check` does today). |
| [`docs/handbook/`](docs/handbook/README.md) | Nine-chapter end-user walkthrough of the type model. Reach for this when you need to explain Rigor concepts to a Ruby programmer (or to yourself) without diving into the spec corpus. Informational; the spec binds. |
| [`docs/types.md`](docs/types.md) | One-page quick guide to the Rigor type system. Faster mental-model warm-up than the handbook when you only need the carrier zoo. |
| [`docs/lsp-integration.md`](docs/lsp-integration.md) | User-facing setup guide for `rigor lsp` across Neovim / VSCode / Helix / Emacs. Covers CLI flags, troubleshooting, performance expectations. Companion to the LSP design docs under `docs/design/`. |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Forward-looking commitment envelope. Holds the active in-flight cycle in full detail + future-cycle plans + open questions. Released versions are reduced to one-line pointers to `CHANGELOG.md` (which is the authoritative "what shipped" record). Update entries in the same commit when scope changes. |
| [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) | Resume bookmark for the next implementer. Names the current ship-readiness state, the next-session entry slice, parallel tracks, and open engineering items. Transient — refresh when you take a substantial change set across the finish line. |
| [`docs/design/20260508-rails-plugins-roadmap.md`](docs/design/20260508-rails-plugins-roadmap.md) | Roadmap for the `rigor-*` Rails ecosystem plugins. Tier table, dependency graph, per-plugin sketches, subtree-split readiness checklist. Use when planning new Rails-side plugin work. |
| [`examples/README.md`](examples/README.md) | Plugin-authoring landing page. **Canonical inventory** of every worked plugin example with a comparison table + recommended reading order; the count drifts as new plugins land, so consult it here rather than hard-coding in upstream docs. Reach for this when authoring a plugin or answering "how do I use the plugin contract for X?". |

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

| ADR | Topic |
| --- | --- |
| [`docs/adr/0-concept.md`](docs/adr/0-concept.md) | Project concept and design boundaries. |
| [`docs/adr/1-types.md`](docs/adr/1-types.md) | Type model and RBS-superset strategy. |
| [`docs/adr/2-extension-api.md`](docs/adr/2-extension-api.md) | Plugin extension surface (deferred to v0.1.0). |
| [`docs/adr/3-type-representation.md`](docs/adr/3-type-representation.md) | Internal type-object layout. Working decisions for OQ1 (Constant scalar shape — Hybrid), OQ2 (predicate naming — drop the `?`), OQ3 (refinement carrier — Difference + Refined). |
| [`docs/adr/4-type-inference-engine.md`](docs/adr/4-type-inference-engine.md) | Inference-engine architecture. |
| [`docs/adr/5-robustness-principle.md`](docs/adr/5-robustness-principle.md) | Design rationale for Postel's law. Companion to `docs/type-specification/robustness-principle.md`. |
| [`docs/adr/6-cache-persistence-backend.md`](docs/adr/6-cache-persistence-backend.md) | Cache persistence backend choice (sharded directory of binary entries, per-file `flock` write atomicity, no eviction). |
| [`docs/adr/7-v0.1.0-slice-decisions.md`](docs/adr/7-v0.1.0-slice-decisions.md) | Working decisions for v0.1.0 slices 4 – 6 (FlowContribution wiring through internal narrowing, plugin diagnostic emission protocol, plugin-side cache producers). |
| [`docs/adr/8-steep-inspired-improvements.md`](docs/adr/8-steep-inspired-improvements.md) | Working decisions for the Steep-inspired improvements (diagnostic family hierarchy, severity profile, `def.return-type-mismatch` rule). |
| [`docs/adr/9-cross-plugin-api.md`](docs/adr/9-cross-plugin-api.md) | Proposed cross-plugin API (`Plugin::FactStore` + `Plugin::Base#prepare(services)` + `manifest(consumes:)`). Queued for v0.1.x. Required before `rigor-actionpack` Phase 1 / `rigor-factorybot` can land. |
| [`docs/adr/10-dependency-source-inference.md`](docs/adr/10-dependency-source-inference.md) | Proposed opt-in `dependencies.source_inference` for gems shipping no RBS / RBS::Inline. Walker contributes `Dynamic[T]` returns at a dispatcher tier strictly below plugins. Per-gem budget pools, per-gem-version cache slice, hard-excluded `spec/` / `test/` / `bin/` / C extensions. Implementation queued (target v0.1.3+). |
| [`docs/adr/11-sorbet-input-adapter.md`](docs/adr/11-sorbet-input-adapter.md) | Proposed `rigor-sorbet` plugin adapter that ingests Sorbet `sig { ... }` blocks, `T.let` / `T.cast` / `T.must` / `T.bind` / `T.absurd`, and RBI files as type sources. Translation at the plugin boundary; core stays RBS-canonical per ADR-0 / ADR-1. Runtime enforcement remains `sorbet-runtime`'s job. Implementation queued (no committed milestone). |
| [`docs/adr/12-dry-rb-packaging.md`](docs/adr/12-dry-rb-packaging.md) | Accepted decision (2026-05-16) on packaging the dry-rb adapter plugin family. **Per-gem plugins + planned `rigor-dry-rb` meta umbrella**, matching the Rails plugin pattern. `rigor-dry-struct` (LANDED v0.1.5) already follows the shape; next concrete slice is `rigor-dry-types` as the Tier A foundation. Cross-plugin channels: `:dry_type_aliases`, `:dry_struct_attributes`, `:dry_validation_keys`. |
| [`docs/adr/13-typenode-resolver-plugin.md`](docs/adr/13-typenode-resolver-plugin.md) | Proposed `Plugin::TypeNodeResolver` extension point + five Rigor-canonical shape-projection type functions (`pick_of` / `omit_of` / `partial_of` / `required_of` / `readonly_of`) + opt-in `rigor-typescript-utility-types` plugin adapter for TS-canonical names (`Pick` / `Omit` / `Partial` / `Required` / `Readonly` / …). Mirrors PHPStan's `TypeNodeResolverExtension`. Core stays RBS-canonical per ADR-0 / ADR-1; TS names are plugin-supplied. Implementation queued (no committed milestone). |
| [`docs/adr/14-rbs-sig-generation.md`](docs/adr/14-rbs-sig-generation.md) | Proposed `rigor sig-gen` CLI command that emits RBS from Rigor's inference results. Classifies each method as `new-file` / `new-method` / `tighter-return` / `equivalent` / `skipped`; `--params` policy (`untyped` default, `observed` opt-in, `observed-strict` reserved) enforces the ADR-5 robustness asymmetry. The project's standard tool for closing RBS coverage gaps. Implementation slicing authorised; slice 1 (MVP — `def`, return-only, `--print` / `--diff`) in progress. |
| [`docs/adr/15-ractor-concurrency.md`](docs/adr/15-ractor-concurrency.md) | Proposed Ractor-based concurrency model for the analyzer. Four-phase staged migration: (1) value-object shareability audit (LANDED); (2a) `Configuration` deep-freeze (LANDED); (2b) `Environment` / `RbsLoader` split into frozen reflection facade + per-Ractor cache layer; (3) plugin contract refactored for per-Ractor instantiation; (4) `Analysis::Runner` Ractor worker pool. Thread-based parallelism was prototyped + reverted (GVL blocks CPU-bound speedup); fork-based parallelism remains a parallel non-exclusive option. ADR-15 binds the Ractor direction; ADR-2 / ADR-4 / ADR-6 gain matching boundary notes. |
| [`docs/adr/16-macro-expansion.md`](docs/adr/16-macro-expansion.md) | Proposed four-tier macro / DSL expansion substrate covering (A) block-as-method (Sinatra-shape), (B) trait-inlining via bundled module registry (Devise / AASM / Sequel associations), (C) heredoc-template expansion parameterised by literal-symbol arguments (ActiveStorage / Devise helpers / Redmine setting accessors), (D) external-Ruby-file inclusion under declared `self` (Redmine webhook payloads / tDiary plugins). Concern re-targeting handled by walker extension, not a separate tier. Grounded in the eight-library survey at [`docs/notes/20260515-macro-expansion-library-survey.md`](docs/notes/20260515-macro-expansion-library-survey.md). Substrate is opt-in per plugin via manifest entries; integrates with ADR-2 plugin contract, ADR-6 cache, ADR-9 fact-store, ADR-13 TypeNode resolver, ADR-15 Ractor isolation. Closes ROADMAP O2. Implementation queued (no committed milestone). |
| [`docs/adr/17-monkey-patch-pre-evaluation.md`](docs/adr/17-monkey-patch-pre-evaluation.md) | Proposed `pre_eval:` config axis that names project files Rigor MUST walk before per-file inference, populating a project-wide `Inference::ProjectPatchedMethods` registry consulted at a new dispatcher tier between plugins and dependency-source inference. MVP shape: **explicit list only** (`pre_eval: [lib/core_ext/string_extensions.rb]`); pattern-based discovery + full-project 2-pass + plugin-API hook remain demand-driven follow-ups. Fail-soft on parse errors, loud on file-not-found. Boundary with ADR-16 Tier D is clean (Tier D is plugin-declared external-file inclusion; ADR-17 is user-declared project-patch registration). Implementation queued (no committed milestone). |
| [`docs/adr/18-substrate-per-call-site-return-type.md`](docs/adr/18-substrate-per-call-site-return-type.md) | Proposed [ADR-16](docs/adr/16-macro-expansion.md) amendment introducing `returns_from_arg:` (the `lookup_via:` declarative DSL referencing a cross-plugin fact) on `Plugin::Macro::HeredocTemplate::Emit` rows. Lets a substrate template's synthesised method return type vary per call site by argument source representation — the missing mechanism `rigor-dry-struct`'s `attribute :city, Types::String` precision uplift needs. Three-tier fallback (`returns_from_arg:` → static `returns:` → `Dynamic[Top]`); declarative `lookup_via: { plugin_id:, fact: }` keeps plugin code out of substrate-pre-pass time per ADR-2 / ADR-15. Implementation queued (no committed milestone). |
| [`docs/adr/19-language-server-packaging.md`](docs/adr/19-language-server-packaging.md) | Accepted decision (2026-05-17) on packaging the Language Server. **Bundled in `rigortype` gem (`rigor lsp` subcommand)** — same shape as Steep / Solargraph. Rejected alternatives: (B) standalone `rigor-lsp` gem (forces internal-API public stability or duplication), (C) `ruby-lsp-rigor` Ruby LSP addon (significant rearchitecture, surrenders LSP-lifecycle control). Five trigger conditions for re-evaluation enumerated; none expected to fire in v0.1.x or v0.2.x. Naming convention if split: `rigor-lsp` (matches plugin family prefix) or `ruby-lsp-rigor` (Ruby LSP addon convention). Companion to [`docs/design/20260517-language-server.md`](docs/design/20260517-language-server.md). |
| [`docs/adr/20-lightweight-hkt.md`](docs/adr/20-lightweight-hkt.md) | Proposed (2026-05-18) Lightweight HKT mechanism for type-level computation in signatures. Defunctionalised tag + `App[F, A]` carrier per Yallop & White 2014 / fp-ts `URItoKind`, built on the conditional / indexed-access rows already listed in `rigor-extensions.md`. Authoring stays in `.rbs` via two new `%a{rigor:v1:hkt_register}` / `%a{rigor:v1:hkt_define}` directives (ADR-0 / ADR-1 boundary holds). First concrete adopter is `JSON.parse`'s `untyped` slot, replaced by `App[json::value, K]` with per-option `K` discrimination via `return_override`. Six implementation slices sketched (carrier + parser; conditional evaluator; JSON.parse overlay; dry-monads `Result`/`Maybe`; sugar; plugin-side resolver hookup), no slice scheduled. Implementation queued (no committed milestone). |

## Skills available in this repository

The `.codex/skills/` tree carries per-task playbooks. Each skill has a `SKILL.md` describing when to invoke it and what steps it codifies.

| Skill | Use when |
| --- | --- |
| [`.codex/skills/rigor-release-prep/SKILL.md`](.codex/skills/rigor-release-prep/SKILL.md) | Preparing a RubyGems release: bumping `Rigor::VERSION`, updating `CHANGELOG.md` (Keep a Changelog 1.1.0), regenerating `Gemfile.lock`, building the gem, and running `bundle exec rake release`. |
| [`.codex/skills/rigor-builtin-import/SKILL.md`](.codex/skills/rigor-builtin-import/SKILL.md) | Importing a Ruby core / stdlib class into Rigor's catalog-driven inference pipeline. Records the nine-stage flow (locate sources → extend `TOPICS` → regenerate YAML → wire loader → curate `:leaf` blocklist → decide RBS::Extended overrides → fixture → verify → changelog) and the decision points where the procedure is NOT mechanical. |
| [`.codex/skills/rigor-plugin-author/SKILL.md`](.codex/skills/rigor-plugin-author/SKILL.md) | Authoring a new Rigor plugin from a user requirement under `examples/`. End-to-end pipeline: 5-question requirements gathering → template selection from the six existing examples → directory scaffold → AST walker pattern → integration spec → CHANGELOG `[Unreleased]` entry. Use whenever the user asks to "create a Rigor plugin for X" or similar. |
| [`.codex/skills/rigor-add-reference/SKILL.md`](.codex/skills/rigor-add-reference/SKILL.md) | Adding a new upstream repo as a reference submodule under `references/`. Covers the three-file atomic change (`.gitmodules` + Makefile `REFERENCE_SUBMODULES` + `init-submodules`) and the decision between full and sparse checkout strategies. |

## Commit message style (mirrors AGENTS.md)

- Plain imperative subject in sentence case. No Conventional-Commits-style `type:` or `area:` prefixes.
- Subject is self-contained and reasonably short; detail belongs in the body.
- Wrap the body at ~72 columns; explain the why, not the diff.
- Release version bumps follow the fixed form `Bump up version to x.y.z`.

## Verification protocol (mirrors AGENTS.md)

After non-trivial changes, run:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

`make verify` chains `make test`, `make lint`, and `make check`. The last target (`bundle exec exe/rigor check lib`) is the project's own self-check — it MUST stay clean. False positives there indicate either an engine regression or a missing per-class blocklist entry; fix the cause rather than disabling the rule.

If the Flake shell is unavailable, mention any skipped verification in the final report.

## Notes for delegated agents

- Do NOT bypass the Flake. `bundle`, `rake`, `rspec`, `rubocop`, and `exe/rigor` MUST run inside `nix … develop` per AGENTS.md.
- Do NOT modify `references/` submodules unless the task is "bump references/<name>". The vendored sources are read-only; engine changes happen against Rigor's own code.
- Do NOT run `bundle exec rake release` without explicit user authorisation. The release task tags `vx.y.z`, pushes to origin, and publishes to RubyGems.
- Prefer `rigor sig-gen` (ADR-14) over AI-authored RBS in this repo — the project's aspiration is for deterministic inference to be precise enough that AI suggestions are unnecessary, so gaps in sig-gen are the more valuable signal than freehand RBS. Full policy + the sig-gen output rule (do not overwrite `tighter-return` candidates that lose union members) live in [`AGENTS.md`](AGENTS.md) § "RBS Authorship".
- The reading order for a returning implementer is in [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md). It points back at the relevant ADRs and skills for the version in progress; treat it as the resume bookmark, not as a normative spec.
