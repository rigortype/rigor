# ADR-24 slice 4 — `call.self-undefined-method` WD4 corpus FP evaluation

Date: 2026-06-14. Grounding: [ADR-24 § "Slice 4"](../adr/24-self-method-call-resolution.md),
[`docs/CURRENT_WORK.md`](../CURRENT_WORK.md) § (B) item 5.

## Purpose

`call.self-undefined-method` (ADR-24 slice 4) ships **`:off`** in every
profile, FP-clean on Rigor's own `lib`. Before flipping it on in any profile
the ADR requires a corpus false-positive gate. This is that evaluation:
enable the rule (`balanced` → `:warning`), sweep the `rigor-survey` corpus,
adjudicate every firing.

## Method

Flip the `balanced`-profile entry to `:warning` (file-swap, restored after),
run `rigor check` over ~26 `rigor-survey` targets, collect every
`call.self-undefined-method` diagnostic, bucket by `receiver_type`, read the
firing sites.

## Result — the rule is NOT promotable

**~454 firings across the corpus, essentially all false positives.** Two
buckets:

### Bucket 1 — `Object` / `BasicObject` receiver (287, dominant) — FIXED

A miss tagged with a **universal base** means the engine fell back to the root
self-type because it could not resolve the real class — a `class << self`
block, an FFI / `define_method` metaprogramming surface, a class-macro call
(`private` / `include` / `attr_accessor` / `define_method` themselves). Their
instance method set is never project-complete, so the miss is a resolution
gap, not a typo. Per target: protobuf 73, tdiary-core 199, pycall 10,
textbringer 3, herb 2.

**Fix landed:** `confidently_closed_self_class?` now excludes
`Object` / `BasicObject` / `Kernel` (`SELF_UNDEFINED_UNIVERSAL_BASES`). A pure
narrowing — it cannot remove a genuine firing on a real project class.
Verified protobuf 73 → 0 (whole-project before/after); clears the entire
`Object` column. Regression spec added (reopened `class Object` / `BasicObject`).

### Bucket 2 — non-`Object` receivers (167) — the promotion blocker

These fire on a *named* project class the gate considers "confidently closed"
(no superclass, no `include`/`prepend`, no `method_missing`), yet the call is
valid. The pattern that dominates is **abstract / template-method base
classes** — a base defines a method that *calls* a method its subclasses
implement, without itself declaring it:

- `Mail::CommonField#do_decode` / `#do_encode`, `Mail::Retriever#find` — the
  base calls the subclass hook (POP3 / IMAP / etc. implement `find`).
- `Concurrent::ThreadSafe::Util::Striped64#cells` / `#base` / `#cas_base` —
  primitives defined by a platform-specific subclass / mixin the gate cannot
  see.
- `Concurrent::…#java` — a JRuby-only method, correct on its platform.
- `Numo::NArray#…` (72) — a C-extension class; its method surface lives in C,
  invisible to a source-only "complete surface" claim.
- `RbNaCl::SimpleBox#nonce_bytes`, `Mail::PartsList#each` (Enumerable /
  delegation).

The rule's founding premise — *a standalone class with no superclass / mixin
has a complete, project-known method surface* — is **unsound for the abstract-
base pattern**, which is pervasive in real Ruby. A standalone class can still
legitimately call a method that a *subclass* (or a C extension, or a
platform-conditional reopen) supplies.

## Decision

- **Keep the rule `:off`.** The corpus gate is red: the abstract-base FP class
  is not addressable by the current per-class gate (it would need
  subclass-awareness — "is this class subclassed anywhere in the project, and
  is the missed method defined on a subclass?" — or an abstract-marker
  heuristic).
- **Land the universal-base exclusion** (Bucket 1) as a sound incremental
  accuracy win — the rule is opt-in usable today via `severity_overrides:`,
  and this removes ~63 % of its corpus false positives for those users.
- **Do not** widen the standalone-only gate to superclass / include chains
  (the other half of the slice-4 backlog) until the abstract-base FP is
  solved — widening would only enlarge Bucket 2.

## Follow-up (demand-gated)

Subclass-aware gating: record, at the recorder, whether the missed method is
defined on any known subclass of the class (the project class hierarchy is
already in the discovery index); suppress the firing when it is. That is the
shape a future promotion attempt needs; this eval is the evidence it is
required.
