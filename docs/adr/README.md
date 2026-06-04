# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for Rigor. Each document captures a significant design decision, its context, the options considered, and the consequences.

## How to Read

- **ADR-0** is the foundation document — start here for the project's core principles and architecture.
- **ADR-1** through **ADR-3** define the type model, extension API, and type representation — the analyzer's conceptual core.
- Higher-numbered ADRs build on the foundation and can be read as needed.
- Each ADR has a **Status** field: `Accepted`, `Proposed`, or `Superseded`. Accepted ADRs whose implementation is still in flight carry a parenthetical note (e.g. *partially implemented*, *slice N deferred*).

## Index

| # | Title | Status |
| --- | --- | --- |
| ADR-0 | [Foundation and Core Architecture of Rigor](0-concept.md) | Accepted |
| ADR-1 | [Type Model and RBS Superset Strategy](1-types.md) | Accepted |
| ADR-2 | [Extension API Strategy](2-extension-api.md) | Accepted |
| ADR-3 | [Type Representation](3-type-representation.md) | Accepted |
| ADR-4 | [Type Inference Engine](4-type-inference-engine.md) | Accepted |
| ADR-5 | [Robustness Principle](5-robustness-principle.md) | Accepted |
| ADR-6 | [Cache Persistence Backend](6-cache-persistence-backend.md) | Accepted |
| ADR-7 | [v0.1.0 Slice Decisions](7-v0.1.0-slice-decisions.md) | Accepted |
| ADR-8 | [Steep-Inspired Improvements](8-steep-inspired-improvements.md) | Accepted |
| ADR-9 | [Cross-Plugin API](9-cross-plugin-api.md) | Accepted (implemented in v0.1.1) |
| ADR-10 | [Dependency Source Inference](10-dependency-source-inference.md) | Accepted |
| ADR-11 | [Sorbet Input Adapter](11-sorbet-input-adapter.md) | Accepted |
| ADR-12 | [dry-rb Packaging](12-dry-rb-packaging.md) | Accepted |
| ADR-13 | [TypeNode Resolver Plugin](13-typenode-resolver-plugin.md) | Accepted |
| ADR-14 | [RBS Sig Generation](14-rbs-sig-generation.md) | Accepted |
| ADR-15 | [Ractor Concurrency](15-ractor-concurrency.md) | Accepted (fork backend active; Ractor pool deferred) |
| ADR-16 | [Macro Expansion](16-macro-expansion.md) | Accepted |
| ADR-17 | [Monkey Patch Pre-Evaluation](17-monkey-patch-pre-evaluation.md) | Accepted (implemented in v0.1.13) |
| ADR-18 | [Substrate Per-Call-Site Return Type](18-substrate-per-call-site-return-type.md) | Accepted (implemented in v0.1.6) |
| ADR-19 | [Language Server Packaging](19-language-server-packaging.md) | Accepted |
| ADR-20 | [Lightweight HKT](20-lightweight-hkt.md) | Accepted (partial implementation) |
| ADR-21 | [Rubydex Evaluation](21-rubydex-evaluation.md) | Proposed |
| ADR-22 | [Baseline and Project Onboarding](22-baseline-and-project-onboarding.md) | Accepted |
| ADR-23 | [Diagnostic Triage Command](23-diagnostic-triage-command.md) | Accepted (slices 1+2+3+4 implemented) |
| ADR-24 | [Self Method Call Resolution](24-self-method-call-resolution.md) | Accepted (slice 4 gated) |
| ADR-25 | [Plugin Contributed RBS](25-plugin-contributed-rbs.md) | Accepted |
| ADR-26 | [ActiveRecord Relation Typing](26-activerecord-relation-typing.md) | Accepted |
| ADR-27 | [Tool Distribution and Installation Model](27-tool-distribution-model.md) | Accepted (partially implemented; CI template + single binary deferred) |
| ADR-28 | [Path-scoped Method-Protocol Contracts](28-path-scoped-protocol-contracts.md) | Accepted |
| ADR-29 | [Browser Playground](29-browser-playground.md) | Accepted (implemented in v0.1.10–0.1.11; cloud deploy + ruby.wasm deferred) |
| ADR-30 | [`rigor-ffi` Plugin Shape](30-rigor-ffi-plugin-shape.md) | Proposed (not implemented) |
| ADR-31 | [Contribution and Supply-chain Policy](31-contribution-and-supply-chain-policy.md) | Accepted (in force) |
| ADR-32 | [Inline-RBS Comment Ingestion](32-rbs-inline-comment-ingestion.md) | Accepted (implemented in v0.1.10) |
| ADR-33 | [MCP Server Packaging](33-mcp-server.md) | Accepted (implemented in v0.1.10) |
| ADR-34 | [Toplevel Unresolved Implicit-self Calls Warn by Default](34-toplevel-unresolved-self-call-default.md) | Accepted (implemented in v0.1.13; Playground severity wiring deferred) |
| ADR-35 | [Override Signature Compatibility (Liskov signature rule)](35-override-signature-compatibility.md) | Accepted (slices 1–4 done; slice 5 deferred) |
| ADR-36 | [Macro-substrate Nested-class Emission Tier (Mangrove `Enum`)](36-mangrove-enum-nested-class-emission.md) | Accepted (Slice A implemented; `is_a?` exhaustiveness deferred) |
| ADR-37 | [Plugin Interface Segregation (narrow extension protocols)](37-plugin-interface-segregation.md) | Accepted (Slices 1–3 implemented; all bundled walker plugins migrated) |
| ADR-38 | [Plugin-declared Additional Initializers](38-additional-initializers.md) | Accepted (def-form implemented; block-form deferred) |
| ADR-39 | [Plugins may invoke their target library's safe methods directly](39-plugin-target-library-invocation.md) | Accepted (Plugin::Inflector + 3 consumers migrated; slice 3 deferred) |
| ADR-40 | [`config_schema` declared defaults (`{kind:, default:}`)](40-config-schema-defaults.md) | Accepted (mechanism + 13 plugins migrated off the `DEFAULT_*` idiom) |
| ADR-41 | [Inference budget design (wiring, on-hit policy, measurement-gated defaults)](41-inference-budget-design.md) | Proposed (spec table unwired; Layer 1 doc hygiene + Layer 2 measurement-gated wiring queued) |
| ADR-42 | [Plugin-contributed binary-operator return types (coerce-direction)](42-plugin-binary-operator-return-types.md) | Proposed, low priority (self/left-operand case already works via `dynamic_return`, spec-confirmed; coerce direction is a narrow false positive — cheapest fix is the WD-D engine mitigation, precision via the ADR-20 HKT route; demand-gated) |
| ADR-43 | [RBS-complete ancestor resolution (allow-list inherited-method dispatch)](43-rbs-complete-ancestor-resolution.md) | Accepted — fully landed (WD1–WD6; `rigor check` resolves a Ruby subclass's inherited calls against an allow-listed RBS-complete ancestor (seed `Plugin::Base`) so contract misuse warns standalone, without Steep's own-helper FP wall; zero net FP on the plugin lib tree; blanket resolution rejected on Rails-controller FP grounds; `make check-plugins` gate in `verify` + CI, teeth verified) |
| ADR-44 | [Per-dispatch / per-narrow allocation churn (Scope, CallContext)](44-dispatch-allocation-churn.md) | Accepted — landed: collapsed the ~12-deep body-scope `with_*` chains into a single `Scope.new` (GC runs −29%, diagnostics byte-identical) + `owners_for` shared-empty + `CallContext` positional `new`; mutable pooled Scope/CallContext **rejected** (re-entrant dispatch → silent narrowing corruption → false positives); `ProjectScope` field-regrouping downgraded (object-shape benchmark: 3–24 ivars all allocate one object, so it cuts size not count) |
| ADR-45 | [Unchanged-project fast path (run-result cache)](45-unchanged-project-fast-path.md) | Accepted — landed. A pre-analysis whole-run fingerprint was **rejected as unsound** (plugins like Pundit read project files *during* analysis → stale hit, caught by the cross-process `pundit_plugin_spec` regression). The sound **record-and-validate** cache (`Cache::Store#fetch_or_validate` + `Descriptor#fresh?`): key on the inputs known up front, store the result with the dependency set the run actually read, re-digest it on the next run. Unchanged Mastodon `app/models` (248 files) 11.6 s → 1.8 s (~6×), diagnostics byte-identical; gate runs `--no-cache` |
| ADR-46 | [Incremental analysis via a cross-file dependency graph](46-incremental-dependency-graph.md) | Proposed — design. The per-file incremental successor to ADR-45's coarse whole-run cache: record, per file, what it read from other files (declarations, inferred-return bodies, plugin reads) through the `Scope` accessor choke point; invert into a `dependents` index; on an edit re-analyze only `ΔF ∪ dependents`, serving the rest from a per-file cache. A leaf `PostsController` edit → 1 file; a `Post` model edit → model + its ~dozen callers. Two tiers (declaration-structure fingerprint for body edits vs structural edits); soundness gated by a mandatory `--verify-incremental` byte-identical cross-check; conservative fallback to full re-analysis on any uncertainty |
| ADR-47 | [Narrowing-driven clause reachability (`flow.unreachable-clause`)](47-narrowing-driven-clause-reachability.md) | Accepted — WD1 + WD2 implemented (v0.1.17). Extends Rigor's two existing `if`/`unless` reachability rules (`flow.unreachable-branch` literal-only + `flow.always-truthy-condition` inferred-constant) to `case`/`when` clauses, inspired by Elixir v1.20's redundant-clause reporting. The flow engine already narrows `case` (`eval_case_when_branches` threads a `falsey_scope` across `when` branches via `Narrowing.case_when_scopes`); a clause is unreachable exactly when its computed `body_scope` narrows the subject to `bot` (per-clause disjointness) or its entry `falsey_scope` already carries a `bot` subject (prior-exhaustion). Reuses `always-truthy-condition`'s FP envelope (subject must narrow, skip loops/blocks, skip defensive shapes, never fire on `Dynamic[T]`); `in`/pattern clauses gated behind `InNode` exhaustiveness (ADR-36 neighbour); corpus FP gate before default-on |

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
