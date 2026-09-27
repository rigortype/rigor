# ADR-89 — Semantic propagation gates: declaration-shape and observed-key return summaries

Status: **Accepted — WD1 (declaration-shape gate for ancestry / file-level dependents) + WD2 (observed-key
return-summary gate for symbol dependents) implemented ([PR #90](https://github.com/rigortype/rigor/pull/90)).
WD1's comment-ingesting-plugin off-switch replaced by a per-file source-RBS output digest (Amendment
2026-09-28, [#1536](https://github.com/rigortype/rigor/issues/1536)).**
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

> **Amended 2026-09-28 ([#1536](https://github.com/rigortype/rigor/issues/1536)).** The off-switch is gone.
> A changed file is declaration-stable only when its declaration signature AND the digest of every loaded
> source-RBS synthesizer's output for it are unchanged, and an edit that moves any synthesized output
> re-analyses the whole project. See § "Amendment 2026-09-28" below.

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
signature (which ignores comments) would otherwise mis-skip. (Replaced 2026-09-28 by the source-RBS output
digest — § "Amendment 2026-09-28".)

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
`--verify-incremental` byte-identical (887/1,774, 2,494, 0 mismatch). The S1 single-file recheck wall stays
within noise of `origin/master` — the gates buy their precision by dropping dependents, not by adding a
measurable per-run cost.

**Measurement note (divergence from the gate's expected numbers).** The gitlab S5a closure collapsed to **1**,
not the recon-estimated ~13–14, because `safe_find_or_create_by` has ZERO recorded in-scope symbol callers
(app/models + app/controllers) — the recon's "13 callers" were textual, not recorded `symbol_dependents`. So
WD1 is the measured gitlab headline (it drops the 340 ancestry dependents); WD2's return-drop does not fire on
these particular gitlab methods (`safe_find_or_create_by` is ineligible — it self-calls `find_by` /
`transaction`; `Label.reference_prefix` has no cross-file symbol callers), and its mechanism is proven by the
WD4 fabricated battery instead.

## Amendment 2026-09-28 — gate on the synthesizers' output, not on a plugin's name ([#1536](https://github.com/rigortype/rigor/issues/1536))

Stakes: high. It moves a soundness gate, and a closure that under-approximates serves a stale diagnostic
that `--verify-incremental` cannot see (it never calls `affected_closure`).

**Context.** WD1 and WD3 kept B1's off-switch: `IncrementalSession#comment_ingesting_plugin_loaded?`
matched a `plugins:` entry named `rigor-rbs-inline` and marked every changed file declaration-unstable. It
had three defects.

- Since [ADR-93](93-default-rbs-inline-ingestion.md) WD2 auto-wires that entry whenever `rbs-inline`
  resolves, WD1 never fired in any bundle carrying the gem. That includes every development and CI bundle,
  since `rbs-inline` is a development dependency of `rigortype`. On Mastodon (1,404 files, no
  annotation), appending a comment to `app/models/account.rb` re-analysed its 311-file ancestry closure.
- It ignored `enabled: false`, so the documented opt-out still switched the gate off.
- It was not sufficient. Marking the edited file unstable re-checks its ancestry dependents and the
  dependents of its changed symbol pairs. An annotation edit changes no method body, so no pair changes.
  With an ancestry dependent present, a reader of `Greeter#greet` kept the pre-edit return type. A reader
  that resolves a member through the synthesized RBS alone records no edge to the file at all. That
  happens for `attr_reader :name #: String` read as `Holder.new.name`, and for an `@rbs!` block declaring
  a method of a class defined in another file.

**Decision.**

1. Each ADR-85 seed bundle carries `source_rbs_digest` (`IncrementalSnapshot::SCHEMA` 29→30): a digest of
   the RBS every loaded `source_rbs_synthesizer` contributes for the file, as the loader reads it. It is
   the `none` sentinel when nothing is contributed, and nil when an output cannot be read.
   `Environment::SourceRbsSynthesis.digest` computes it through the same function and `Cache::Store`
   entries `Environment.collect_virtual_rbs` feeds the loader from, so an unmoved digest means the loader
   read the same bytes. The ADR-32 WD6 / WD12 notices are left out. They reach only the run-level
   `source-rbs-*` rows, which every run regenerates and the per-file cache never serves, and they quote line
   numbers, so digesting them would turn a line shift in a file carrying a malformed `#:` into a
   whole-project re-analysis. A failed synthesis contributes nothing to the loader but counts as one stable
   value, so a file that flips between "no annotation" and "broken annotation" still reads as moved. The
   RBS text itself is digested whole, comments included (decision 6).
2. `Analysis::SourceRbsGate` writes the digest onto the bundles the runner built this run. A reused bundle
   keeps its digest, which stays exact because a bundle is reused only for byte-identical content. A stamp
   must describe the synthesized RBS the cached answers of the file's readers were computed under, so each
   digest is bound to its bundle's bytes. The reading the closure was decided on is stamped only when the
   file's SHA-256, taken before and after it, equals the content digest the runner built the bundle from.
   A file saved after the closure was decided is not read again: its readers' cached answers predate the
   save. It is stamped unknown, and its recorded content digest is forgotten, so the next run detects it as
   changed and re-analyses the project. A bundle the run built without such a reading is stamped from a
   reading taken after the run only when every file was just re-analysed (a baseline, or a whole-project
   recheck), and is stamped unknown the same way otherwise. An unknown stamp is re-stamped once a run can
   vouch for it: when its file is next read for a closure, or the next time every file is re-analysed.
3. The gate reads the synthesizers from a plugin registry it loads for itself, without `#prepare`, before
   the recheck runner exists. Every loaded synthesizer counts, not one plugin known by name. An
   `enabled: false` entry, which the loader skips, contributes none. A registry without `#prepare` is exact
   only for a synthesizer the manifest declares before `#prepare` runs. So after every `--incremental` run,
   one that changed nothing and so read no file included, the session compares, by plugin id and order,
   the gate's set with the prepared registry's. A stamp written by an earlier process is at stake even
   when this run read nothing, and a long-lived session gets its only check at priming. The prepared
   registry is the one ADR-88 WD1 already reads: the runner's on a sequential run, and the sequential
   probe's on a pooled one. On a mismatch the gate turns untrusted for the session. Every bundle's digest is
   stamped unknown before the snapshot is saved, and every later edit re-analyses the whole project. The
   run that found the mismatch, if it was an edit whose recheck left files out, re-analyses the project at
   once (`run_buffer_recheck` declines instead). A run that changed nothing stays a null run: every edit
   under the untrusted gate already re-analysed the whole project, so the snapshot it serves is whole.
   [`plugin.md`](../internal-spec/plugin.md) states the contract a synthesizer must keep.
4. Before WD1 and WD2 run, the recheck asks whether the edit moved any synthesized output. It has moved
   when a changed file's digest differs from its bundle's or either is unknown, when an added file
   contributes anything, or when a removed file contributed anything. If so, the closure is every analysed
   file. Otherwise WD1 runs on the declaration signature alone, which is sound because every changed file's
   synthesized contribution is then byte-identical. A digest that cannot be read affects only an edit that
   changes or removes that file. It never switches the gate off for the project.
5. The fallback is the whole project, not the file's dependents, because ADR-46 records Ruby-side reads, and
   a read of a `virtual:` buffer records no edge back to its `.rb` file (the shapes above). This is what a
   `sig/` edit already costs through the snapshot fingerprint. Narrowing it needs those reads recorded:
   [#1544](https://github.com/rigortype/rigor/issues/1544).
6. The digest comes from the output, not from the comment lines. rbs-inline binds an annotation by
   adjacency, so a plain comment or a blank line can bind or unbind one without touching its text. In an
   annotated file upstream emits a skeleton for every `def`, `attr`, constant and mixin, and the plugin
   rewrites `#:nodoc:`-style directives before parsing. The output's comments stay in the digest. Upstream
   copies each member's comment block, and the `.rb` file's first comment line, into the RBS it writes, and
   RBS reads a `# resolve-type-names:` magic comment at the start of a buffer. Flipping that one line in a
   `.rb` file changes how every type name in its RBS resolves. A string-literal type can also span lines
   that start with `#`. A line-based strip of comments from the digest input was tried in review and
   reverted for these reasons. A sound comment-insensitive digest is
   [#1549](https://github.com/rigortype/rigor/issues/1549). Until it lands, rewording any comment in an
   annotated file re-analyses the project.
7. `Effects::InlineAnchor` maps an effect envelope's location onto the `.rb` line of its annotation, which
   the RBS text does not carry, so a line shift can move that position without moving the digest. This
   needs no handling. The mapped location reaches only `EffectEnvelopePass` and
   `EffectAnnotationResidualPass`, which are run-level passes, recomputed on every run from the current
   bytes and never served from the per-file cache. A per-file effect collection imports an envelope's
   bound, which the RBS text carries.

**Consequences.** Measured on Mastodon main (1,404 files, `app/models/account.rb`, 310 ancestry
dependents; one run per edit on a shared host, so the walls are indicative):

| edit | master | this amendment |
| --- | ---: | ---: |
| comment appended | 311 files, 13.1 s | 1 file, 2.2 s |
| same-line literal change | 311 files, 13.1 s | 1 file, 2.0 s |
| NOTE comment turned into `#: () -> void` | 311 files, 13.2 s | 1,404 files, 21.0 s |

Every answer from this amendment matched a cold `--no-cache` run. On a project without annotations,
nothing else changes. In an annotated project, every edit that moves the synthesized RBS re-analyses the
whole project. Such edits include an annotation edit, adding, removing or renaming a `def` in an
annotated file, and, until [#1549](https://github.com/rigortype/rigor/issues/1549), rewording any comment
in one. Master re-analysed the file's ancestry closure for these edits, which can serve a stale answer. A
baseline computes one digest per file: a `Cache::Store` hit after the environment build, or a second
synthesizer run under `--no-cache`, plus two content SHA-256 reads that bind each digest to its bundle.
Every `--incremental` run loads the plugin registry once more for the post-run comparison. A plugin that
builds its synthesizer in `#prepare` costs its project a whole-project re-analysis on every
`--incremental` run that changes a file; a run that changes nothing stays a null run. After it is fixed, the unknown stamps it left clear one file at a time, as each is
next edited, or all at once on the next whole-project run. The language server re-seeds its session from the
on-disk snapshot on every watched-file change, and editor mode never saves. In both, the whole-project
fallback therefore repeats until a terminal `--incremental` run refreshes the snapshot, as master's
ancestry closure already did ([#1547](https://github.com/rigortype/rigor/issues/1547)).

## Relationship

[ADR-46](46-incremental-dependency-graph.md) (closure machinery), [ADR-84](84-cross-file-return-memo-scoping.md)
(the memo = the summary source; its finality / taint rules gate what may be compared),
[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) (the bundle = the declaration summary's base),
[ADR-88](88-incremental-plugin-fact-soundness.md) (the soundness premise + WD3 site edge), PR #88 B1 (the
comment-only special case this generalizes).
