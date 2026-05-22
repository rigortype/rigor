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
| ADR-0 | [Foundation and Core Architecture of Rigor](0-concept.md) | Accepted |
| ADR-1 | [Type Model and RBS Superset Strategy](1-types.md) | Draft |
| ADR-2 | [Extension API Strategy](2-extension-api.md) | Draft |
| ADR-3 | [Type Representation](3-type-representation.md) | Draft |
| ADR-4 | [Type Inference Engine](4-type-inference-engine.md) | Draft |
| ADR-5 | [Robustness Principle](5-robustness-principle.md) | Draft |
| ADR-6 | [Cache Persistence Backend](6-cache-persistence-backend.md) | Draft |
| ADR-7 | [v0.1.0 Slice Decisions](7-v0.1.0-slice-decisions.md) | Accepted |
| ADR-8 | [Steep-Inspired Improvements](8-steep-inspired-improvements.md) | Accepted |
| ADR-9 | [Cross-Plugin API](9-cross-plugin-api.md) | Proposed |
| ADR-10 | [Dependency Source Inference](10-dependency-source-inference.md) | Proposed |
| ADR-11 | [Sorbet Input Adapter](11-sorbet-input-adapter.md) | Proposed |
| ADR-12 | [dry-rb Packaging](12-dry-rb-packaging.md) | Accepted |
| ADR-13 | [TypeNode Resolver Plugin](13-typenode-resolver-plugin.md) | Proposed |
| ADR-14 | [RBS Sig Generation](14-rbs-sig-generation.md) | Proposed |
| ADR-15 | [Ractor Concurrency](15-ractor-concurrency.md) | Proposed |
| ADR-16 | [Macro Expansion](16-macro-expansion.md) | Accepted |
| ADR-17 | [Monkey Patch Pre-Evaluation](17-monkey-patch-pre-evaluation.md) | Proposed |
| ADR-18 | [Substrate Per-Call-Site Return Type](18-substrate-per-call-site-return-type.md) | Proposed |
| ADR-19 | [Language Server Packaging](19-language-server-packaging.md) | Accepted |
| ADR-20 | [Lightweight HKT](20-lightweight-hkt.md) | Accepted |
| ADR-21 | [Rubydex Evaluation](21-rubydex-evaluation.md) | Proposed |
| ADR-22 | [Baseline and Project Onboarding](22-baseline-and-project-onboarding.md) | Proposed |
| ADR-23 | [Diagnostic Triage Command](23-diagnostic-triage-command.md) | Proposed |
| ADR-24 | [Self Method Call Resolution](24-self-method-call-resolution.md) | Proposed |
| ADR-25 | [Plugin Contributed RBS](25-plugin-contributed-rbs.md) | Accepted |
| ADR-26 | [ActiveRecord Relation Typing](26-activerecord-relation-typing.md) | Accepted |
| ADR-27 | [Tool Distribution and Installation Model](27-tool-distribution-model.md) | Proposed |

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
