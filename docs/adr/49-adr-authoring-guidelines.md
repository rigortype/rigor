# ADR-49 — ADR authoring guidelines (a rubric for necessary-and-sufficient ADRs)

Status: **Accepted — in force (living rubric), 2026-06-05.** Establishes a
shared, archetype-aware rubric for writing and scoring Rigor's ADRs. Its
purpose is operational: drive the authoring (including semi-automated
drafting) of ADRs that carry **necessary and sufficient** information —
neither thin enough to send the next implementer back to a full code
read, nor padded past what the decision's stakes justify. The rubric is a
living document; refine the axes when the corpus teaches us a new failure
mode.

Grounding: the in-repo ADR corpus itself (ADR-0 … ADR-48), scored against
this rubric in
[`docs/notes/20260605-adr-corpus-rubric-audit.md`](../notes/20260605-adr-corpus-rubric-audit.md)
(the audit that validated the rubric: its high-stakes×thin-intent alarm
correctly stayed silent, its exemptions rescued the mechanical/foundation
ADRs without false failures, and economy surfaced as the corpus's one
systematic drift). The high-water exemplars cited below —
[ADR-43](43-rbs-complete-ancestor-resolution.md),
[ADR-46](46-incremental-dependency-graph.md) — and the appropriately
concise [ADR-40](40-config-schema-defaults.md) are the calibration set.

## Context

The corpus has grown to 48 ADRs of sharply different natures. Some are
deep deliberations whose value is the reasoning — ADR-43 (the allow-list
scoping that keeps false positives at zero), ADR-45/46 (the
soundness story for the caches). Others are near-mechanical records of a
simple choice the maintainer made in passing — ADR-40 (`{kind:, default:}`
config defaults), ADR-38 (additional initializers), ADR-7 (a v0.1.0 slice
bundle). Many of the mechanical ones were drafted semi-automatically from
a one-line maintainer selection, so they neither carry nor need a
deep "intent" narrative.

We want a rubric that does two jobs: **score** an existing ADR's
information sufficiency, and **guide** the next one (a human or an agent
drafting from a prompt). The trap to avoid is a uniform checklist: applied
flat, it punishes a mechanical ADR for "missing" the deliberation it never
needed, and it has no way to flag the opposite defect — a small-stakes
decision bloated to ten screens. The goal is *proportionality*, so the
rubric must be **archetype-aware**, **stakes-weighted**, and must score
economy in **both** directions.

This sits beside the README's "Adding a New ADR" steps (the structural
contract: Status / Context / Decision / Consequences + an index entry) —
that is the *format*; this ADR is the *quality bar* layered on top.

## Decision

Score an ADR in three passes: tag its **archetype**, tag its **stakes**,
then score the **eight axes** — dropping the axes the archetype exempts
rather than scoring them zero.

### 1. Archetype tag (assign exactly one, first)

| Archetype | What it is | Corpus examples | Axis treatment |
| --- | --- | --- | --- |
| **Deliberative** | A genuine design choice with live trade-offs; the reasoning is the payload. | 43, 45, 46, 15, 35 | Full rubric. Axes 1–2 (intent, criterion) are the *core* of the score. |
| **Mechanical / policy** | A small or near-forced choice, or a standing policy record. Often drafted semi-automatically. | 40, 38, 7, 31 | Axes 1–2 score **generously** (a one-line rationale earns full marks) or are **N/A** when the choice is genuinely forced. Axis 8 (economy) weighted **up** — these must stay short. |
| **Evaluation / proposal** | Assesses an option not yet implemented (accept-conditionally / defer / reject). | 21, 30, 41, 42 | Axis 5's *evidence* sub-part is **N/A** (nothing shipped to measure); its *acceptance-criteria* sub-part still applies. |

### 2. Stakes tag (a reading modifier, **not** a scored axis)

Tag each ADR `low` / `mid` / `high` by three quick reads: **reversibility**
(how hard to undo), **blast radius** (engine-wide vs one plugin field), and
**does it touch the false-positive / soundness envelope** (the project's
top-tier discipline — see `feedback_false_positive_discipline`). Stakes do
not add to the score; they *condition how two axes are read*:

