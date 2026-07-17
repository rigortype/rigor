# ADR-97 — Index entries are not summaries: the ADR-index budgets and their gate

Status: **Accepted, 2026-07-17 — implemented.** `CLAUDE.md`'s ADR list becomes a
**premise set** — the foundation / conceptual core plus the standing policies, 10
entries against a cap of 12, everything else reached via the README (file:
134,688 → 16,082 bytes). `docs/adr/README.md` stays the complete index and its
status column is restored to a ≤ 200-character status (141,169 → 17,061), with
five long-standing blank rows that had been silently breaking the table's
markdown rendering removed. `rigor-prior-art` is repointed at the ADR bodies, the
`rigor-adr-author` density instruction is replaced by the membership rule + caps,
and `spec/docs/agent_index_spec.rb` gates all of it under the existing
`make docs-check`.

Grounding: the measurements in § Context; commit `db8d01bf` (2026-05-29,
"Compress CLAUDE.md and tidy AGENTS.md") — the same audit, the same fix, and the
regression that motivates the gate; and the eight-ADR sample adjudication of the
README's status cells recorded in § Context.

## Context

Rigor keeps two ADR indexes, and both had stopped being indexes.

**`CLAUDE.md`** is loaded into context at the start of every session. On
2026-07-17 it measured **134,688 bytes (~34k tokens), of which the ADR bullet
list was 120,260 — 89%**. The file's own header calls it "a navigation index
that points at the documents an agent typically needs", and the ADR section's
preamble already named `docs/adr/README.md` "**The canonical index**". The
bullets contradicted both.

**`docs/adr/README.md`** measured **141,169 bytes across 98 rows**, its status
cells averaging 1,420 characters and peaking at 5,195 (ADR-82). That column is
headed **Status**, and the README's own "How to Read" declares its contract:

> Each ADR has a **Status** field: `Accepted`, `Proposed`, or `Superseded`.
> Accepted ADRs whose implementation is still in flight carry a parenthetical
> note (e.g. *partially implemented*, *slice N deferred*).

So in both files the declared contract was already right. Only the entries drifted.

The README's table had also accumulated **five blank lines between its rows**. A
blank line ends a markdown table, so the index rendered as six separate tables,
each promoting the next ADR row to a header. This had been true on `master` for
some time and nobody saw it — when every cell is a thousand-character essay, no
one reads the table rendered. It became obvious within minutes of the cells
getting short. An unenforced formatting rule is not observably true either, which
is criterion 2 arriving from a second direction.

**The same audit already happened once.** `db8d01bf` found the `CLAUDE.md`
defect in nearly these words — "CLAUDE.md calls itself a navigation index but had
grown a 40-row ADR table whose cells transcribed each ADR's full working-decision
detail — duplicating the ADR files and the now-canonical docs/adr/README.md
status index. Since the file is loaded into context every session, that
duplication is pure token cost" — and applied this ADR's fix, 69,380 → 15,542
bytes. In the seven weeks since, it regrew to **8.7× the compressed size and 1.9×
the size that triggered the compression**.

**One ratchet hit both files, at the same ADR number.** Per-entry size by ADR:

| ADR range | CLAUDE.md bullet | README status cell |
| --- | --- | --- |
| ADR-0 … ADR-39 | 116 bytes avg | 19 chars median |
| ADR-40 … ADR-96 | 2,029 bytes avg | 585 → 3,089 chars avg, rising by decade |

Both files' pre-ADR-40 entries are still compliant, verbatim. Existing entries
did not fatten — **every ADR authored after ADR-40 entered at the then-current
density, in both indexes.** Two mechanisms drove it, neither a discipline failure:

1. **`rigor-adr-author` § 4c** instructed: "Keep the one-liner consistent in
   density with its neighbours." With no absolute reference, *consistent with
   neighbours* is a ratchet — each ADR matches the current, higher density and
   raises the bar for the next.
2. **`rigor-prior-art`** (`SKILL.md:39`) listed the `CLAUDE.md` bullets as its
   corpus-map **"First stop. Often answers the question without opening a single
   file."** The density had a real consumer, so supplying it was rational.

