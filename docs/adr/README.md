# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for Rigor. Each document captures a significant design decision, its context, the options considered, and the consequences.

## How to Read

- **ADR-0** is the foundation document — start here for the project's core principles and architecture.
- **ADR-1** through **ADR-3** define the type model, extension API, and type representation — the analyzer's conceptual core.
- Higher-numbered ADRs build on the foundation and can be read as needed.
- Each ADR has a **Status** field: `Accepted`, `Draft`, or `Superseded`.

## Index

| # | Title | Status |
| --- | --- | --- |
| [0](0-concept.md) | Foundation and Core Architecture of Rigor | Accepted |
| [1](1-types.md) | Type Model and RBS Superset Strategy | Draft |
| [2](2-extension-api.md) | Extension API Strategy | Draft |
| [3](3-type-representation.md) | Type Representation | — |
| [4](4-type-inference-engine.md) | Type Inference Engine | — |
| [5](5-robustness-principle.md) | Robustness Principle | — |
| [6](6-cache-persistence-backend.md) | Cache Persistence Backend | — |
| [7](7-v0.1.0-slice-decisions.md) | v0.1.0 Slice Decisions | — |
| [8](8-steep-inspired-improvements.md) | Steep-Inspired Improvements | — |
| [9](9-cross-plugin-api.md) | Cross-Plugin API | — |
| [10](10-dependency-source-inference.md) | Dependency Source Inference | — |
| [11](11-sorbet-input-adapter.md) | Sorbet Input Adapter | — |
| [12](12-dry-rb-packaging.md) | dry-rb Packaging | — |
| [13](13-typenode-resolver-plugin.md) | TypeNode Resolver Plugin | — |
| [14](14-rbs-sig-generation.md) | RBS Sig Generation | — |
| [15](15-ractor-concurrency.md) | Ractor Concurrency | — |
| [16](16-macro-expansion.md) | Macro Expansion | — |
| [17](17-monkey-patch-pre-evaluation.md) | Monkey Patch Pre-Evaluation | — |
| [18](18-substrate-per-call-site-return-type.md) | Substrate Per-Call-Site Return Type | — |
| [19](19-language-server-packaging.md) | Language Server Packaging | — |
| [20](20-lightweight-hkt.md) | Lightweight HKT | — |
| [21](21-rubydex-evaluation.md) | Rubydex Evaluation | — |
| [22](22-baseline-and-project-onboarding.md) | Baseline and Project Onboarding | — |
| [23](23-diagnostic-triage-command.md) | Diagnostic Triage Command | — |
| [24](24-self-method-call-resolution.md) | Self Method Call Resolution | — |
| [25](25-plugin-contributed-rbs.md) | Plugin Contributed RBS | — |
| [26](26-activerecord-relation-typing.md) | ActiveRecord Relation Typing | — |

## Adding a New ADR

When making a significant architectural decision:

1. Find the next available number in this directory.
2. Copy the template from an existing ADR or create a new file following the same structure: Status, Context, Decisions, Consequences.
3. Add an entry to the index table above.
4. Reference the ADR from relevant code comments, other ADRs, or `AGENTS.md` where appropriate.

## Relationship to Other Documents

- **`docs/types.md`** — Type specification quick guide. When ADR-1 and `docs/types.md` discuss the same area, `docs/types.md` is authoritative for *what the analyzer does*; ADR-1 is authoritative for *why*.
- **`docs/type-specification/`** — Normative type specification, split into topical documents.
- **`docs/internal-spec/`** — Analyzer-internal contracts (engine surface, type-object public API).
- **`docs/handbook/`** — End-user handbook, written for Ruby programmers without prior static-typing background.
- **`AGENTS.md`** — Development contract for agents working in this repository.