- **Intent / criterion (axes 1–2):** `high` stakes × thin intent is a
  **real gap** — the most valuable thing this rubric surfaces (a load-bearing
  decision recorded without its reasoning). `low` stakes × thin intent is
  **correct economy**, not a defect. This is exactly how we avoid
  over-penalizing the semi-automatic ADRs.
- **Economy (axis 8):** stakes set the length budget. `high` stakes earns
  ADR-46's length; `low` stakes should read like ADR-40, and the same
  length on a `low`-stakes topic is the *over*-information defect axis 8
  exists to catch.

### 3. The eight axes (score each 0 / 1 / 2, or **N/A**)

N/A is not zero: an exempted axis is **removed from the denominator** (§4).

1. **Intent & purpose.** Is the goal — *what we want and why it matters* —
   stated up front, ideally tied to a standing project value? *2*: a crisp
   motivating question/goal anchored to a value (ADR-43: "Can Rigor itself,
   Steep-free, warn on plugin-contract misuse?"). *1*: a goal stated but
   generic. *0*: jumps to mechanism with no "why now". *(deliberative-core;
   mechanical: generous/N-A)*
2. **Decision criterion.** Not just *which* option, but the **reusable rule**
   that discriminated. *2*: a generalizable criterion you could apply to a
   future case (ADR-43: "this class's RBS is authoritative and complete — a
   call it omits is genuinely a mistake," then applied to `Plugin::Base` =
   true, `ActionController::Base` = false). *1*: alternatives listed with
   per-option reasons but no general rule (ADR-40's rejected-alternatives
   table). *0*: a choice asserted with no comparison. *(deliberative-core)*
3. **Actionability & code-anchoring.** Could an implementer go straight to
   the code? *2*: named injection point with file + approx. line and the
   surrounding real symbols (ADR-43 WD2: `RbsDispatch.lookup_method`,
   `rbs_dispatch.rb` ~L270, "after the nil lookup, before fall-through";
   ADR-46: the `Scope` accessor choke point). *1*: the right files/classes
   named but no precise site. *0*: abstract mechanism only. *(all archetypes)*
4. **Constraints & guardrails.** The "don't break this" envelope: invariants
   to preserve, explicit in/out-of-scope lines, and the FP/soundness boundary.
   *2*: states the load-bearing coupling and the line not to cross (ADR-43:
   "precision and `undefined-method`-firing flow through the same path";
   ADR-46: "under-recording a dependency manufactures a false positive →
   conservative fallback, never narrow"). *1*: scope bounded but constraints
   implicit. *0*: silent on what must not break. *(all archetypes)*
5. **Verifiability & evidence.** *Acceptance criteria* (how we know it is done
   — a gate, a test, a measured-clean bar) **and** *grounding* (numbers, a
   spike-note link). *2*: both, concretely (ADR-46: `--verify-incremental`
   byte-identical gate + "262 files, 0.75s vs 7.2s, ~9.6×"; ADR-43:
   `make check-plugins` non-zero exit + the zero-net-FP measurement). *1*:
   criteria without evidence, or vice-versa. *0*: neither. *(evaluation:
   evidence sub-part N/A — score on criteria alone)*
6. **Status & progress fidelity.** Does the Status line tell the truth at
   slice granularity, and does the body match it? *2*: accurate status, what
   landed in which version, what remains (ADR-46's status block as a resume
   bookmark). *1*: coarse status, body broadly consistent. *0*: status and
   body disagree (e.g. "landed" over a body still written as a proposal).
   *(all archetypes)*
7. **Connectedness.** Cross-references that place the ADR in the design web —
   adjacent ADRs, duals, the binding spec. *2*: names neighbours and their
   relation (ADR-43 ↔ ADR-26 as inverse knobs; → ADR-24's
   `discovered_superclasses`). *1*: a bare link or two. *0*: orphaned.
   *(all archetypes)*
8. **Economy / proportionality (the goal axis — bidirectional).** Is the
   length *necessary and sufficient* for the stakes? Penalize **both**
   under-information (forces a code read) **and** over-information (ceremony,
   restated context, padding past what a `low`-stakes call warrants). *2*:
   length tracks stakes — ADR-40 is short for a small change, ADR-46 is long
   for a soundness-critical one, and both feel right. *1*: somewhat over/under.
   *0*: badly disproportionate either way. *(all archetypes; weighted up for
   mechanical)*

### 4. Scoring & the don't-over-penalize rule

Final score = `sum(scored axes) / (2 × count(scored axes))`, expressed as a
percentage. **N/A axes leave the denominator** — a mechanical ADR exempted on
axes 1–2 is scored out of 12 (six axes), not 16, so it is never dragged down
for deliberation it correctly omitted. A `high`-stakes ADR is **never**
exempted on 1–2; thin intent there counts as a real 0 and is the headline
finding.

Treat the percentage as a **conversation starter, not a gate**: its job is to
locate the one or two axes pulling an ADR down so the author can fix *those*,
not to rank the corpus. A semi-automatic ADR scoring "low" only because 1–2
are N/A is healthy, not failing.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| One uniform checklist, no archetypes | Rejected | Over-penalizes mechanical/semi-automatic ADRs for missing deliberation they never needed, and cannot flag the over-information defect. The whole point is proportionality. |
| Stakes as an independent scored axis | Rejected | Stakes are a property of the *decision*, not the *document's quality*; double-counting them distorts the score. They belong as a reading modifier on axes 1–2 and 8. |
| Absolute length limits (e.g. "≤ N words") | Rejected | Economy is proportional, not absolute — ADR-46's length is correct, ADR-40's brevity is correct. A fixed cap would punish the right long ADR and reward a hollow short one. |
| Auto-penalize any ADR lacking explicit intent | Rejected | Directly contradicts the goal: many ADRs are correctly thin. Thin intent is a defect *only* at `high` stakes (§2), which the modifier captures without a blanket penalty. |
| Fold intent into the existing "Context" expectation | Deferred | Intent (the goal/why) and Context (the problem/background) are distinct and worth scoring apart; merging them hides the most common gap in load-bearing ADRs. Revisit only if the two axes prove to move together in practice. |

## Consequences

Positive:

- A drafting agent (or a maintainer) gets a concrete target: pick the
  archetype, judge the stakes, then satisfy the axes that apply — and stop.
  This is what curbs both thin and bloated drafts.
- The N/A mechanism makes the rubric **safe to run over the whole corpus**:
  semi-automatic ADRs are not punished for being what they are, so a low score
  reliably means a real gap rather than an archetype mismatch.
- High-stakes-but-thin ADRs become findable — the single most useful audit
  output (a load-bearing decision missing its reasoning).

Negative:

- Archetype and stakes tagging is a human judgement call; two reviewers may
  tag differently at the deliberative/mechanical boundary. Mitigated by the
  worked exemplars (43/46 deliberative × `high` stakes, 40 mechanical × `low`)
  as the calibration set and tagging anchors, and by the
  score being advisory.
- Eight axes is more than a quick gut-check. For a clearly trivial mechanical
  ADR, axes 3/6/8 alone are a reasonable fast path; the full eight are for the
  deliberative cases and for corpus audits.

## Relationship to other ADRs

- **README "Adding a New ADR"** — supplies the structural contract (Status /
  Context / Decision / Consequences + index entry); this ADR is the quality
  bar on top of that format.
- **ADR-31** (contribution & supply-chain policy) — the sibling
  "policy in force" ADR; this one governs ADR-authoring the way ADR-31 governs
  contribution.
- **`feedback_false_positive_discipline`** (and ADR-43/45/46) — the
  false-positive / soundness envelope that axis 4 and the `high`-stakes tag key
  on; it is the value most worth recording an ADR's intent against.
- **AGENTS.md** — the development contract a drafting agent reads first; this
  rubric is the ADR-specific companion to it.
- **`.claude/skills/rigor-adr-author`** — the procedural wrapper that
  operationalizes this rubric: it tags archetype + stakes, picks the matching
  skeleton, and does the mechanical wiring (numbering, the two index updates,
  verification), deferring here for the quality bar rather than restating it.
