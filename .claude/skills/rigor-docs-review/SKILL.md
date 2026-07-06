---
name: rigor-docs-review
description: |
  Run the multi-lens review battery on Rigor's user-facing docs (docs/manual/ + docs/handbook/) as independent-context subagents, in five ordered layers: L0 mechanical (the permanent spec/docs/ gate), L1 semantic fidelity (claims vs the spec corpus / implementation / real CLI behaviour), L2 reader lenses (a Ruby-only reader with no static-typing background, procedure reproduction of the install + Rails-quickstart chapters, a Coming-from-X appendix reader), L3 bloat detection (inverted — flags fat not thin), L4 English copyedit + terminology and cross-reference hygiene. Parallel within a layer, sequential across; the LLM battery runs only when L0 is green; copyedit is always last. Records each lens to docs/notes/ and applies only necessary, axis-preserving fixes. Triggers: review the docs / manual / handbook, 査読して / 校閲して, validate a chapter before a milestone, check docs against the implementation. Not for a single typo. Software documentation, not a book — prose depth is not a virtue.
metadata:
  internal: true
---

# rigor-docs-review — user-facing docs review battery

Reviews Rigor's **user-facing documentation** — [`docs/manual/`](../../../docs/manual/README.md)
(operational reference) and [`docs/handbook/`](../../../docs/handbook/README.md) (type-model
walkthrough) — from multiple expert lenses run as **independent-context subagents**, records each to
a note, and applies **only the necessary, axis-preserving fixes**. This skill is the **methodology
freeze**; the personas are re-pointed at whatever chapter/scope each run targets.

The full design rationale (what ports from the chibirigor book battery, what drops, what inverts, why
L0 is new) is [`docs/notes/20260610-user-docs-review-battery-design.md`](../../../docs/notes/20260610-user-docs-review-battery-design.md).
Read it once; do not restate it here.

**The one load-bearing constraint:** this is **software documentation, not a book.** Prose depth is
not a virtue. A book battery *rewards* narrative richness and woven-in background; here the reference
job is correctness and necessary clarity, and background thinness is not a defect. This is why L3 is
**inverted** (a bloat detector, not a depth booster) and why no lens is allowed to recommend padding.

## When to use / not

- **Use:** a manual/handbook chapter reached a stopping point; pre-release doc pass; "does the doc
  still match the implementation?"; the user says "review the docs / 査読して / 校閲して".
- **Do NOT use:** a single-line fix or an obvious typo — the lens-launch overhead is not worth it.

## The five layers

Run order is **L0 → L1 → L2 → L3 → L4** (機械 → 真 → 伝 → 簡 → 整). A full cycle runs at milestones;
day-to-day, run only the layer in question (see "Which layer to run"). **Parallel within a layer,
sequential across** — a later layer reads the text the earlier layer's fixes already corrected,
because polishing an incorrect claim, or tidying prose a reader can't follow, is wasted work.