**The dense cells are restatements, and they had already begun to drift.** An
eight-ADR sample (82, 96, 73, 50, 56, 52, 89, 49), each adjudicated by reading the
cell against the full ADR body: **six are pure RESTATEMENT** and the other two
(89, 49) hold exactly one unique fragment each — a wall-time claim whose home is
the grounding note, and a stakes tag. Both were migrated into their ADR bodies
before compression, so no information is lost. Meanwhile the cells were *already*
wrong in the other direction: ADR-48's said `Struct` was deferred when its body
records slices 1–3 landed; ADR-73's dropped two dated amendments its body carries,
so a cell-only reader would never learn `rigor skill --full` exists. A
hand-maintained second copy of canonical content does not stay a copy.

Duplication is otherwise well-policed and is *not* the defect: only **2** of the
last 400 commits changed a `CLAUDE.md` bullet without also touching the README,
and both indexes carry the same 97 ADRs at identical slugs. The cost is ~34k
tokens per session, ~128 KB of restatement, and two dense summaries to write per
ADR on top of the ADR itself.

## Working decision

The criterion has two parts.

**1. An index entry's payload does not vary with the indexed document, so an
index entry has a fixed budget.** Every entry does the identical job whatever the
ADR's stakes: name the subject (`CLAUDE.md`) or report whether it is live
(`docs/adr/README.md`). A high-stakes ADR earns a longer *body*, never a longer
index line. What each index may spend follows from its job and its reader, not
from its neighbours.

**2. An economy rule with no mechanical gate is a temporary state, not a
decision.** `db8d01bf` is the evidence: an identical, correct, well-argued
compression, applied by hand and left to instruction, regressed 8.7× in seven
weeks — while the same ratchet quietly did the same thing to the README. The gate
is part of this decision, not a follow-up to it.

### WD1 — `CLAUDE.md`: a premise set, not an index

`CLAUDE.md` is loaded **unconditionally**, before the task is known, so it does
not get an index at all. It lists only the ADRs an agent would get wrong
*without knowing to look them up* — two classes:

- **Foundation and conceptual core** (ADR-0–5): what Rigor is. The README's own
  "How to Read" already draws this line — ADR-0 the foundation, ADR-1–3 the
  conceptual core, "higher-numbered ADRs build on the foundation and **can be
  read as needed**."
- **Standing policies in force** (ADR-31, 49, 50, 97): rules that bind a
  contribution whatever it touches.

Everything else — 88 of 98 — is a **lookup**: it matters only to a session
already in its area, and that session finds it in `docs/adr/README.md`, one hop
away. The discriminating question is not "is this ADR important?" but "will a
session that never thought to look it up do the wrong thing?" ADR-5's
robustness principle silently governs every type anyone authors here; ADR-93's
rbs-inline default flips govern only a session already editing rbs-inline
ingestion.

Each entry is `- [ADR-N](docs/adr/N-slug.md) — <topic>`: one line, **≤ 100
characters**, no status, no dates, no measurements, no WD references. 10 entries
≈ 1.3 KB, **capped at 12**.

The cap matters more than its value. It means a new ADR normally adds *nothing*
here, and an eleventh premise costs a deliberate argument — which is a stronger
ratchet-stopper than a per-entry budget, because it removes the default of
"append mine too."

### WD2 — `docs/adr/README.md`: status-only, ≤ 200-character status

Restore the column its own "How to Read" already specifies: `Accepted` /
`Proposed` / `Superseded` plus a parenthetical for in-flight implementation
(which WD/slice landed, what remains, a version or PR). 200 characters fits the
longest legitimate case with room to spare; the pre-ADR-40 rows median 19. The
criteria, rationale, rejected alternatives, code anchors and measurements stay in
the ADR body, which is canonical and was already carrying all of them. The cell is
**derived from the body's Status block**, so the README stops being a second place
where status can rot.

This index gets the looser budget because its reader is different: it is read on
demand, by someone already looking for an ADR, and the extra ~100 characters buy
the *shortlisting* power that makes a fetch unnecessary.

### WD3 — the density's consumer points at the bodies, not at a cache

