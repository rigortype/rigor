# ADR corpus rubric audit — scoring ADR-0…49 against ADR-49

Status: **working note, no design commitments.** A point-in-time
measurement taken 2026-06-05 against the ADR corpus as it stands at this
commit, applying the [ADR-49](../adr/49-adr-authoring-guidelines.md)
authoring rubric. Scores are **one reader's judgement calibrated to the
rubric**, not a gate — their job is to locate the one or two axes pulling
each ADR down and to validate ADR-49 itself against real data before it
is frozen into a SKILL. The spec and the ADRs bind; this note does not.

Reading-order companion: [ADR-49](../adr/49-adr-authoring-guidelines.md)
defines the archetypes, the stakes tag, and the eight axes scored below.

## Method

Each ADR is tagged with an **archetype** (Deliberative / Mechanical-policy
/ Evaluation-proposal) and **stakes** (low / mid / high, per reversibility
× blast-radius × FP-envelope), then scored on the eight axes — each
`0`/`1`/`2`, or `–` for an archetype-exempt axis (dropped from the
denominator, never scored `0`):

| Key | Axis |
| --- | --- |
| **I** | Intent & purpose |
| **C** | Decision criterion |
| **A** | Actionability & code-anchoring |
| **G** | Constraints & guardrails |
| **V** | Verifiability & evidence |
| **S** | Status & progress fidelity |
| **X** | Connectedness |
| **E** | Economy / proportionality (bidirectional) |

`%` = `sum / (2 × scored-axes)`. Per ADR-49, a low score is read as
"which axis drags," not "bad ADR" — many low scores are correct economy
or age, not defects.

## Per-ADR scores

| # | Title (short) | Arch | Stk | I | C | A | G | V | S | X | E | % | Main drag |
| --- | --- | --- | --- | -- | -- | -- | -- | -- | -- | -- | -- | --: | --- |
| 0 | Foundation/concept | Delib | hi | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 63 | pre-code: no anchors/criterion (age-correct) |
| 1 | Type model / RBS superset | Delib | hi | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy (850 lines; ref tables) |
| 2 | Extension API | Delib | hi | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy / open-question sprawl |
| 3 | Type representation | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 4 | Inference engine | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (478 lines) |
| 5 | Robustness principle | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify (examples, no numbers) |
| 6 | Cache backend | Delib | mid | 2 | 2 | 2 | 2 | 1 | 1 | 2 | 2 | 88 | verify (design, no measurement) |
| 7 | v0.1.0 slice decisions | Mech | mid | – | 2 | 2 | 1 | 1 | 1 | 2 | 1 | 71 | bundle: thin guard/status/econ |
| 8 | Steep-inspired | Delib | mid | 2 | 1 | 2 | 1 | 2 | 1 | 2 | 2 | 81 | criterion (direction, few alternatives) |
| 9 | Cross-plugin API | Delib | mid | 2 | 2 | 2 | 1 | 1 | 2 | 2 | 2 | 88 | verify |
| 10 | Dependency-source inference | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 11 | Sorbet input adapter | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy (translation tables) |
| 12 | dry-rb packaging | Mech | low | 1 | 2 | 1 | 1 | 1 | 1 | 2 | 2 | 69 | packaging: thin action/verify (stakes-ok) |
| 13 | TypeNode resolver | Delib | mid | 2 | 2 | 2 | 1 | 1 | 2 | 2 | 1 | 81 | economy / guard |
| 14 | sig-gen | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 15 | Ractor concurrency | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (very long) |
| 16 | Macro substrate | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (1221 lines) |
| 17 | Monkey-patch pre-eval | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 18 | Substrate per-call return | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify |
| 19 | LSP packaging | Delib | mid | 2 | 2 | 1 | 2 | 1 | 1 | 2 | 2 | 81 | action (packaging, no code) |
| 20 | Lightweight HKT | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy |
| 21 | Rubydex evaluation | Eval | mid | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy (long for a defer-all eval) |
| 22 | Baseline + onboarding | Delib | mid | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (960 lines — outlier) |
| 23 | Triage command | Delib | mid | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 2 | 94 | guard (WD3 fragility noted) |
| 24 | Self-call resolution | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy |
| 25 | Plugin-contributed RBS | Delib | mid | 2 | 2 | 2 | 1 | 1 | 1 | 2 | 2 | 81 | verify / status |
| 26 | ActiveRecord relation typing | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 100 | — (exemplar) |
| 27 | Tool distribution | Delib | mid | 2 | 2 | 1 | 2 | 1 | 1 | 2 | 1 | 75 | action/status (partial impl) |
| 28 | Protocol contracts | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify |
| 29 | Browser playground | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 30 | rigor-ffi plugin shape | Eval | mid | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy (long proposal) |
| 31 | Contribution policy | Mech | hi | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy (policy prose) |
| 32 | rbs-inline ingestion | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 33 | MCP server | Mech | low | 1 | 2 | 2 | 1 | 1 | 2 | 1 | 2 | 75 | concise+complete (low-stakes-correct) |
| 34 | Toplevel unresolved-self | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify (empirical, no corpus #) |
| 35 | Override sig compatibility | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (WD9 large) |
| 36 | Mangrove nested-class | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify |
| 37 | Plugin interface segregation | Delib | hi | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy |
| 38 | Additional initializers | Mech | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify (reasoned FP-safety) |
| 39 | Target-library invocation | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (isolation section) |
| 40 | config_schema defaults | Mech | low | 1 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 88 | mechanical done well |
| 41 | Inference budget design | Eval | mid | 2 | 2 | 1 | 2 | 2 | 2 | 2 | 1 | 88 | economy (long) |
| 42 | Plugin binary-op return | Eval | low | 2 | 2 | 1 | 2 | 1 | 2 | 2 | 1 | 81 | economy (long for demand-gated) |
| 43 | RBS-complete ancestor | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 100 | — (exemplar) |
| 44 | Allocation churn | Delib | mid | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 100 | — (exemplar) |
| 45 | Run-result cache | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 100 | — (exemplar) |
| 46 | Incremental dep graph | Delib | hi | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 100 | — (exemplar; dense status block) |
| 47 | Clause reachability | Delib | mid | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 1 | 94 | economy (status prose dense) |
| 48 | Data value folding | Delib | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 1 | 88 | economy (carrier-zoo checklist) |
| 49 | ADR authoring guidelines | Mech | mid | 2 | 2 | 2 | 2 | 1 | 2 | 2 | 2 | 94 | verify (this audit *is* the evidence) |

## Distribution

| Band | Count | ADRs |
| --- | --: | --- |
| 100 % | 5 | 26, 43, 44, 45, 46 |
| 88–94 % | 30 | 3,4,5,6,9,10,11,14,15,16,17,18,20,22,23,24,28,29,32,34,35,36,37,38,39,40,41,47,48,49 |
| 75–81 % | 13 | 1,2,8,13,19,21,25,27,30,31,33,42, (12 at 69) |
| < 70 % | 2 | 0 (63), 12 (69) |

Median ≈ 88 %. The corpus is uniformly strong; the spread is narrow and
the bottom is not failure (see below).

## Findings

### 1. The headline audit output is empty — and that is the reassuring result

ADR-49's single most valuable signal is **high-stakes × thin intent** (a
load-bearing decision recorded without its reasoning). **The corpus has
none.** Every `high`-stakes ADR (0, 1, 2, 3, 4, 5, 10, 15, 16, 17, 20,
24, 26, 31, 34, 35, 37, 39, 43, 45, 46) scores `2` on **both** Intent and
Criterion. The rubric's alarm never fires — which, for a rubric whose
purpose is to catch exactly that gap, is the corpus passing the test, not
the rubric finding nothing to do.

