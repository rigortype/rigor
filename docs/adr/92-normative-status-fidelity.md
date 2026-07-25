# ADR-92 — Normative status fidelity: the founding-era stratum and the declare-or-mark gate

Status: **Accepted — implemented 2026-07-16 (WD1–WD5) and 2026-07-25 (WD6, the corpus sweep and its
gate); WD2's `void` verdict resolved to option (b), landed.** WD2 verdicts + WD3 markers landed
in `special-types.md` (§ `void`, § `top`), `diagnostic-policy.md` (four family rows + the
guidelines preamble), and `internal-type-api.md` (a document-level status block narrowing
the method surface to what ships). WD4's gate is axis 5 of
[`spec/docs/manual_drift_spec.rb`](../../spec/docs/manual_drift_spec.rb), load-bearing in
both directions (removing a marker from an unimplemented family goes red; leaving a marker
on a family that later ships goes red — the marker expires). `make docs-check` green, 246
examples. The `void` implement-vs-narrow decision is deliberately carried over (WD2,
measurement-gated) — **now resolved: option (b) landed** (`Bases::Void => :translate_top`),
leaving only the distinct-`void` intent of `special-types.md` § `void` carried over. The
prose-clause body stays ungated by design (WD1).

One in-flight correction worth recording: the gate's first run failed on `sig.*`, which the
spec *had* marked honestly but in different words than WD3's `Reserved`. That surfaced a
third status the draft had missed — **implemented, but reaching the user through another
surface** (`rigor sig-gen`'s JSON, not the diagnostic stream) — distinct from
*claimed-but-unimplemented*. The marker vocabulary therefore keys on the corpus's existing
idiom, the phrase **"as of this writing"** (`inference-budgets.md`'s unwired `budgets:`
table already used it), and admits both statuses.

Grounding: [`docs/notes/20260716-dspec-formal-spec-substrate-evaluation.md`](../notes/20260716-dspec-formal-spec-substrate-evaluation.md)
§ P1 / § (b) / § 段 0 — the three findings and the probes that produced them.

**Amendment (2026-07-25) — a second class, found by finishing the sweep (WD6).** The carry-over
above ("`internal-spec`'s other documents were not swept") was worked through
([#163](https://github.com/rigortype/rigor/issues/163); ledger:
[`docs/notes/20260725-internal-spec-status-fidelity-sweep.md`](../notes/20260725-internal-spec-status-fidelity-sweep.md)).
The *claimed-but-never-implemented* class recurred exactly once —
[`implementation-expectations.md`](../internal-spec/implementation-expectations.md) § Engine surface,
where the incomplete-inference result carrier and the *inference* half of capability roles both name
surfaces absent from all of `lib/`. Three of the five findings were a class this ADR did not
anticipate:

> **A version-anchored future tense that the release then outran.**

"The merger lands in v0.1.0" (`flow-contribution.md`, written at v0.0.9 and still there at v0.3.0,
four sections above the note that it shipped); "the substrate the v0.1.0 plugin API will be designed
against" plus three extensions it never got (`reflection.md`); "nothing consumes it yet"
(`plugin-trust.md`, false since the run-result cache started folding plugin boundary reads into the
run dependency descriptor). **Each was true the day it was written.** That is what separates this
class from the founding-era stratum: no one misstated anything, and no author error is available to
correct. The corpus simply has no mechanism that expires such a sentence, so the release date
silently converts an accurate plan into a false claim — and WD4's gate cannot see it, because that
gate reads the diagnostic-family table and WD1 leaves the prose body ungated.

The inverse direction belongs to the same class: `plugin-trust.md` *under*-claimed what ships. WD4
already names this ("the marker expires"); this amendment records that an unmarked deferral rots the
same way a marker does.

**WD6 — the gate: `manual_drift_spec.rb` axis 6.** Over `docs/type-specification/` +
`docs/internal-spec/`, no sentence may pair a pending marker (`will` / `lands` / `introduces` /
`adds` / …) with a **pinned** version literal at or below `Rigor::VERSION`. Three properties make
this gateable where the general prose body is not:

- **The comparison is decidable** — a version literal against `Rigor::VERSION`, never a judgement
  about whether a clause is satisfied. That is the WD1 line, not an exception to it.
- **A release line cannot expire.** `v0.4.x` / `v1` name a line, not a release, so a sentence about
  one stays true as the line grows. The corpus already uses that spelling for open work
  (`plugin-cache-producers.md`), and the gate's remediation is to adopt it.
- **Past tense is never matched.** `landed` / `added` / `shipped` are how a corrected sentence
  reads; matching them would fight the fix.

The detector carries its own non-vacuity examples — the three real sentences above, plus the shapes
it must not fire on. Without them the axis is silence-shaped: a corpus that is clean passes forever,
including when the detector has quietly stopped detecting.

Precision on the live corpus: two false positives, both instructive. One was a marker in one bullet
pairing with a version literal in the next (fixed by splitting list items before joining lines); the
other was a sentence naming an old version for *history* while promising something else entirely
(fixed by requiring the version to sit within a short window of the marker — the promise must
*govern* the version, not merely share a sentence with it).

The gate is a floor, not a ceiling. `public-api.md` carried three stale sentences that axis 6 does
not match ("until v0.1.0 ratifies them", "as the v0.1.0 plugin observability story finalises"); they
were found by reading and fixed in the same pass. Per WD1 the manual probe remains the instrument
for the prose body.

## Context

`CLAUDE.md` states that the spec binds: when an ADR and the spec disagree on analyzer
behaviour, `docs/type-specification/` and `docs/internal-spec/` win. That promise has a
reader who cannot fall back on reading `lib/` — **rigor-rs**, the sibling Rust port
([ADR-79](79-rbs-version-range-over-pinned-determinism.md) records the deliberate
divergence; [ADR-91](91-kernel-intrinsic-fold-ownership-gate.md) processes its feedback).
For the port, a normative clause *is* the requirement.

A 2026-07-16 investigation found three independent places where the corpus states, in the
present tense, behaviour that has never shipped:

| # | Clause | Implementation |
| --- | --- | --- |
| 1 | [`special-types.md`](../type-specification/special-types.md) § `void` — "Rigor keeps `void` distinct internally so it can diagnose value use"; value context **MUST** produce a "use of void value" diagnostic; imported generic slots **MUST** be preserved | [`rbs_type_translator.rb:51`](../../lib/rigor/inference/rbs_type_translator.rb) — `RBS::Types::Bases::Void => :translate_untyped`. No `Type::Void` carrier, no rule id, zero specs |
| 2 | [`diagnostic-policy.md`](../type-specification/diagnostic-policy.md) § Identifier taxonomy — 12 declared families | `static.*` / `compat.*` / `hint.*` / `generated.<provider>.*` have **zero** implemented ids |
| 3 | [`internal-type-api.md`](../internal-spec/internal-type-api.md) — "the public contract that every Rigor type object MUST satisfy" | `normalize` / `traverse` / `consistent_with` / `equal_value` / `has_method` / `subtype_of` absent from all 23 carriers. `Type::Nominal` exposes `initialize` / `describe` / `erase_to_rbs` / `inspect` |

**Amendment (2026-07-16, same day): a fourth instance**, found by applying the same probe to
a user question about rbs-inline default-loading, and a sharper class than the three above —
not silent non-implementation but a **direct contradiction between the binding spec and an
accepted, shipped ADR**. [`overview.md`](../type-specification/overview.md) § "Compatibility
hierarchy" (2026-04-28) requires inline annotations to be "always parsed and used whenever
present" and says Rigor "MUST NOT require `# rbs_inline: enabled` to begin parsing them";
[ADR-32](32-rbs-inline-comment-ingestion.md) (2026-05-25, implemented v0.1.10) shipped an
opt-in plugin whose WD2 requires exactly that magic comment and lists the spec-mandated
behaviour as a *rejected alternative* — without citing the month-older spec clause anywhere.
Per CLAUDE.md the spec binds, so the shipped behaviour is non-conforming on both the
activation model and the magic-comment gate. The WD4 gate cannot catch this class (it reads
the diagnostic-family table, and WD1 deliberately leaves the prose body ungated), which
confirms the carry-over: the manual probe stays the instrument for prose clauses. The marker
lands in `overview.md`; the design resolution is
[ADR-93](93-default-rbs-inline-ingestion.md).

None is recorded as deferred in any ADR, ROADMAP, CURRENT_WORK, or CHANGELOG entry, and
none carries a marker in its own text. All three are **founding-era**
([ADR-1](1-types.md) / [ADR-2](2-extension-api.md) / [ADR-3](3-type-representation.md))
declarations: written as design targets, presented as binding contract, never reconciled
with what shipped. ADR-1 even names #1 as a foreseen risk — "`void` and `untyped` are
likely to be treated as broad aliases too early" — which then happened, unobserved.

**Why no gate caught it.** Two structural blind spots compose. Every docs axis in
[`spec/docs/manual_drift_spec.rb`](../../spec/docs/manual_drift_spec.rb) runs
**impl → doc** ("every key in `Configuration::DEFAULTS` must be mentioned in the
reference"; "every ID in `ALL_RULES` must appear in the catalogue"); the reverse direction
is unchecked. And every *analysis* gate is false-positive-oriented (corpus byte-identical,
regression sweeps, `make check`), so a diagnostic that was never implemented is **silence**
— invisible by construction. [ADR-62](62-mutation-testing-teeth-measurement.md) built a
harness for exactly this class of blindness one layer down, but mutation testing needs code
to break; an absent feature has none.

## Decision

> **A normative clause states behaviour in the present tense only if it ships. Otherwise
> it carries an explicit status marker at the point of declaration.**

The criterion's force is in its corollary: **silence is never the honest state for a
divergence.** Three outcomes are available per clause — implement it, narrow the clause to
what ships, or mark the gap — and *marking is always available and always cheap*. So the
cost of the other two never justifies leaving a clause that lies. This separates the
status question (settle now, always) from the design question (settle on evidence).

This is [ADR-49](49-adr-authoring-guidelines.md) axis 6 (*Status & progress fidelity*)
applied to the **spec** corpus rather than the ADR corpus. The corpus already demonstrates
the marker twice — [`inference-budgets.md:75`](../type-specification/inference-budgets.md)
("**As of this writing the configurable `budgets:` surface is not yet wired**") and
[`diagnostic-policy.md:43`](../type-specification/diagnostic-policy.md) (`sig.*` is
JSON-output-only). **The norm is established; only enforcement is missing.**

## Working decisions

**WD1 — scope: enumerable declaration tables, not the prose body.** The gate binds
surfaces the corpus *enumerates* (the diagnostic family taxonomy; the type-object method
surface), where "declared vs implemented" is a decidable set comparison. It does **not**
bind the ~836 prose `MUST`/`SHOULD` occurrences. Most are not atomic testable propositions
(authoring conventions, display rules, explanatory usage); id-ing them to force coverage
manufactures `reference`-grade links with no substance — false assurance, the failure the
grounding note's rejected dspec design exists to illustrate.

**WD2 — per-instance verdicts.**

- **`void` → MARK now; the design decision is carried over, measurement-gated.** There are
  **three** live options, not two, because the shipped behaviour matches neither the spec
  nor RBS:

  | | `void` is… |
  | --- | --- |
  | RBS (`docs/syntax.md` § "`void`, `boolish`, or `top`?") | `top` — "They are all equivalent for the type system; they are all *top type*"; `void` is a developer hint |
  | This spec (intent, unshipped) | distinct; diagnoses value use; materializes as `top` |
  | The engine | `untyped` = `Dynamic[top]` |

  `top` and `Dynamic[top]` are different carriers (`Combinator.top` vs `Combinator.untyped`),
  and `Dynamic[top]` is the *more permissive* of the two — consistent with everything at a
  gradual boundary, where `top` demands proof. So the engine is today **looser than RBS's own
  semantics**, a silent divergence from the installed toolchain that
  [ADR-79](79-rbs-version-range-over-pinned-determinism.md)'s fidelity criterion does not
  license; it survived because the direction is FP-safe. The options: **(a) implement** the
  distinct-`void` intent — a new required discipline = BC under
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1, so behind `bleeding_edge:`;
  **(b) narrow to RBS** (`Bases::Void => :translate_top`, one line) — restores toolchain
  fidelity and is the closest cheap reading of [ADR-1:30](1-types.md)'s "type-theoretic
  clarity rather than ad hoc aliases"; **(c) narrow to the engine** (concede `void = untyped`)
  — abandons both RBS and ADR-1:30 and is the weakest. All three need the same corpus
  measurement (how often is a `-> void` return consumed in value position — `-> void` is
  pervasive in real RBS); the marker needs none and stops the misstatement today.
- **`static.*` / `compat.*` / `hint.*` / `generated.*` → MARK as reserved-not-implemented.**
  `static.*`'s budget half already has its marker (`inference-budgets.md:75`) and its ADR
  ([ADR-41](41-inference-budget-design.md), Proposed); the taxonomy row must point at it
  rather than restate the family in the present tense. `compat.*` / `hint.*` /
  `generated.*` are founding-era reservations with no consumer — the identifier space stays
  reserved (that is what the taxonomy is *for*), but reservation is stated as reservation.
- **`internal-type-api.md` → NARROW to the shipped routing, MARK the absent capabilities.**
  The split is not uniform and the document must say which is which. `accepts` ships, routed
  through `Type::AcceptanceRouter`. `subtype_of` / `has_method` name capabilities the engine
  *has* but reaches through internal helpers of a different shape (`rbs_subtype?` and its
  neighbours) rather than as a carrier method. `normalize` / `traverse` / `consistent_with` /
  `equal_value` — and every method of § *Structural queries* (`members`, `key_type`,
  `value_type`, `tuple_arity`, `iterable_*`) — have **no implementation anywhere in `lib/`**;
  `consistent_with` and `equal_value` have no near-name either. The document's own § Scope
  already declines to bind concrete method names (ADR-3 OQ2) and the concrete class set
  (OQ1) — but that carve-out excuses *spelling*, not relocating an entire surface. There is
  no evidence the carrier-method shape beats the router the engine actually uses, so the
  document follows the implementation. `normalize` / `traverse` are absent outright (no
  near-name anywhere in `lib/`) and are marked, not narrated.

**WD3 — marker shape follows the two precedents.** Inline, at the point of declaration,
naming what is unwired and where the intent is recorded. No new metadata schema, no
per-clause `status:` front-matter (a dspec-shaped registry — rejected below). The marker is
a bolded status carrying the phrase **"as of this writing"** — the idiom
`inference-budgets.md:75` already uses — and covers two statuses: *Reserved* (claimed, never
implemented) and *Not a diagnostic family* (implemented, reaches the user by another
surface). The second was found by the WD4 gate rather than by the draft; see Status.

**WD4 — the gate: `manual_drift_spec.rb` gains the doc → impl direction.** Every family the
taxonomy declares must have **≥ 1 implemented diagnostic id or a status marker**. The
implemented vocabulary is *not* `CheckRules::ALL_RULES` alone (26 ids) — the non-check
families (`dynamic.*` / `pre-eval.*` / `rbs.coverage.*` / `rbs_extended.*`, 13 more) are
emitted outside `CheckRules` and admitted by `known_suppression_token?` per family, so the
gate reads the full 39-id surface or it will report false gaps.

**WD5 — adjudicate before gating.** WD2/WD3 land before WD4 in the same change set; a gate
introduced first lands red on five pre-existing divergences and would invite a blanket
skip, which is the discipline this ADR exists to install.

## Rejected / deferred alternatives

- **Stable ids on every normative clause + a coverage gate (the dspec design).** The found
  class is narrow and enumerable; a whole-corpus registry buys `reference`-grade links that
  assert nothing. Rejected in the grounding note on its own evidence.
- **Leave it (documentation drift is cosmetic).** Rejected: the port is a live consumer and
  is the reader least able to detect the lie.
- **Implement all three now.** Rejected: `void` is BC-bearing (ADR-50 WD1) and the
  `internal-type-api` surface has no evidence of being better than what ships. Status
  fidelity must not be held hostage to a design decision.
- **Delete the aspirational clauses.** Rejected: it discards recorded design intent that is
  still wanted (ADR-1:30's type-theoretic-clarity requirement for `void` in particular).
  Marking preserves the intent and the honesty at once.
- **A machine-readable `status:` schema per clause.** Rejected as disproportionate: two
  prose precedents already work, and the gate needs only the family tables.

## Consequences

- **Positive.** The corpus stops misstating five behaviours to its one reader who cannot
  check (rigor-rs). The WD4 gate makes recurrence unrepresentable for the declared surfaces
  — the direction that let all five through is closed. Design intent survives as
  reservation rather than as a false claim.
- **Negative / cost.** The corpus admits in writing that several founding declarations
  never shipped — a credibility cost, paid once and deliberately, against a spec that
  currently reads as complete and is not. WD4 adds one docs-spec axis (no analysis cost).
- **Carry-over.** (1) `void`: the three-way choice in WD2. **The measurement is now done**
  (grounding note § "void 三択の A/B 実測"): patching `Bases::Void => :translate_top` leaves
  diagnostics byte-identical on mail (26), kramdown (68), haml (60), liquid (5), and
  mastodon `app/models` (0, 248 files) — non-vacuously, since instrumenting the translator
  counts 29 real `Void` translations in kramdown and 2 in mail. So **option (b) is free**,
  and option (c) is eliminated: with (b) costing nothing there is no reason to concede both
  RBS and ADR-1:30. The reason (b) is free is itself the point — `static.*`, the family that
  would diagnose an unguarded `top` call, is Reserved, so `top` and `Dynamic[top]` are
  equally silent today; (b) buys representational fidelity that pays off when `static.*`
  lands, not a diagnostic today. (a) is **not** simply (b) plus more: this section wants
  `void` distinct from `top` precisely to explain *why* a `top` appeared, which a naive (b)
  discards — but [ADR-75](75-dynamic-provenance.md)'s pattern applies unchanged (provenance
  is metadata *about* a value, never part of what it *is*), so `void → top` plus a
  `void_origins` identity-keyed side-table reaches (a)'s intent on (b)'s foundation without
  adding a carrier or forking the lattice.

  **(b) landed in this change set** (`Bases::Void => :translate_top`; full suite 7,914
  examples green, `make check` / `check-plugins` clean, corpus byte-identical on
  mail/kramdown/haml/liquid). A user report sharpened the case beyond the fidelity argument
  and is why it landed now rather than waiting: a author writing `#: void` is declaring "do
  not rely on this return", and `Dynamic[top]` — consistent with everything at a gradual
  boundary — lets a caller silently build that dependency anyway, which is the one outcome
  `void` exists to prevent. `top` demands proof, so it serves the declared contract; the
  widening the author asked for is to `top`, exactly as RBS defines it.

  **What remains carried over** is (a): `special-types.md` § `void`'s distinct-`void` intent,
  whose value-position diagnostic needs two more pieces — the **`static.*` family** (Reserved,
  and the connective that actually makes `top` bite: without it `top` and `Dynamic[top]` are
  equally silent, which is why (b) measured free) and a **`void_origins` side-table** for the
  transitive case (`def bar; foo; end; a = bar` — `bar` declares nothing, so a call-site rule
  reading `bar`'s RBS cannot see the `void` that reached it through the body). (2) The prose-clause body stays ungated (WD1) — the P1-class probe remains a
  manual instrument. (3) `internal-spec`'s other documents were not swept; only
  `internal-type-api.md` was probed — **resolved 2026-07-25**, see the WD6 amendment above: the sweep
  found one more instance of this ADR's class and three of a second one, now gated by axis 6. The
  three largest documents (`inference-engine.md`, `plugin.md`, `cache.md`) got the enumerated-surface
  pass rather than a line-by-line read, which is what keeps #163 open.

## Relationship to other ADRs

- **ADR-1 / ADR-2 / ADR-3** — the founding declarations this reconciles. ADR-1 foresaw
  finding #1 and is the reason the `void` intent is marked rather than deleted.
- **ADR-49** — supplies the criterion by extension: axis 6 (*Status & progress fidelity*)
  already binds the ADR corpus; this applies the same discipline to the spec corpus.
- **ADR-41** — the model instance: a Proposed ADR plus an in-spec marker is exactly the
  shape WD2 requires of the other gaps.
- **ADR-50** — WD1 makes a new required discipline BC, which is why `void` cannot simply be
  implemented into the default surface.
- **ADR-62** — kinship: both target false negatives that FP-oriented gates cannot see.
  ADR-62 covers absent *teeth*; this covers absent *features*.
- **ADR-79 / ADR-91** — rigor-rs as a live consumer of the spec, and the precedent of
  converting an externally-discovered gap into an in-repo gate.
