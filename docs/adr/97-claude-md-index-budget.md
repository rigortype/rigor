# ADR-97 — CLAUDE.md as an index: the unconditional-load budget and its gate

Status: **Accepted, 2026-07-17 — implemented.** The `CLAUDE.md` ADR list is
compressed back to one index line per ADR (the file: 134,688 → 25,103 bytes;
the list itself: 120,260 → 11,033); the density's one real consumer
(`rigor-prior-art`) is repointed at
`docs/adr/README.md`; the `rigor-adr-author` § 4c density instruction is
replaced by an absolute cap; and a new `spec/docs/agent_index_spec.rb` gates
that cap under the existing `make docs-check`.

Grounding: the measurement in § Context, and commit `db8d01bf` (2026-05-29,
"Compress CLAUDE.md and tidy AGENTS.md") — the same audit, the same fix, and
the regression that motivates the gate.

## Context

`CLAUDE.md` is loaded into context at the start of every session. On
2026-07-17 it measured **134,688 bytes (~34k tokens), of which the ADR bullet
list was 120,260 — 89%**. The file's own header calls it "a navigation index
that points at the documents an agent typically needs", and the ADR section's
own preamble already names `docs/adr/README.md` as "**The canonical index**".
The bullets contradicted both.

**This audit already happened.** `db8d01bf` found the same defect in nearly
these words — "CLAUDE.md calls itself a navigation index but had grown a
40-row ADR table whose cells transcribed each ADR's full working-decision
detail — duplicating the ADR files and the now-canonical docs/adr/README.md
status index. Since the file is loaded into context every session, that
duplication is pure token cost" — and applied this ADR's fix, 69,380 →
15,542 bytes. In the seven weeks since, it regrew to **8.7× the compressed
size and 1.9× the size that triggered the compression**.

The regrowth is entirely new-ADR:

| ADR range | bullets | avg bytes/bullet | total |
| --- | --- | --- | --- |
| ADR-0 … ADR-39 | 40 | 116 | 4,631 |
| ADR-40 … ADR-96 | 57 | 2,029 | 115,629 |

ADR-0 … ADR-39 still carry `db8d01bf`'s one-line form verbatim. Existing
entries did not fatten; **every ADR authored after the compression entered at
the new density**. The mean bullet went 94 → 1,239 bytes; the largest (ADR-82)
is 6,587 — longer than some ADRs' own summaries.

Two mechanisms drove it, and neither is a discipline failure:

1. **`rigor-adr-author` § 4c** instructed: "Keep the one-liner consistent in
   density with its neighbours." With no absolute reference, *consistent with
   neighbours* is a ratchet — each ADR matches the current (higher) density and
   raises the bar for the next.
2. **`rigor-prior-art`** (`SKILL.md:39`) listed the `CLAUDE.md` bullets as its
   corpus-map **"First stop. Often answers the question without opening a
   single file."** The density had a real consumer, so supplying it was
   rational.

Duplication itself is well-policed and is *not* the problem: across the last
400 commits touching either file, only **2** changed a `CLAUDE.md` ADR bullet
without also touching `docs/adr/README.md`, and the two lists carry the same 97
ADRs with identical slugs. The cost is ~34k tokens per session, plus a second
dense summary to write per ADR.

## Working decision

The criterion has two parts.

**1. An unconditionally-loaded document carries only what a session cannot
start without; everything else is a pointer.** `CLAUDE.md` is loaded before the
task is known, so every session pays for its content regardless of relevance.
Content whose value is *conditional* — the per-ADR detail the rare session
touching ADR-82 wants — belongs behind a pointer however valuable it is when it
is needed. `docs/adr/README.md` is read on demand and already holds that
detail.

**2. An economy rule with no mechanical gate is a temporary state, not a
decision.** `db8d01bf` is the evidence: an identical, correct, well-argued
compression, applied by hand and left to instruction, regressed 8.7× in seven
weeks. The gate is therefore part of this decision, not a follow-up to it.

### WD1 — the list is index-only, capped

Each entry is `- [ADR-N](docs/adr/N-slug.md) — <topic>`: one line, **topic ≤ 100
characters**, no status, no dates, no measurements, no WD references. The topic
answers only *does a decision about this exist, and on what subject* — the
reader then opens `docs/adr/README.md` for status or the ADR for detail. 97
entries ≈ 11 KB.

### WD2 — the density's consumer is repointed, not dropped

`rigor-prior-art`'s corpus map moves its first stop from the `CLAUDE.md`
bullets to `docs/adr/README.md`'s status column — which holds the same dense
per-ADR paragraph and is what the skill actually wanted. The capability
survives; only its cost moves from unconditional to on-demand. **Skipping this
step is what would make the compression regress**: a consumer left pointing at
a supply that no longer exists re-grows it.

### WD3 — the cap is gated, not instructed

`spec/docs/agent_index_spec.rb`, under the existing `make docs-check` target,
asserts that every `CLAUDE.md` ADR bullet is one line with a ≤ 100-character
topic, and that the list's ADR set matches `docs/adr/README.md`'s. §4c's
density instruction is replaced by the cap plus a pointer here. The gate is the
load-bearing half: § 4c is what a *conforming* author reads; the gate is what
catches the author who does not.

### WD4 — `docs/adr/README.md` keeps the detail; its own economy is out of scope

