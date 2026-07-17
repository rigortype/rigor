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

### Bucket 2 — non-`Object` receivers (167) — partially addressed

These fire on a *named* project class the gate considers "confidently closed"
(no superclass, no `include`/`prepend`, no `method_missing`), yet the call is
valid. The eval found several distinct sub-classes; two are now fixed, the
rest remain.

**Fixed — abstract / template-method base classes.** A base defines a method
that *calls* a method its subclasses implement, without itself declaring it:
`Mail::CommonField#decoded` calls `do_decode` (every `< CommonField` subclass
defines it); `Mail::Retriever#find` is implemented by POP3 / IMAP.
**Subclass-aware gating** now suppresses a miss when the missed method is
defined (a plain `def` via the def-node table, or a dynamic definition) on any
known subclass of the self-class — walking the `discovered_superclasses`
child→parent map inverted, resolving each recorded (unqualified) parent name in
the child's namespace. A genuine typo no subclass defines still fires.

**Fixed — dynamic (non-constant) superclass.** `Mail::PartsList <
DelegateClass(Array)` (and `< Struct.new(...)` / `< Data.define(...)`)
inherits a dynamically produced surface; the recorder never records a
non-constant superclass, so the gate wrongly treated the class as standalone.
The `SelfClosednessScanner` now marks a class with a non-constant superclass
open.

Per-target effect of the two fixes: mail 12 → 0, faraday 5 → 2.

**Remaining (still false positives, rule stays off).** Sub-classes the
per-class gate still cannot see:
- `Numo::NArray#…` (72) — a **C-extension** class; its method surface lives in
  C, invisible to a source-only "complete surface" claim.
- `Concurrent::ThreadSafe::Util::Striped64#cells` / … (20) — metaprogrammed /
  platform-specific primitives; `Concurrent::…#java` (5) — a JRuby-only method.
- `TDiary::Application` / `TDiary::Style::*` (31), `RbNaCl::SimpleBox` (8),
  `Textbringer::*` (7) — metaprogramming / project-specific surfaces.

## Decision

- **Keep the rule `:off`.** The corpus gate is still red on the remaining
  Bucket-2 sub-classes (dominated by C-extension and metaprogrammed surfaces),
  which the per-class source scan fundamentally cannot enumerate.
- **Landed the universal-base exclusion** (Bucket 1, 287) **+ subclass-aware
  gating + the dynamic-superclass guard** (Bucket 2 abstract-base / delegate-
  class, ~15) — all pure narrowings, sound incremental accuracy wins for the
  opt-in users the rule is usable by today (`severity_overrides:`).
- **Do not** widen the standalone-only gate to superclass / include chains
  (the other half of the slice-4 backlog) — the C-ext / metaprogramming FP
  classes would only grow.

## Follow-up

Subclass-aware gating — recorded here as the required shape — **landed in this
same commit** (`01491c63`); see "Fixed — abstract / template-method base
classes" above. It is implemented read-side in `CheckRules`
(`method_defined_on_known_subclass?`) against the project-global discovery index
rather than literally "at the recorder", which is functionally equivalent and
cross-file correct. Nothing here remains open: the rule stays `:off` because of
the C-extension / metaprogrammed **Remaining** class, which a source-only scan
cannot enumerate — not for want of subclass-aware gating.
