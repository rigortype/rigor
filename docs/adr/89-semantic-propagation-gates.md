# ADR-89 — Semantic propagation gates: declaration-shape and observed-key return summaries

Status: **Accepted — WD1 (declaration-shape gate for ancestry / file-level dependents) + WD2 (observed-key
return-summary gate for symbol dependents) implemented ([PR #90](https://github.com/rigortype/rigor/pull/90)).**
Extends PR #88's B1 comment-only gate to BODY edits: a dependent is re-analyzed only when something it can
consume actually changed. Sound only on top of ADR-88 — the plugin-fact value fingerprints are what make
"the plugin-visible surface is unchanged" a checkable premise.

Grounding: [`20260714-edit-shape-recon.md`](../notes/20260714-edit-shape-recon.md) (closure shapes; the S5a
class-method edit → 341-file ancestry closure; `diags_changed = 0` across every comment shape) +
[ADR-88](88-incremental-plugin-fact-soundness.md).

## Context

After #87 / #88 / ADR-88: comment-only edits collapse (B1 code fingerprint); symbol-edge dependents
re-check only on changed per-method source fingerprints; plugin facts invalidate the snapshot by value. The
remaining over-propagation is BODY edits:

- **(a)** any body edit re-analyzes ALL ancestry / file-level dependents. The recon's S5a — a 13-caller
  `def self.safe_find_or_create_by` body edit — re-analyzed 341 files. They consume only the class's
  *declaration shape*, which a body edit does not change.
- **(b)** a body edit whose inferred return types are unchanged at every previously-observed call shape
  still re-analyzes all its callers.

## Decision (criterion)

A dependent D of an edited file F is re-analyzed iff the intersection of (what D can consume from F) × (what
actually changed) is non-empty, where "what changed" is proven by comparing PERSISTED summaries, each
covering a complete consumable surface:

1. **Declaration surface** (ancestry / file-level consumers): the ADR-85 seed bundle with per-def CODE
   fingerprints replaced by per-def SIGNATURE shape — name, kind (instance / singleton), full parameter
   structure (kinds / names / defaults-presence), visibility, ancestry (superclass / include), member
   layouts, method existence, AND def start LINE. A body edit leaves it equal; an arity / visibility /
   added-or-removed-method / ancestry edit does not.
2. **Behavioral surface** (symbol consumers): per-def observed-key return summaries — the ADR-84 memo's
   `(receiver-descriptor, arg-descriptors) → return-descriptor` entries for F's defs, persisted in the
   snapshot — PLUS the effects channel (the content-mutation parameter sets of ADR-56 / `af3efef3`, a per-def
   static property callers consume for arg flooring).

Premise for BOTH: the ADR-88 plugin-fact fingerprints matched (else full re-analysis already). Skips compose
with recording — a skipped dependent's edges / caches carry over unchanged in the snapshot.

## Working decisions

### WD1 — declaration-shape gate

On recheck, for each changed file compute its {ScopeIndexer.declaration_signature} (a SHA-256 over the
declaration surface above, read from a single-file live index — parameter structure straight from the def
node, deliberately syntactic, not typed). If it equals the snapshot's stored signature (built from the same
live index at cache time, on the seed bundle, `IncrementalSnapshot::SCHEMA` 9→10), the file is
declaration-STABLE and drops out of the `unstable` set — its ancestry / file-level dependents are skipped
(symbol dependents stay governed by fingerprints / WD2). This **generalises B1**: code-stable ⟹
declaration-stable, so the gate switched from B1's comment-stripped code fingerprint to the declaration
signature (a superset of B1's skip set, still sound), keeping B1's comment-ingesting-plugin off-switch.

The closure machinery already routed this correctly: `affected_with_symbols(unstable, changed_pairs, …)`
adds a declaration-stable file's ancestry dependents only when the file is in `unstable`, so removing it
there is the whole change; its changed symbol pairs still contribute their symbol dependents.

**Def-site LINE SHIFTS — divergence from the draft (soundness-driven).** The draft proposed that a
line-shifted def re-check only its site-consuming dependent (via the ADR-88 WD3 `user_def_site_for` edge)
while others skip. The realized signature instead **includes each def's start line**, so a line-shifting body
edit moves the signature → the file is declaration-UNSTABLE → its ancestry / file-level dependents (including
the `call.undefined-method` consumer that embeds `project_definition_site`) all re-check. This is required
for soundness: the ADR-88 WD3 symbol fingerprint is line-INVARIANT (the def's source slice text is
unchanged), so it does NOT flag a shifted-but-otherwise-unchanged def, and only the file-level edge covers
the ADR-17 site consumer — the same conservative behaviour B1 has on a line shift. So a line-shift edit keeps
the full dependent set (sound, coarse); only a **same-line** body edit collapses (a local rename, an internal
literal). The finer per-site precision is deferred. The `--verify-incremental` line-shift spec (ADR-88 WD3)
stays green through THIS gate, and the WD4 line-shift case asserts the site consumer re-checks.

### WD2 — observed-key return-summary gate

Persist per-file observed keys, bounded: `RETURN_SUMMARY_KEYS_PER_DEF` (8) keys per def,
`RETURN_SUMMARY_TOTAL_CAP` (4000) defs, `describe(:short)` return descriptors + the effects set. They are
harvested after each run from the ADR-84 return memo — `MemoEntry` gained the call descriptor (`receiver` +
`arg_types`) so a summary carries the actual observed key types (`ExpressionTyper.harvest_return_memo` +
`Runner#return_summaries`, mapping each memo entry to its `(path, "Class#method"|"Class.method")` through the
discovery index). Un-Marshal-able keys are dropped at snapshot-save time so a cache write never fails.

On recheck, for each changed def that still exists with an unchanged signature shape and carries a persisted
summary, the session re-evaluates its return at each old key (`Scope#user_method_return` → the ADR-84 memo,
final values only) through a session-side runner probe (`Runner#evaluate_return_types` — builds the discovery
+ env from the seed bundles once, no file analysis). All returns equal AND the effects set equal → drop the
def's symbol dependents. Any mismatch, missing def, changed signature, cap overflow, or a key whose
re-evaluation the memo refuses (a transient ADR-84 result) → keep the dependents (conservative). The probe
runs ONLY when a declaration-stable changed pair carries a summary, so a comment edit (no changed pairs) pays
zero WD2 cost — the wall-gate property.

**Eligibility restriction — divergence from the draft (soundness completeness).** A symbol dependent
consumes MORE from a callee body than its return and its content-mutation effects: an ivar definite-assignment
(a same-class caller reading a field the callee assigns, ADR-58 WD3, transitively through the callee's own
calls) and `yield` values (a caller passing a block). Comparing only the return + content-mutation surfaces
would be UNSOUND for a def that touches those. So the return-drop is gated by `gate_eligible_def?`: the def
writes no instance / class variable, does not `yield`, and makes no implicit-self call (which could carry a
transitive shared-state write) — a purely syntactic, conservative sufficient condition under which return +
content-mutation ARE the complete cross-file body surface. An ineligible def keeps its dependents. The
general all-surfaces gate (a transitive ivar-assign summary + a yield-type summary, lifting the restriction)
is deferred.

### WD3 — plugin-fact premise

The gates apply only when the snapshot's plugin-fact fingerprints matched this run. With ADR-88 in place this
is structurally enforced, asserted-not-assumed: `IncrementalSession#run_incremental` trusts the gated
recheck's result ONLY inside the `if reuse` branch (`@plugin_fact_reusable.reusable_against?`), and a fact
mismatch OR an opaque contributing plugin discards the recheck and runs a full baseline — so a plugin whose
cross-file contribution derives from a file's BODY beyond the fingerprinted surfaces can never let a WD1 / WD2
skip stand. The B1 comment-ingesting-plugin off-switch is retained for the one comment-reading plugin the
signature (which ignores comments) would otherwise mis-skip.

### WD4 — verification battery

Fabricated specs (`incremental_session_spec.rb`), each red without the gate / green with, all asserting
byte-identical-to-full:

- **WD1** — same-line body edit → ancestry dependent skipped (`341 → its symbol callers`); arity change →
  propagates; visibility change → propagates; added method → propagates (negative edge); return-visible body
  edit (a `Constant` fold) → propagates via the symbol fingerprint.
- **WD2** — return-preserving refactor (same returns at observed keys) → symbol dependents skipped + merged
  diagnostics byte-identical; return-visible edit → propagates; mutation-effect change (a callee starts
  mutating an arg) → propagates; ineligible def (ivar write) → keeps its dependents.
- **WD3** — the ADR-88 line-shift spec stays green through the gate.

## Rejected / deferred

- **Gating on diagnostics-unchanged** — circular (requires analyzing the dependents to know).
- **Gating on inferred-summary equality WITHOUT the effects channel** — arg-flooring is caller-visible.
- **Un-premised gating without ADR-88** — the B1 audit's content-reading-plugin objection.
- **The per-site line-shift precision** (draft WD1) — the symbol fingerprint is line-invariant, so only the
  file-level edge covers the ADR-17 site consumer; def lines therefore live IN the declaration signature and
  a line shift keeps the full dependent set (sound, coarse). Deferred.
- **The general all-surfaces WD2 return-drop** — comparing transitive ivar-assign + yield surfaces would lift
  the eligibility restriction; deferred behind proving each additional surface's comparison sound. Re-eval
  trigger: demonstrated demand for return-dropping ivar-assigning / yielding callees on a real corpus.
- **WD5-style per-consumer narrowing of ADR-88 invalidation** — remains deferred (ADR-88 WD5).

## Consequences

S5a-shaped edits collapse (the gitlab `def self.safe_find_or_create_by` return-preserving edit: **341 → 1**,
WD1 dropping all 340 ancestry dependents; a `label.rb reference_prefix` literal change: **19 → 1**), so the
"does my edit change types?" question becomes the propagation boundary. Return-preserving refactors of an
eligible leaf callee stop re-checking its callers (WD2). Negative: the snapshot grows by the summaries
(bounded string / stat descriptors); two new comparator surfaces to keep complete (the WD4 battery +
`--verify-incremental` are the insurance); observed-key re-evaluation adds bounded work per changed file, only
when a declaration-stable pair carries a summary. Precision-additive throughout — no type / diagnostic /
severity change; cold diagnostics byte-identical to `origin/master` (mail 26, kramdown 68); gitlab
`--verify-incremental` byte-identical (887/1,774, 2,494, 0 mismatch).

**Measurement note (divergence from the gate's expected numbers).** The gitlab S5a closure collapsed to **1**,
not the recon-estimated ~13–14, because `safe_find_or_create_by` has ZERO recorded in-scope symbol callers
(app/models + app/controllers) — the recon's "13 callers" were textual, not recorded `symbol_dependents`. So
WD1 is the measured gitlab headline (it drops the 340 ancestry dependents); WD2's return-drop does not fire on
these particular gitlab methods (`safe_find_or_create_by` is ineligible — it self-calls `find_by` /
`transaction`; `Label.reference_prefix` has no cross-file symbol callers), and its mechanism is proven by the
WD4 fabricated battery instead.

## Relationship

[ADR-46](46-incremental-dependency-graph.md) (closure machinery), [ADR-84](84-cross-file-return-memo-scoping.md)
(the memo = the summary source; its finality / taint rules gate what may be compared),
[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) (the bundle = the declaration summary's base),
[ADR-88](88-incremental-plugin-fact-soundness.md) (the soundness premise + WD3 site edge), PR #88 B1 (the
comment-only special case this generalizes).