### 2. Economy is the one recurring drag — and it confirms ADR-49's goal

The single most-lost point across the corpus is **axis 8 (economy)**: ~22
of 50 ADRs drop it. The corpus trends toward **over-information**, never
under — there is not one ADR that is too thin to implement from. This is
the exact asymmetry ADR-49's bidirectional economy axis exists to name,
and it validates making *brevity-for-stakes* the lever ADR-49 pushes.

Clearest over-information cases (length disproportionate even granting the
stakes):

- **ADR-22** (960 lines) — a baseline mechanism whose WD9 alternatives
  analysis alone runs longer than most whole ADRs. The decision is sound;
  the prose is ~2× what a `mid`-stakes onboarding feature warrants.
- **ADR-16** (1221 lines) and **ADR-1** (850) — `high`-stakes, so length
  is more defensible, but both carry large reference/comparison tables
  that could move to a linked note.
- **ADR-21 / ADR-30 / ADR-42** — *evaluation* archetype, `mid`/`low`
  stakes, yet long. A "defer / demand-gate this" decision paying
  full-deliberation length is the proportionality smell on the
  low-stakes side.

Counter-examples that nail economy (the calibration targets): **ADR-33**
(MCP, ~120 lines, concise+complete), **ADR-38** (additional initializers,
tight), **ADR-44** (allocation churn, tight high-signal), **ADR-40**
(config defaults — a small mechanical change written small).

### 3. Low scores are archetype/age, not defects — the don't-over-penalize rule works

The bottom of the table is **not** the weakest ADRs:

- **ADR-0 (63 %)** — pre-code foundation; no code anchors or
  alternatives-criterion because none existed yet. Correctly low, not bad.
- **ADR-12 (69 %), ADR-7 (71 %), ADR-33 (75 %)** — mechanical/bundle
  archetypes where Intent is legitimately light. ADR-7's Intent is `–`
  (N/A, scored out of 14); without the exemption it would read far worse
  than it is. The N/A mechanism is doing its job.
- **ADR-27 (75 %)** — a partially-implemented distribution policy; the
  Status/Action points reflect genuine in-flight state, which is honest,
  not a documentation gap.

No ADR scored low for the reason that matters (a real reasoning gap). This
is the evidence that ADR-49's exemptions don't manufacture false failures.

