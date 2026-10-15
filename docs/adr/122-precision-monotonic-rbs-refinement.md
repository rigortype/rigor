# ADR-122 — Precision-monotonic RBS refinement and layout-stable code emission

Status: **Proposed, 2026-10-12.** Addresses #1487, #1488, and #1489. Establishes the precision-monotonicity and layout-stable contracts for Rigor's signature generation and existing-RBS refinement (`rigor sig-refine`).

Grounding: the Alba dogfooding pilot in [`docs/notes/20261012-alba-onboarding-rbs-inline-pilot.md`](../notes/20261012-alba-onboarding-rbs-inline-pilot.md); the open defects #1487 (tighter-return candidates widening existing precise parameters to `untyped`), #1488 (`DuplicatedMethodDefinitionError` on reopened modules), and #1489 (singleton method parameter types inferred from literal call arguments); and the Steep mutable instance variable narrowing boundary.

## Context

Rigor's signature generation (`rigor sig-gen`, introduced in [ADR-14](14-rbs-sig-generation.md)) was originally conceived as a bootstrap tool for untyped Ruby repositories: reading an unannotated codebase, performing type inference, and writing initial `.rbs` files into `sig/`.

However, the real-world adoption journey of mature Ruby projects (demonstrated in the Alba onboarding pilot) follows a fundamentally different lifecycle:
1. **Existing Annotations:** Projects rarely begin with zero signatures. They already maintain hand-crafted `sig/**/*.rbs` files or embedded `rbs-inline` annotations.
2. **The "Untyped Reduction" Need:** The primary user requirement is not generating wholesale boilerplate from scratch, but surgically tightening residual `untyped` positions in existing declarations without regressing human-specified precision or breaking downstream type checkers (such as Steep).
3. **The Current `sig-gen` Failures on Existing Projects:**
   - **Parameter Widening (#1487):** When `sig-gen` identifies a `tighter_return` candidate, its candidate emitter constructs a fresh `RBS::AST::Declarations` object from the Ruby AST where unannotated parameters default to `untyped`. Consequently, tightening a return type destructively downgrades existing, precise parameter types (e.g. `(Symbol | Proc) -> untyped` becomes `(untyped) -> bool`).
   - **Module Reopening Duplication (#1488):** `LayoutIndex` maps class/module names to RBS file paths at the class declaration level (`Alba -> sig/alba.rbs`). When secondary files reopen a top-level module (e.g., `lib/alba/association.rb` reopening `module Alba`), `CandidateClassifier` generates definitions targeting `sig/alba/association.rbs`. This emits duplicate method definitions for methods already declared in `sig/alba.rbs`, crashing `rbs build` and `steep check` with `RBS::DuplicatedMethodDefinitionError`.
   - **Literal Over-Specialization (#1489):** Parameter observation mode (`--params=observed`) captures runtime call arguments or single-site literals. Instead of generalizing primitive literals to `String`, `Integer`, or `Symbol`, it infers literal singleton types (e.g., `"foo"`, `1`), resulting in fragile signatures that reject valid calls.
   - **Setter Return & AST Artifact Pollutions:** In Ruby AST, setters (`name=`) evaluate to their assigned value or helper calls (e.g. `reset_transform_keys`). `sig-gen` infers these arbitrary intermediate return types, violating RBS setter invariants (`(T) -> void` or `(T) -> T`) and generating `Ruby::SetterBodyTypeMismatch` diagnostics. Similarly, trailing assignments (`@ivar = val`) and loop iterations (`.each`) pollute return inference when the method's semantic intent is `void` or `self`.
   - **The Steep Mutable Instance Variable Barrier:** In Steep, mutable instance variables (`@ivar`) do not narrow across control-flow branches without local variable rebinding (`v = @ivar`). When generator tooling infers and emits strict union types for internal ivars (`@check: Proc | false`), Steep reports `NoMethod` false positives on every branch. External method interfaces must be strictly typed, while internal mutable ivars checked via branching must retain wide/`untyped` bounds unless locally rebound.

## Decision

Establish a **precision-monotonic, layout-stable signature refinement model** and introduce `rigor sig-refine` (and `--mode=refine` in `rigor sig-gen`) as the dedicated workflow for upgrading existing RBS declarations.

The design is governed by three primary criteria:
1. **Precision Monotonicity:** A refinement must only tighten or preserve existing types; it must never replace a known static type with `untyped`.
2. **Layout Invariance:** A method already declared in a project's RBS files has an immutable canonical home; refinement never creates duplicate declarations across files.
3. **Downstream Checker Viability:** Signatures produced by Rigor must check cleanly in both Rigor and Steep without introducing synthetic type-narrowing barriers.

### Working Decisions

#### WD1 — Precision Monotonicity Invariant (Lattice Subtype Invariant)
When refining an existing signature $S_{old} = (P_1, \dots, P_n) \to R_{old}$ into candidate $S_{new} = (P'_1, \dots, P'_n) \to R_{new}$:
1. **Parameter Preservation:** For `tighter_return` and existing-method candidates, parameter types must be preserved verbatim from $S_{old}$ unless explicitly targeted by a parameter inference pass. Specifically, `Writer#emit_signature` must not re-synthesize parameters from unannotated AST nodes.
2. **No Untyped Degradation:** $P'_i$ may not be `untyped` if $P_i \neq \text{untyped}$. $R_{new}$ may not be `untyped` if $R_{old} \neq \text{untyped}$.
3. **Return Subtyping:** $R_{new} <: R_{old}$ in Rigor's type lattice.
4. **Primitive Literal Generalization (#1489):** Observed literals (`String`, `Integer`, `Float`, `Symbol`) must be generalized to their primitive class types (`String`, `Integer`, `Float`, `Symbol`) rather than literal types, unless the position is explicitly typed as an enum union (`:json | :yaml`) or literal flag.

#### WD2 — Method-Level Layout and Provenance Indexing (#1488)
1. `LayoutIndex` is upgraded from class-level (`class_name -> file_path`) to member-level: `(class_name, method_name, kind) -> canonical_rbs_path`, where `kind` is `:singleton` or `:instance`.
2. **Canonical Home Rule:** If a method is already defined in any existing project RBS file (`sig/**/*.rbs`), that file is its exclusive canonical target. Any candidate targeting that member must be written as an in-place edit to that file, never emitted into a new file derived from the Ruby source filename.
3. **Reopened Module Default:** When a Ruby file reopens an existing namespace to add new methods not present in `sig/`, the canonical target defaults to the primary namespace file (e.g. `sig/alba.rbs` for `Alba`), rather than synthesizing a sibling file, unless configured otherwise.

#### WD3 — Semantic Return Filtering & Setter Invariants
1. **Setter Contract:** Methods matching `/=\z/` (e.g. `attribute=`) are classified under setter semantics: their return type is normalized to `void` (or the parameter type `T`), ignoring intermediate return values of trailing cleanup or helper calls (`reset_transform_keys`).
2. **Side-Effect Trailing Artifacts:** Trailing expressions consisting solely of ivar assignment (`@ivar = val`) or side-effecting iterations (`.each { ... }`) where the method is otherwise a command must not blindly infer the trailing RHS type if the structural contract indicates `void` or `self`.

#### WD4 — Instance Variable vs Method Boundary Partitioning (Steep Ivar Barrier)
1. **Boundary Segregation:** Method parameters and method returns constitute the external contract and must be typed with maximum static precision.
2. **Internal Ivar Pragmatism:** Mutable instance variables that participate in internal runtime polymorphism (`case @resource; when Class ... when Proc ...`) must not be aggressively typed to narrow unions if the project targets Steep, because Steep lacks cross-branch ivar narrowing.
3. Default policy: preserve `untyped` or wide bounds on internally branched ivars unless `--strict-ivars` is explicitly enabled or the ivars are proven to be initialized once and never dynamically reassigned.

#### WD5 — Scope-Aware Type Alias Folding & Interface Extraction
1. When generating or refining signatures across a class/module namespace, repeated multi-member union types (such as `Symbol | Proc | String | ...`) must be recognized and folded into project-level type aliases (e.g. `type serializable_hash_type = ...`).
2. Preserves and prefers existing type aliases discovered in the project's `sig/` environment over repeating inlined raw union types.

#### WD6 — `rigor sig-refine` CLI Surface & Workflow
1. Introduce a dedicated workflow command:
   ```sh
   rigor sig-refine [paths...] [options]
   ```
   (and `--mode=refine` flag under `rigor sig-gen`).
2. Modes:
   - `--check`: Analyzes existing RBS signatures against Rigor's type inference. Exits non-zero if candidates exist that can tighten `untyped` positions without violating WD1–WD5.
   - `--diff`: Prints a colorized unified diff showing proposed precision refinements.
   - `--write`: Surgically applies the refinements directly to the existing RBS files in place.
3. Metrics: Reports the exact count of tightened `untyped` positions, preserved signatures, and rejected regressions.

## Rejected and Deferred Alternatives

| Alternative | Reason |
| --- | --- |
| Rely solely on `sig-gen --overwrite` | Overwrites hand-authored comments, type aliases, and precise parameter types with unannotated AST defaults (#1487). |
| Heuristic AST-only parameter inference | Cannot know runtime caller constraints; leads to either over-specialized literal types (#1489) or false-positive parameter rejections. |
| Automatic type generation of narrow unions for all ivars | Directly breaks Steep downstream due to the mutable ivar narrowing barrier; produces dozens of false positives on valid Ruby code. |
| File-name 1:1 mapping for reopened modules | Emits duplicate method definitions across multiple `.rbs` files, crashing `rbs build` with `DuplicatedMethodDefinitionError` (#1488). |
| Requiring inline type annotations (`@type`, `@rbs`) in Ruby code | Violates Rigor's core design boundary: Ruby application code does not require Rigor-specific annotations or DSLs. |

## Consequences

- **Positive**
  - Existing projects with established RBS or `rbs-inline` signatures can safely adopt Rigor to eliminate `untyped` debt monotonically.
  - Zero risk of regressing existing parameter types when tightening return types (#1487 resolved).
  - Eliminates `DuplicatedMethodDefinitionError` on codebases with reopened modules (#1488 resolved).
  - Generated and refined signatures check cleanly in both Rigor and Steep.
- **Negative, accepted**
  - Requires maintaining a two-dimensional member layout index `[class, method, kind]` in addition to file-level indices.
  - Candidate generation for `sig-refine` is slightly more computationally involved than naive AST emission because it must parse and diff against the existing RBS AST.

## Relationship to other ADRs

- [ADR-1](1-types.md): The type model and RBS superset strategy.
- [ADR-14](14-rbs-sig-generation.md): The original `sig-gen` pipeline architecture. ADR-122 extends and refines its candidate classification, layout indexing, and writing phases.
- [ADR-32](32-rbs-inline-comment-ingestion.md) & [ADR-93](93-default-rbs-inline-ingestion.md): Inline RBS comment ingestion and interaction with `sig/` overlays.
- [ADR-35](35-override-signature-compatibility.md): Liskov signature compatibility checking used to validate candidate subtyping.
- [ADR-58](58-ivar-field-typing.md): Instance variable typing semantics and interaction with Steep's ivar flow barrier (WD4).
- [ADR-108](108-type-provenance-for-agents.md): Type provenance and agent-driven signature maintenance.
