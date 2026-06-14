# Precision fold-gap recon over rigor-survey (2026-06-14)

Status: point-in-time recon + one finding with a recorded blocker. Non-normative.

## Recon

Broad three-axis pass (precision / FP / teeth) over the `rigor-survey` corpus to
locate fixable typing gaps on real code:

- **Protection** (ADR-63 Tier 1): 17–40 % of dispatch sites have a concrete receiver
  (parser 19.7 % / kramdown 17.3 % / liquid 29.5 % / net-ssh 23.8 % / mail 40.5 %) — most
  dispatch is on `Dynamic` receivers, the bulk **intrinsic** (untyped params, gem returns,
  `Proc#call`).
- **Precision** (`coverage`): precise 44–56 %, **`dynamic_top` 44–56 %** (mail an outlier at
  97 % constant). `dynamic_specific` ≈ 0.
- **FP** (`check`): low yield (the corpus is the FP gate). `tdiary-core`'s 245 is 234
  `call.unresolved-toplevel` from its plugin DSL (`h`/`bot?` — needs a `rigor-tdiary`
  plugin, not an engine fix); elsewhere `possible-nil-receiver` on `loc()`-style nilable
  method returns (genuine-conservative, the WD1b decision — not artifacts).
- **Teeth** (mutation sweep): parser/kramdown survivors are mostly `undefined_method` on the
  projects' **own** classes (ADR-43/24 deferred — can't prove a method absent on an
  in-source class) and the deferred `type_swap` channel (ADR-64).

**Conclusion: the corpus is mature.** The remaining holes are predominantly intrinsic
(need project-side RBS / `source_inference:`, not engine fixes) or already-deferred.

## Fold-gap probe (context-aware)

A first probe over `Scope.empty(environment:)` produced false fold-gaps (`Array#any? →
Dynamic`) — it lacked the project pre-pass seed. Rebuilt to replicate the real path
(`Runner#seed_project_scope` + `ScopeIndexer.index`); the false signals vanished. The
remaining CORE-receiver→Dynamic clusters are all **element/value projections**
(`Array#[]`/`#last`, `Hash#[]`) where the container's element/value type is intrinsically
`Dynamic` (an ivar `Array[Dynamic]` built from untyped sources) — not fold gaps.

## The one real fold gap (found, fix backed out)

`MESSAGES = { … }.freeze; MESSAGES[reason]` types `Dynamic` (parser `messages.rb:120`).
Root cause: **identity / self-returning methods degrade shape carriers.**
`{a: 1}.freeze` → `Hash` (drops the `HashShape`), `[1,2,3].freeze` → `Array` (drops the
`Tuple`), `"x".freeze` → `String` — because `() -> self` routed through RBS resolves
against the *nominal* class, and the degraded `Hash` then makes `#[]` `Dynamic`. The
mutating self-returners (`<<`, `merge!`) genuinely change the shape and must NOT be
preserved; the pure ones (`freeze`, `itself`, `dup`, `clone`) should.

A tier returning the receiver type for those four (on shape carriers) fixed it
(`{…}.freeze; h[k]` → the value union; corpus-FP-safe — **zero new firings across 8
projects** incl. mail). **But it was backed out:** on rigor's OWN constant-folder it
surfaced 12 reflexive `flow.always-truthy-condition` — rigor's self-analysis folds
`receiver.public_send(method_name)` to a constant, so `foldable_constant_value?(result)`
becomes provably-truthy (an over-fold on a runtime-variable `public_send`). Per the project
discipline (fix the cause, never `# rigor:disable` the rule), 12 disables are not
acceptable, and the real root — the reflexive over-fold + the `always-truthy` envelope — is
a separate, larger change.

**Verdict:** real gap, ADR-scoped fix (entangled with reflexive self-analysis). Not a quick
win. Recorded here so it is not re-investigated cold.