### 4. The corpus's genuine strengths cluster on three axes

Near-universal `2`s on **Criterion (C)**, **Guardrails (G)**, and
**Connectedness (X)**. The corpus is exceptional at recording the
discriminating decision rule (ADR-43's allow-list criterion, ADR-35's
direction-asymmetry, ADR-15's fork-vs-Ractor table), at stating the
FP/soundness envelope (it is the project's top value and shows up in
nearly every guard section), and at cross-linking. These are the house
strengths a SKILL should preserve by default, not re-teach.

### 5. Verifiability (V) is the cleanest archetype/recency signal

V splits sharply: **recent deliberative** ADRs carry hard numbers (ADR-43
zero-net-FP, ADR-45 11.6→1.8s, ADR-35 160→35 FP, ADR-24 467→15, ADR-15
bug #22075, ADR-44 GC −29 %) and score `2`; **older or design-only** ADRs
(5, 6, 9, 13, 25, 28) are reasoned-but-unmeasured and score `1`;
**evaluation/proposal** ADRs correctly carry survey evidence but no
shipped measurement (ADR-41 is the standout — measurement-driven *as a
proposal*). This is the axis where ADR-49's "evidence sub-part N/A for
proposals" exemption matters most; the data supports keeping it.

### 6. Status/body fidelity (S) is uniformly high — no drift found

Every ADR's body matched its Status line. The recent ADRs' habit of a
dense landed-status opening paragraph (ADR-46, ADR-47, ADR-24) doubles as
a resume bookmark — high `S`, at a small `E` cost (the wall-of-status is
itself an economy nibble). Worth noting as a deliberate trade the SKILL
should sanction rather than discourage.

## Exemplars and anti-pattern, for ADR-49's calibration set

- **Best overall (100 %): ADR-26, 43, 44, 45, 46.** All deliberative, all
  recent, all carry a reusable decision criterion + a measured FP/perf
  result + a tight body. ADR-43 (criterion) and ADR-46 (soundness +
  progress) are already ADR-49's named anchors; **ADR-45** (the
  rejected-unsound-design-then-sound-design arc) and **ADR-26** (reverted
  first attempt → diagnostic-layer fix) are the strongest additions —
  both teach "record the wrong turn."
- **Best mechanical: ADR-40 / ADR-38 / ADR-33** — small changes written
  small, with a rejected-alternatives table that earns Criterion `2`
  without bloat. ADR-49 already cites ADR-40; ADR-33 is the purest
  "concise MCP-shaped" example.
- **Economy anti-pattern: ADR-22** — the corpus's clearest "right
  decision, over-written" case. A good negative exemplar for the economy
  axis (it is not *wrong*, it is *long*), which the SKILL can use to show
  what `E=1` looks like without implying the ADR is low-quality.

## Implications for ADR-49 (and the queued SKILL)

1. **The rubric survives contact with the corpus.** Its alarm (high-stakes
   × thin intent) correctly stays silent, its exemptions correctly rescue
   mechanical/foundation ADRs, and its one active lever (economy)
   identifies a real, consistent corpus trend. No axis was inert; no
   exemption produced a false failure. ADR-49 is safe to freeze into a
   SKILL.
2. **Economy is the lever worth foregrounding.** Since over-information is
   the corpus's only systematic drift, the drafting SKILL should make
   *length-for-stakes* its most prominent prompt — e.g. an evaluation or
   low-stakes ADR that exceeds ~ADR-33 length should prompt a "move this to
   a linked note?" check. The reference-table-extraction pattern (ADR-1 /
   ADR-16 candidates) is the concrete remedy.
3. **One small ADR-49 refinement to consider (not made here):** the
   "dense landed-status paragraph" is a recurring, *deliberate* economy
   nibble that buys resume-bookmark value (finding 6). ADR-49's economy
   axis currently reads it as a minor `E` cost; the SKILL should call it
   out as a sanctioned trade, not a defect, so authors don't trim a
   load-bearing status block to chase the economy point.
4. **No individual ADR needs a corrective edit on this audit's evidence.**
   Every "drag" is either age (ADR-0), archetype (ADR-7/12/33), honest
   in-flight state (ADR-27), or proportional length on a high-stakes ADR.
   The economy outliers (esp. ADR-22) are candidates for a *future*
   trim-and-link pass if one is ever desired, but none is a correctness or
   sufficiency gap.

## Caveats

- Scores are one reader's calibrated judgement in a single pass; the
  archetype/stakes tags at the deliberative↔mechanical boundary (e.g.
  ADR-19, ADR-31) are debatable and would move a point or two either way.
- The audit scored documents, not implementations — an ADR can score
  `2` on Actionability (names the injection point) yet the named site may
  have since moved; the note inherits the standard "verify the named
  file/symbol still exists before acting" caveat.
- Economy judgements are the least reproducible axis (length-vs-stakes is
  inherently subjective); they are offered as signal for the SKILL's
  prompt design, not as authoritative grades.
