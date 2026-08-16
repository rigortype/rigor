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
| ADR-17 | [Monkey Patch Pre-Evaluation](17-monkey-patch-pre-evaluation.md) | Accepted (slices 1-4 implemented; 5-6 open) |
| ADR-18 | [Substrate Per-Call-Site Return Type](18-substrate-per-call-site-return-type.md) | Accepted (implemented in v0.1.6) |
| ADR-19 | [Language Server Packaging](19-language-server-packaging.md) | Accepted (LSP v1 implemented in v0.1.6; v2 + follow-ups across v0.1.x) |
| ADR-20 | [Lightweight HKT](20-lightweight-hkt.md) | Accepted (partial implementation) |
| ADR-21 | [Rubydex Evaluation](21-rubydex-evaluation.md) | Proposed |
| ADR-22 | [Baseline and Project Onboarding](22-baseline-and-project-onboarding.md) | Accepted |
| ADR-23 | [Diagnostic Triage Command](23-diagnostic-triage-command.md) | Accepted (slices 1+2+3+4 implemented) |
| ADR-24 | [Self Method Call Resolution](24-self-method-call-resolution.md) | Accepted (slice 4 gated; WD3 in-body adoption gate opened by ADR-57, 2026-06-12) |
| ADR-25 | [Plugin Contributed RBS](25-plugin-contributed-rbs.md) | Accepted |
| ADR-26 | [ActiveRecord Relation Typing](26-activerecord-relation-typing.md) | Accepted |
| ADR-27 | [Tool Distribution and Installation Model](27-tool-distribution-model.md) | Accepted (partially implemented; Nix flake, container image, and CI templates shipped; single binary deferred) |
| ADR-28 | [Path-scoped Method-Protocol Contracts](28-path-scoped-protocol-contracts.md) | Accepted |
| ADR-29 | [Browser Playground](29-browser-playground.md) | Accepted (server-side playground v0.1.10–0.1.11; in-browser ruby.wasm build shipped 2026-06-14/15) |
| ADR-30 | [`rigor-ffi` Plugin Shape](30-rigor-ffi-plugin-shape.md) | Proposed (not implemented) |
| ADR-31 | [Contribution and Supply-chain Policy](31-contribution-and-supply-chain-policy.md) | Accepted (in force) |
| ADR-32 | [Inline-RBS Comment Ingestion](32-rbs-inline-comment-ingestion.md) | Accepted (WD11/WD12 keep the rbs-inline gem as the reader, 2026-07-30) |
| ADR-33 | [MCP Server Packaging](33-mcp-server.md) | Accepted (implemented in v0.1.10) |
| ADR-34 | [Toplevel Unresolved Implicit-self Calls Warn by Default](34-toplevel-unresolved-self-call-default.md) | Accepted (implemented in v0.1.13; the ADR-29 Playground default-severity wiring shipped too — its sandbox config sets `severity_profile: strict`) |
| ADR-35 | [Override Signature Compatibility (Liskov signature rule)](35-override-signature-compatibility.md) | Accepted (slices 1–4 done; slice 5 deferred) |
| ADR-36 | [Macro-substrate Nested-class Emission Tier (Mangrove `Enum`)](36-mangrove-enum-nested-class-emission.md) | Accepted (Slice A implemented; `is_a?` exhaustiveness deferred) |
| ADR-37 | [Plugin Interface Segregation (narrow extension protocols)](37-plugin-interface-segregation.md) | Accepted (Slices 1–3 implemented; all bundled walker plugins migrated; `flow_contribution_for` deleted 2026-06-11 per ADR-52 WD3) |
| ADR-38 | [Plugin-declared Additional Initializers](38-additional-initializers.md) | Accepted (def-form implemented; block-form deferred) |
| ADR-39 | [Plugins may invoke their target library's safe methods directly](39-plugin-target-library-invocation.md) | Accepted (Plugin::Inflector + 3 consumers migrated; slice 3 deferred) |
| ADR-40 | [`config_schema` declared defaults (`{kind:, default:}`)](40-config-schema-defaults.md) | Accepted (mechanism + 13 plugins migrated off the `DEFAULT_*` idiom) |
| ADR-41 | [Inference budget design (wiring, on-hit policy, measurement-gated defaults)](41-inference-budget-design.md) | Proposed (spec table unwired; Layer 1 doc hygiene + Layer 2 measurement-gated wiring queued) |
| ADR-42 | [Plugin-contributed binary-operator return types (coerce-direction)](42-plugin-binary-operator-return-types.md) | Proposed (low priority, demand-gated; self/left-operand case already works via dynamic_return) |
| ADR-43 | [RBS-complete ancestor resolution (allow-list inherited-method dispatch)](43-rbs-complete-ancestor-resolution.md) | Accepted (fully landed, WD1–WD6; make check-plugins gate wired into verify + CI) |
| ADR-44 | [Per-dispatch / per-narrow allocation churn (Scope, CallContext)](44-dispatch-allocation-churn.md) | Accepted (body-scope collapse + allocation hygiene landed; mutable pooling rejected; field-regrouping downgraded) |
| ADR-45 | [Unchanged-project fast path (run-result cache)](45-unchanged-project-fast-path.md) | Accepted (record-and-validate run cache landed; naive pre-analysis fingerprint rejected as unsound) |
| ADR-46 | [Incremental analysis via a cross-file dependency graph](46-incremental-dependency-graph.md) | Accepted (slices 1–4 landed incl. file add/remove; --incremental gated by --verify-incremental in CI) |
| ADR-47 | [Narrowing-driven clause reachability (`flow.unreachable-clause`)](47-narrowing-driven-clause-reachability.md) | Accepted (WD1–WD3a landed, v0.1.17; WD4 16-corpus sweep zero-firing; WD3b deferred) |
| ADR-48 | [Struct / Data value folding (member-shape carriers)](48-data-struct-value-folding.md) | Accepted (Data.define slices 1–4 landed v0.1.17; Struct slices 1–3 landed, slice 4 deferred) |
| ADR-49 | [ADR authoring guidelines (a rubric for necessary-and-sufficient ADRs)](49-adr-authoring-guidelines.md) | Accepted (in force; living rubric) |
| ADR-50 | [Release engineering and stability strategy (v0.2.0 → v1.0.0)](50-release-engineering-and-stability-strategy.md) | Proposed (v0.2.0 release-engineering trial; v1.0.0 hard contract freeze) |
| ADR-51 | [CI-native diagnostic output formats](51-ci-diagnostic-output-formats.md) | Accepted (partially implemented in v0.1.18) |
| ADR-52 | [Compiled plugin contribution dispatch](52-compiled-plugin-contribution-dispatch.md) | Accepted (slices 1-6 implemented; full WD surface complete, remaining work demand-driven) |
| ADR-53 | [Scope discovery-index separation + check-rule walk consolidation](53-scope-discovery-index-separation.md) | Accepted (Track A and Track B both complete) |
| ADR-54 | [Cache slimming: definitions-blob retirement, payload compression, default eviction](54-cache-slimming.md) | Accepted (WD1-WD4 implemented; cache footprint ~33.7MB to ~2MB per project) |
| ADR-55 | [Recursive-method return-type precision](55-recursive-return-precision.md) | Accepted (slice 1 and slice 2 both implemented) |
| ADR-56 | [Block-captured local write-back and loop-body fixpoint](56-block-captured-local-mutation.md) | Accepted (slices A and B implemented 2026-06-11; slice C implemented 2026-06-12) |
| ADR-57 | [Opening the implicit-self call return-adoption gate](57-self-call-return-adoption.md) | Accepted (gate opened 2026-06-12; WD3 module-singleton seed fix landed 2026-07-10) |
| ADR-58 | [Instance-variable field typing](58-ivar-field-typing.md) | Accepted (WD1 partial, WD1b queued; WD2 already-realized; WD3/WD5 implemented; `||=` seed deferred) |
| ADR-59 | [Spec assertions are not implementation signatures](59-spec-assertions-are-not-signatures.md) | Accepted (strong form rejected; three weak forms recorded, demand-gated) |
| ADR-60 | [Pre-freeze plugin contract consolidation](60-pre-freeze-plugin-contract-consolidation.md) | Accepted (2026-06-13) |
| ADR-61 | [Agent-friendly diagnostic statistics (structured selector axis)](61-agent-friendly-diagnostic-statistics.md) | Accepted (implemented 2026-06-13; precision-additive) |
| ADR-62 | [Mutation-testing the analyzer (false-negative / teeth measurement)](62-mutation-testing-teeth-measurement.md) | Accepted (harness + first fixes landed 2026-06-13; remaining backlog demand-gated) |
| ADR-63 | [User-facing type-protection coverage](63-type-protection-coverage.md) | Accepted (Tier 1 and Tier 2 both implemented 2026-06-14) |
| ADR-64 | [Non-nil argument-type-mismatch and the coerce barrier](64-non-nil-argument-type-mismatch.md) | Accepted (non-nil channel built and gated for multi-overload methods) |
| ADR-65 | [Diagnostic evidence tier and documentation URL](65-diagnostic-evidence-tier-and-doc-url.md) | Accepted (implemented 2026-06-15; precision-additive) |
| ADR-66 | [Discriminated-union member typing (tag-keyed narrowing)](66-discriminated-union-member-typing.md) | Proposed (not implemented; demand-gated) |
| ADR-67 | [Parameter type inference (the M3 frontier)](67-parameter-type-inference.md) | Accepted (WD6 landed opt-in; default-on declined 2026-07-30; WD6c incremental exclusion lifted; WD2 deferred) |
| ADR-68 | [Plugin-declarable class-builder folding](68-class-builder-folding.md) | Proposed (demand-gated) |
| ADR-69 | [Pluggable mutation substrate (kill-oracle + operator seam)](69-pluggable-mutation-substrate.md) | Accepted (both seams implemented 2026-06-17) |
| ADR-70 | [Fused static∪dynamic protection coverage](70-fused-protection-coverage.md) | Accepted (implemented 2026-06-17; co-landed with ADR-69 Seam 1) |
| ADR-71 | [Type-guided external incremental mutation testing](71-type-guided-external-mutation-testing.md) | Proposed (deferred / demand-gated; nothing implemented) |
| ADR-72 | [Gemfile.lock-gated bundled RBS overlays](72-gemfile-lock-gated-rbs-overlays.md) | Accepted (implemented 2026-06-17) |
| ADR-73 | [SKILL-driven Rigor user experience](73-skill-driven-user-experience.md) | Accepted (WD1–WD5 landed 2026-06-20; flag grammar amended 2026-06-21; thin-shell/live-core split + `rigor skill --full` added 2026-07-05) |
| ADR-74 | [Offline doc access (`rigor docs`) + `llms.txt` linkage](74-offline-doc-access-and-llms-txt.md) | Accepted (WD1–WD4 implemented 2026-06-20) |
| ADR-75 | [`Dynamic[T]` provenance and explanation](75-dynamic-provenance.md) | Accepted (implemented 2026-06-24, `01e291cb`) |
| ADR-76 | [Effect modeling for `freeze` / `dup` / `clone` and shape-carrier preservation](76-effect-modeling-freeze-dup-shape-preservation.md) | Accepted (WD1 landed 2026-06-24; WD2 landed 2026-06-26 once ADR-78 unblocked it) |
| ADR-77 | [`rigor doctor` and `rigor upgrade` evidence-routing commands](77-doctor-and-upgrade-commands.md) | Accepted (implemented 2026-06-24; `upgrade` is a skeleton) |
| ADR-78 | [Reflexive over-fold and the `flow.always-truthy-condition` envelope](78-reflexive-overfold-always-truthy.md) | Accepted (fully implemented 2026-06-26) |
| ADR-79 | [RBS version-range fidelity over checker-pinned determinism](79-rbs-version-range-over-pinned-determinism.md) | Accepted (2026-06-26) |
| ADR-80 | [Rename the `type_specifier` plugin hook to `narrowing_facts`](80-narrowing-facts-rename.md) | Accepted (completed in 0.3.0; `type_specifier` renamed to `narrowing_facts`) |
| ADR-81 | [Skill-set optimization: per-skill freshness + the `waza` evaluation stance](81-skill-set-optimization.md) | Accepted (implemented 2026-07-05) |
| ADR-82 | [`Dynamic[T]` provenance wiring: breaking the catch-all on real apps](82-dynamic-provenance-wiring.md) | Accepted (WD1-3,6-9 implemented 2026-07-06/07-11; WD4 deferred; causeless 49%→26%) |
| ADR-83 | [Dynamic-origin algebra: keep union arms over absorbing into `Dynamic`](83-dynamic-origin-algebra.md) | Accepted (supersedes the value-lattice.md join algebra; spec revised to match engine behavior) |
| ADR-84 | [Cross-file return-memo scoping and the taint-precise store gate](84-cross-file-return-memo-scoping.md) | Accepted (WD1 landed in PR #79; WD2-WD3 implemented; mail body evals 3355→557) |
| ADR-85 | [Per-file seed bundles and lazy def-node handles (pre-pass incrementalization)](85-seed-bundles-and-lazy-def-node-handles.md) | Accepted (WD1 in PR #81; WD2-WD3 in PR #82; gitlab warm-incremental allocs 16.7M→2.06M) |
| ADR-86 | [Partial native extensions for residual hot paths (rejected; rigor-rs owns native speed)](86-partial-native-extensions.md) | Accepted (standing rejection of native extensions; rigor-rs owns native speed; WD4 candidate staged) |
| ADR-87 | [The null-build floor: stat-then-digest validation, zero-change snapshot skip, hit-path boot slimming](87-null-build-floor.md) | Accepted (WD1-WD5 implemented, PR #85; supersedes ADR-54's rejected mtime fast-path) |
| ADR-88 | [Incremental plugin-fact soundness](88-incremental-plugin-fact-soundness.md) | Accepted (WD1-WD4 implemented, PR #89; WD5 deferred) |
| ADR-89 | [Semantic propagation gates: declaration-shape and observed-key return summaries](89-semantic-propagation-gates.md) | Accepted (WD1 declaration-shape gate + WD2 return-summary gate implemented, PR #90; gitlab 341→1) |
| ADR-90 | [Target-library resolution from the analyzed project's bundle](90-target-library-resolution-from-project-bundle.md) | Accepted (implemented 2026-07-16; WD1-WD3 landed) |
| ADR-91 | [Kernel intrinsic fold ownership gate + spelling-parity invariant](91-kernel-intrinsic-fold-ownership-gate.md) | Accepted (implemented 2026-07-16, WD1-WD4; corpus gate byte-identical) |
| ADR-92 | [Normative status fidelity: the founding-era stratum and the declare-or-mark gate](92-normative-status-fidelity.md) | Accepted (implemented 2026-07-16 WD1-WD5, 2026-07-25 WD6; void verdict resolved to option b) |
| ADR-93 | [Default rbs-inline ingestion: reconciling ADR-32's opt-in with the always-parse spec](93-default-rbs-inline-ingestion.md) | Accepted (WD5 engine-anchored bundled-plugin resolution added 2026-07-19, slice queued) |
| ADR-94 | [The inline-RBS reader: `RBS::InlineParser` and the rbs 3.x floor](94-rbs-inline-reader-and-the-rbs-3x-floor.md) | Accepted (migration deferred; rigor-rbs-inline stays the reader) |
| ADR-95 | [Homebrew distribution: deferred behind the single binary](95-homebrew-tap-deferral.md) | Proposed (deferred, trigger-gated; nothing implemented) |
| ADR-96 | [Plugin target-gem declaration, the plugin-gap advisory, and presence-gated umbrella expansion](96-plugin-target-gems.md) | Accepted (WD1-WD2 committed; WD3 umbrella expansion proposed) |
| ADR-97 | [Index entries are not summaries: the ADR-index budgets and their gate](97-adr-index-budgets.md) | Accepted (implemented 2026-07-17; both ADR indexes compressed to their declared contract and gated by spec/docs/agent_index_spec.rb) |
| ADR-98 | [Development-flow document roles: handoff, issues, changelog](98-development-flow-document-roles.md) | Accepted (implemented 2026-07-17; backlog migrated to GitHub Issues, ROADMAP.md dissolved, handoff capped and gated) |
| ADR-99 | [The config schema is a source of truth: `.rigor.yml` tiers and the reserve pipeline](99-config-schema-authority.md) | Accepted (implemented 2026-07-17; schema named a source of truth, `rigor_rs:` reserved, nested + reserved + URL gates added) |
| ADR-100 | [The `static.*` diagnostic family shape and the `void_origins` side-table](100-static-diagnostic-family-and-void-origins.md) | Accepted (direct slice shipped; WD4 transitive design added 2026-07-19, slice queued; budget ids deferred) |
| ADR-101 | [The branch elision may not rest on an optimistically nil-free carrier](101-optimistic-carrier-branch-elision.md) | Accepted (implemented 2026-08-06; 47 of 2,060 corpus verdicts affected, diagnostics byte-identical both directions) |
| ADR-102 | [The unused-code reachability report is a report, not a diagnostic](102-unused-code-reachability-report.md) | Proposed (decisions for the `rigor unused` slices; all eight working decisions settled) |
| ADR-103 | [Effect labels: an opt-in, snapshot-first effect system](103-effect-labels.md) | Proposed (design note landed 2026-08-16; nothing implemented; four items open at Proposed) |

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