| Layer | Question | Form |
| --- | --- | --- |
| **L0 機械** | Do the mechanically-checkable claims match reality? | `spec/docs/` (`make docs-check`) — a permanent gate, **not** an LLM lens |
| **L1 真** | Are the semantic claims true against the spec / implementation? | LLM lens (fidelity, + a type-theory sub-lens for the type-theory appendix) |
| **L2 伝** | Does it reach its declared reader? | LLM lenses (Ruby-only reader · procedure reproduction · appendix reader) |
| **L3 簡** | Is it fat? (thinness is L2's job, not this one) | LLM lens (bloat detector, inverted) |
| **L4 整** | Is the English / terminology / cross-referencing clean? | LLM lens (copyedit — **always last**) |

### L0 機械 — the permanent gate (already built)

L0 is **not an LLM lens** — it is the `spec/docs/` harness, run with `make docs-check`:

- **`handbook_snippets_spec.rb`** — extracts ` ```ruby ` blocks carrying `assert_type` / `dump_type`,
  runs them through the analyzer, fails on `assert.type-mismatch` (a prose claim the engine no longer
  produces).
- **`manual_drift_spec.rb`** — CLI subcommands (`CLI::HANDLERS`), config keys
  (`Configuration::DEFAULTS`), rule ids (`CheckRules::ALL_RULES`), and rule `documentation_url`
  anchors (ADR-65) cross-referenced against `docs/manual/`.
- **`link_integrity_spec.rb`** — every relative markdown link in the docs resolves.

**The LLM battery runs only when L0 is green.** Start every cycle with `make docs-check`; a mechanical
failure is cheaper to fix than an LLM lens is to run, and a red L0 usually means a fix landed with a
stale doc. (Known un-covered gap: CLI *flag* drift — flags lack a clean registry, so it stays an LLM
L1 concern, not a mechanical check.)

### The common contract (pass to EVERY lens)

- **Do not break the docs' declared axes** (both READMEs state them, so hand them over as the review
  criterion, don't invent new ones):
  - **Reader:** the handbook targets a **Ruby programmer with no static-typing background**; each
    "Coming from X" appendix declares its own reader.
  - **Split:** type model → handbook, operation → manual (both READMEs cross-declare it).
  - **Handbook non-goals:** readable cover-to-cover in a few hours; edge cases belong in the spec
    corpus; it does not teach Ruby; plugin authoring belongs in `examples/`.
  - **Terminology:** bare "interface" is banned — first use is always *structural interface* or
    *RBS interface*.
  - **Spec binds:** if the handbook contradicts the [spec corpus](../../../docs/type-specification/README.md)
    on analyzer behaviour, the **handbook** is what's wrong.
- **Severity-label every finding** (ERROR / MISLEADING / FRICTION / nitpick). A few nitpicks at the
  end, not sprinkled.
- **This is software docs, not a book.** No lens may recommend adding prose for depth's sake, "more
  rigour," or narrative flourish. Reference density (tables, annotated code) is the goal.
- **Read the shipping docs only.** Do not read internal `docs/notes/` review memos as source.
- **Output:** the subagent's final message is a per-lens table (quoted location / problem / proposed
  fix) + a short overall verdict, **and** it writes the same to its note (below).

### L1 真 — semantic fidelity

- **Persona:** a reviewer who reads *both* Rigor's implementation and the docs and checks that every
  claim the L0 harness can't mechanically verify is true — cache-invalidation conditions, diagnostic
  firing conditions, severity-profile mappings ("balanced maps X to `:info`"), plugin behaviour.
  **Handbook** claims are checked against the spec corpus (spec binds); **manual** claims against the
  implementation + actual CLI behaviour. Has read access to `lib/rigor/` and may run the CLI
  (read-only). An **intentional simplification is not a fidelity gap** — flag only accidental
  inaccuracy (the doc asserts ¬X where the engine does X). Distinguish the two in the report.
- **Type-theory sub-lens** (only for `appendix-type-theory.md` and the cross-checker appendices): a
  reviewer at TAPL-teaching level checks the formal claims; honest simplifications are not faulted.
- Note: `docs/notes/YYYYMMDD-docs-review-fidelity.md`. **First cycle expectation:** L1 is expected to
  surface ADR-51 CI-format follow-through gaps in `11-ci.md` (rewritten after the last verification
  pass), and any post-v0.1.16 feature (env-resilience, provenance labels, `evidence_tier`) whose docs
  drifted.

### L2 伝 — reader lenses (three sub-lenses, parallel)

- **(a) Ruby-only reader** — the handbook's declared audience: a Ruby programmer who understands
  `String` / `Array` / `Hash` / `Data` as real classes but has **no type-declaration mental model**
  and conflates "type" with "class." Reads the handbook only (never `lib/` / `spec/`), flags where
  "type ≈ class" silently breaks (`Constant[1]`, unions, structural shapes), where type-annotation or
  static-checking is treated as already-known, and where a TypeScript/RBS example is used as
  scaffolding rather than a bonus. **Do NOT over-simplify** — the goal is finding *genuine* steps
  where a Ruby-only reader is truly stuck, not lowering the doc's level; a concept the surrounding
  text teaches is not a leap. Severity BLOCK / FRICTION / nitpick. Note: `-ruby-reader.md`.
- **(b) Procedure reproduction** — reads `docs/manual/01-installation.md` and `14-rails-quickstart.md`
  and tries to complete the procedure from the **text alone** (execution mode; may run the commands
  in a scratch dir). Reports any step that can't be completed without outside knowledge. Note:
  `-repro.md`.
- **(c) Appendix reader** — reads a "Coming from X" appendix as someone with an X background (Sorbet /
  TypeScript / Steep / RBS / mypy / Flow / …), checking the bridge from X's model lands. All nine on a
  full cycle; only the changed appendix on a targeted pass. Note: `-appendix-reader.md`.

### L3 簡 — bloat detector (inverted; flags FAT only)

- **Persona:** the harsh-critic attribute from the book battery, but re-pointed — it does **not** flag
  thin prose (that is L2's job). It flags only the fat direction:
  - **manual / handbook overlap** (the README-declared split is the criterion — the same thing
    explained in both).
  - Prose that a **table or an annotated code block** would express more precisely.
  - **Handbook non-goal violations:** content beyond "a few hours to read," content that belongs in
    the spec corpus, plugin-authoring guidance that belongs in `examples/`.
- **Axis guard:** trimming is not a licence to gut necessary reference material. The manual is a
  reference; density is correct, terseness is fine. Note: `-bloat.md`.

### L4 整 — English copyedit + convention compliance (ALWAYS LAST)

- **Persona:** a professional technical copyeditor. Checks English quality (AI-flavoured phrasing,
  passive-voice drift, hedging), the **`interface` → *structural interface* / *RBS interface*** naming
  rule (semi-mechanisable — grep bare "interface" and check first-use qualification), the
  `docs/manual` ↔ `docs/handbook` cross-reference hygiene, and link text. Does **not** re-litigate
  content (done by L1–L3). Runs last so the churn from earlier layers is copyedited once. Note:
  `-copyedit.md`.

## Launch → synthesize → apply (layer-driven)

**Default is one layer at a time.** A full cycle (L0→…→L4) is for milestones only.

1. **Pick scope:** full cycle / single layer (`L1`…`L4`) / single lens (`fidelity` / `ruby-reader` /
   `repro` / `appendix-reader` / `bloat` / `copyedit`). Name the target chapters.
2. **Gate on L0:** run `make docs-check`. Green → proceed; red → fix the mechanical drift first.
3. **Run one layer:** launch its lenses **in the same message** (Agent tool, `general-purpose`;
   `opus` default, reader lenses may use `sonnet` and 2–3 readers surface the common stumble). Each
   subagent writes its findings to `docs/notes/YYYYMMDD-docs-review-<lens>.md` (persistent ledger).
4. **Synthesize + selectively apply that layer's fixes:**
   - **Axis first. Not everything.** Prioritise ERROR / clear fidelity gaps / clear language errors.
     Judgment calls (restructuring, a new table, a big cut) are recorded for the maintainer, not
     auto-applied.
   - Apply with **`git add <individual files>`** — never `-A` (don't sweep a parallel session's WIP).
   - **Re-run `make docs-check`** after edits — a fix must not break a snippet, a link, or a rule
     anchor.
5. **Gate to the next layer** (full cycle only): later layers read the corrected text. Never reorder
   L1 → L2 → L3 → L4, and **L4 整 is always last** (copyediting text that later layers will churn is
   waste).

### Which layer to run (quick reference)

- **Wrote / changed technical content** → **L1 真** (then L2 if the change affects explanation).
- **New chapter / restructure** → **L2 伝**.
- **After a big rewrite (cut / expand)** → **L3 簡**, then once settled **L4 整**.
- **Pre-release final pass** → **L4 整** (full cycle at a milestone).
- **Single-line fix / obvious typo** → no layer (not worth the overhead).

## Notes

- **Layer-at-a-time is the default;** a full cycle is heavy — reserve it for milestones.
- **Never reorder 真 → 伝 → 簡 → 整,** and keep **L4 整 last.** Correctness → teaching → leanness →
  polish is the only order in which "fitness as a knowledge-transfer medium" accumulates.
- Findings notes live under `docs/notes/`, **never** inside `docs/manual/` or `docs/handbook/` (those
  are shipping docs).
- After authoring/editing this skill, run `waza check .claude/skills/rigor-docs-review` once (the
  CLAUDE.md convention); treat everything beyond spec-compliance as informational (ADR-81).