`rigor-prior-art`'s corpus map moves its first stop from the `CLAUDE.md` bullets
to `docs/adr/README.md` (title + status, for shortlisting) and then to the ADR
bodies (for substance). This costs the skill little: its actual method is
ripgrep over `docs/adr/*.md`, and the index's job in that method is to shortlist
2–5 candidates, which title + status does. What it gives up is the "answers
without opening a file" property — which was only ever a cache of the bodies, and
one already proven to drift (ADR-48, ADR-73). Repointing the consumer is what
keeps the compression from regrowing: a consumer left pointing at a vanished
supply re-grows it.

### WD4 — both caps are gated, not instructed

`spec/docs/agent_index_spec.rb`, under the existing `make docs-check` target,
asserts the `CLAUDE.md` premise cap and topic cap, that no status leaks into a
premise topic, that every premise names a real ADR, the README status cap, that
each status cell opens with a declared status word, that the README indexes every
ADR file on disk, that **its table stays contiguous** (the blank-row rendering
break above), and that both lists are ascending. The skill's density instruction
is replaced by the membership rule plus a pointer here. The gate is the
load-bearing half: the skill is what a *conforming* author reads; the gate is
what catches the author who does not.

The gate's progress-vocabulary check is deliberately **narrow** — "deferred" /
"rejected" / "proposed" are not progress markers, because for an evaluation ADR
the deferral or rejection *is* the decision (ADR-95's title is "Homebrew
distribution: deferred behind the single binary"; ADR-86's ends "(rejected;
rigor-rs owns native speed)"). A gate that fires on a correct entry teaches
authors to route around it, which is the project's standing false-positive
discipline applied to a docs gate.

### Why the caps are absolute here, and proportional in ADR-49

[ADR-49](49-adr-authoring-guidelines.md) rejected absolute length limits —
"Economy is proportional, not absolute — ADR-46's length is correct, ADR-40's
brevity is correct." That governs ADR **bodies**, whose payload varies with
stakes, so whose budget must too. It does not reach index entries, for the reason
criterion 1 gives: their payload does not vary. The axis ADR-49 keeps
proportional is precisely the axis an index does not have.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep the dense entries | Rejected | ~34k tokens every session plus ~128 KB of restatement, for content the ADR bodies already carry — and the copies had begun to contradict the bodies (ADR-48, ADR-73). This is the state the ADR exists to end. |
| Keep all 98 in `CLAUDE.md`, capped at 100 characters each (~11 KB) | Rejected | The first cut of this ADR did exactly that, and it is what `db8d01bf` restored in 2026-05. It answers the token question but not the premise question: a flat list asserts every ADR is equally worth a session's attention, when 88 of them are lookups a session reaches only if it is already in their area. The discovery it buys for ADR-93 is not worth what every session pays for it; the discovery it buys for ADR-5 is. Hence WD1's two classes. |
| Drop the `CLAUDE.md` list entirely; keep only the pointer | Rejected | Discovery is real but only for the premises: a bare pointer helps an agent that already suspects an ADR exists, which is exactly the agent that does *not* need ADR-5 pointed out. ~1.3 KB keeps the unprompted cases; the lookups lose nothing, since finding them was always a `docs/adr/README.md` hop. |
| Compress by instruction only (i.e. repeat `db8d01bf`) | Rejected | Measured to fail: `db8d01bf` did exactly this and regressed 8.7× in seven weeks. Criterion 2. |
| Keep a one-sentence decision summary in the README status column | Rejected | The Title column already names the subject and the body already holds the decision, so the sentence's marginal shortlisting value is small — while "one sentence" is precisely the seed that grew the 5,195-character cell. Considered and declined by the maintainer at ~30 KB vs ~17 KB. |
| Cap each section's total bytes rather than the per-entry payload | Rejected | Both indexes grow linearly and *legitimately* with the ADR count; a total cap would fail on the 130th ADR for the right reason and force an unrelated fight. The per-entry cap is what holds density constant. |
| Delete the README's dense cells without migrating first | Rejected | The sample adjudication found two fragments (ADR-89's S1 wall claim, ADR-49's calibration stakes tags) that existed only in the cell. They were moved into their bodies first, which is what makes the compression lossless rather than merely smaller. |
| Trim the ADR bodies too | Deferred | Out of scope and governed by a different rule: [ADR-49](49-adr-authoring-guidelines.md) already owns body economy, proportionally to stakes. Its corpus audit found over-information to be the corpus's one systematic drift, so this is worth a pass — but as an ADR-49 exercise, not an index-budget one. |

## Consequences

Positive:

- `CLAUDE.md` 134,688 → 16,082 bytes (ADR list: 120,260 → ~1,300); ~30k tokens
  returned to every session. The residual ~14 KB is the spec/skills navigation
  tables, which are the file's actual job.
- `docs/adr/README.md` 141,169 → 17,061 bytes (8.3×), its table renders again,
  and its status column is now derived from each ADR's own Status block — so the
  ADR-48 / ADR-73 class of staleness has one fewer place to live.
- Per-ADR authoring drops two dense summaries. The ADR body remains; both index
  entries become mechanical and derivable (the topic from the title, the status
  from the body's Status block).
- The next regression is a failing `make docs-check`, not a silent 8.7× drift
  found by an audit seven weeks later.

Negative:

- A corpus-archaeology session that previously answered "did we evaluate X?" from
  an index alone now opens 2–5 ADR bodies. `rigor-prior-art` routes it (WD3), the
  bodies are canonical rather than a drifting cache, and the trade is deliberate.
- The premise set is a judgement call with a hard edge. ADR-27 (distribution
  model) and ADR-63 (protection coverage) are arguable eleventh entries; the rule
  ("would a session that never looked it up go wrong?") decides them out, but
  another reader could decide otherwise. That argument is the cap working, not
  failing — it just has to happen here rather than in a drive-by append.
- Three numbers invite lawyering. 100 is the longest canonical ADR title today;
  200 is headroom over the longest legitimate status; 12 is two above the current
  premise count. None is a derived optimum. If an entry genuinely needs more,
  move the number **here**, not per-entry.
- The 58 rewritten status cells are a hand pass over prose. The gate checks their
  shape, not their truth; `make docs-check` cannot tell you a status is wrong,
  only that it is short and well-formed.

## Relationship to other ADRs

- **[ADR-49](49-adr-authoring-guidelines.md)** — the ADR-*body* quality rubric.
  This ADR governs *index entries*, where economy is absolute rather than
  proportional (§ "Why the caps are absolute here"). ADR-49's rejected
  absolute-length row is about bodies and stands unchanged; its deferred sibling
  here is the body-economy pass.
- **[ADR-81](81-skill-set-optimization.md)** — the sibling docs-economy decision:
  a distributed skill freezes only version-stable scaffold and fetches
  version-coupled detail live. Same shape, different surface — keep the
  always-loaded copy thin and resolve detail at the point of need.
- **[ADR-92](92-normative-status-fidelity.md)** — the sibling *the gate is the
  decision* record, and the reason WD2 derives the cell from the body: status
  fidelity lives in the ADR. ADR-92 added the doc → impl axis to
  `manual_drift_spec.rb` because every existing docs axis ran impl → doc, so a
  never-implemented clause was invisible by construction. WD4 adds axes to the
  same `make docs-check` harness for the same reason — an unenforced doc rule is
  not observably true.
- **[ADR-95](95-homebrew-tap-deferral.md)** — its criterion that "an unrecorded
  non-decision is re-researched every time it is raised" has a sharper variant
  here: an unrecorded *decision* is **reversed** every time. `db8d01bf` compressed
  `CLAUDE.md` without recording why, so the next 57 ADRs had nothing to conform
  to. (ADR-95 and ADR-86 are also the gate's false-positive anchors — WD4.)
- **`.claude/skills/rigor-adr-author`** — § 4c carried the ratchet this ADR
  removes; the skill now states both caps and defers here.
- **`.claude/skills/rigor-prior-art`** — the density's consumer, repointed by WD3.
- **`AGENTS.md`** — its "where the state lives" paragraph pointed at `CLAUDE.md`
  § "Architecture decision records" for the ADR index; corrected to
  `docs/adr/README.md`, which the `CLAUDE.md` section itself already named
  canonical.