The README is 135,875 bytes and its longest status cell (ADR-82) is 5,195. That
is over-written for an index — but it is read on demand, so it does not pay the
per-session cost this ADR is about. Trimming it is a separate question against
a different criterion; do not fold it in here.

### Why the cap is absolute here, and proportional in ADR-49

[ADR-49](49-adr-authoring-guidelines.md) rejected absolute length limits — "Economy
is proportional, not absolute — ADR-46's length is correct, ADR-40's brevity is
correct." That governs ADR **bodies**, whose payload varies with stakes, so
whose budget must too. An **index entry's** payload does not vary: every entry
does the identical job whatever the ADR's stakes. A high-stakes ADR earns a
longer body, not a longer index line. The axis ADR-49 keeps proportional is
precisely the axis an index does not have.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep the dense bullets | Rejected | ~34k tokens every session for content the session almost never needs, and the same paragraph already exists in `docs/adr/README.md`. This is the state the ADR exists to end. |
| Drop the ADR list from `CLAUDE.md` entirely; keep only the pointer | Rejected | The list's residual job is **discovery** — an agent scanning `CLAUDE.md` learns a decision about X exists without a file read, whereas a bare pointer only helps an agent already suspecting one. ~11 KB buys that; `db8d01bf` made the same call and discovery value is not what regressed. |
| Compress by instruction only (i.e. repeat `db8d01bf`) | Rejected | Measured to fail: `db8d01bf` did exactly this and regressed 8.7× in seven weeks. Criterion 2. |
| Cap the section's total bytes rather than the per-entry topic | Rejected | The section grows linearly and *legitimately* with the ADR count; a total cap would fail on the 130th ADR for the right reason and force an unrelated fight. The per-entry cap is what holds density constant. |
| Move the CLAUDE.md detail into `docs/adr/README.md` | Rejected (no-op) | It is already there — 97 rows, identical slugs, independently worded. Nothing to move: the `CLAUDE.md` copy is redundant, not unique. |
| Trim `docs/adr/README.md`'s status cells in the same change | Deferred | WD4 — it is read on demand, so it does not pay this ADR's cost. Worth a separate look (ADR-82's cell is 5,195 bytes) against an index-economy criterion, not a context-budget one. |

## Consequences

Positive:

- `CLAUDE.md` 134,688 → 25,103 bytes (the ADR list: 120,260 → 11,033); ~27k
  tokens returned to every session, for content the overwhelming majority of
  sessions never consult. The residual 14 KB is the spec/skills navigation
  tables, which are the file's actual job.
- Per-ADR authoring drops one dense summary. The ADR body and the
  `docs/adr/README.md` row remain; the `CLAUDE.md` entry becomes a mechanical
  one-liner derivable from the canonical title.
- The next regression is a failing `make docs-check`, not a silent 8.7× drift
  found by an audit seven weeks later.

Negative:

- An agent that previously answered "did we evaluate X?" from `CLAUDE.md` alone
  now reads `docs/adr/README.md` first — one extra file read on the rare
  corpus-archaeology session. `rigor-prior-art` routes it (WD2); the trade is
  deliberate.
- The cap is a number, and a number invites lawyering. 100 is the longest
  canonical ADR title today, not a derived optimum. If a title genuinely needs
  more, move the cap **here**, not per-entry.

Carry-over: `docs/adr/README.md`'s own economy (WD4).

## Relationship to other ADRs

- **[ADR-49](49-adr-authoring-guidelines.md)** — the ADR-*body* quality rubric.
  This ADR governs the *index entry*, where economy is absolute rather than
  proportional (§ "Why the cap is absolute here"). ADR-49's rejected
  absolute-length row is about bodies and stands unchanged.
- **[ADR-81](81-skill-set-optimization.md)** — the sibling docs-economy
  decision: a distributed skill freezes only version-stable scaffold and fetches
  version-coupled detail live. Same shape, different surface — keep the
  always-loaded copy thin and resolve detail at the point of need. ADR-81
  applied it to the distributed *skill* body; this applies it to the
  always-loaded *repo* context.
- **[ADR-92](92-normative-status-fidelity.md)** — the sibling *the gate is the
  decision* record: it added the doc → impl axis to `manual_drift_spec.rb`
  because every existing docs axis ran impl → doc, so a never-implemented clause
  was invisible by construction. WD3 adds an axis to the same `make docs-check`
  harness for the same reason — an unenforced doc rule is not observably true.
- **[ADR-95](95-homebrew-tap-deferral.md)** — its criterion that "an unrecorded
  non-decision is re-researched every time it is raised" has a sharper variant
  here: an unrecorded *decision* is **reversed** every time. `db8d01bf`
  compressed `CLAUDE.md` without recording why, so the next 57 ADRs had nothing
  to conform to.
- **`.claude/skills/rigor-adr-author`** — § 4c carried the ratchet this ADR
  removes; the skill now states the cap and defers here.
- **`.claude/skills/rigor-prior-art`** — the density's consumer, repointed by
  WD2.
- **`AGENTS.md`** — its "where the state lives" paragraph pointed at `CLAUDE.md`
  § "Architecture decision records" for the ADR index; corrected to
  `docs/adr/README.md`, which the `CLAUDE.md` section itself already named
  canonical.
