---
name: rigor-adr-author
description: |
  Author a new Architecture Decision Record under docs/adr/. Use when the user asks to "write an ADR", "record this decision as an ADR", "add ADR-N for X", or when a design discussion reaches a decision worth recording. Covers the quality bar (defers to ADR-49's rubric — archetype, stakes, eight axes) and the mechanical wiring (next number, the file, the docs/adr/README.md index row in ascending order with its capped status, whether the ADR earns a CLAUDE.md premise line at all — usually not — and verification). NOT for editing the type spec or internal-spec corpus, and NOT a substitute for reading ADR-49 — this skill is the procedure; ADR-49 is the binding quality contract.
metadata:
  internal: true
---

# Author an ADR

This skill is the **procedure** for adding an ADR. The **quality bar** is
[`docs/adr/49-adr-authoring-guidelines.md`](../../../docs/adr/49-adr-authoring-guidelines.md)
— read it; do not re-derive or restate its rubric here. The skill's job is
to route the decision to the right shape, then get the mechanical wiring
(numbering + two index updates + verification) right, which is where ADR
authoring actually slips.

The one empirical lever from the corpus audit
([`docs/notes/20260605-adr-corpus-rubric-audit.md`](../../../docs/notes/20260605-adr-corpus-rubric-audit.md)):
the corpus's only systematic drift is **over-information**, never thin.
So the recurring authoring mistake is writing too much for the stakes, not
too little. Bias toward brevity; let stakes earn length.

## Step 0 — Does this even need an ADR?

An ADR records a **decision with rationale and rejected alternatives**, or
a **standing policy**. It is not the home for:

- A mechanical change with no live alternatives (just do it; note in
  `CHANGELOG.md`).
- Behaviour the spec corpus (`docs/type-specification/`,
  `docs/internal-spec/`) should own — when a change touches type-language
  behaviour or an analyzer contract, the **spec binds**; the ADR records
  *why*, not *what*. Put the normative rule in the spec, the rationale in
  the ADR.
- A point-in-time measurement or survey — that is a `docs/notes/` note
  (which an ADR may then cite as grounding).

If the decision is real but small and forced, it can still be an ADR — see
the Mechanical archetype below. If there is no decision (no alternatives
were weighed), it is probably a note or a CHANGELOG line, not an ADR.

## Step 1 — Tag archetype + stakes (per ADR-49)

Before writing, fix the two tags ADR-49 defines. They decide which axes
you must satisfy and how long the ADR may be.

- **Archetype** — Deliberative / Mechanical-policy / Evaluation-proposal.
  This sets which axes are core vs exempt.
- **Stakes** — low / mid / high, by reversibility × blast-radius × whether
  it touches the false-positive / soundness envelope. This sets the length
  budget (Step 3) and how hard the intent/criterion axes are read.

Do not skip this. A mis-tag is the usual cause of a bloated mechanical ADR
or a thin high-stakes one.

## Step 2 — Pick the skeleton for the archetype

The repo's structural contract (from `docs/adr/README.md` § "Adding a New
ADR") is **Status / Context / Decision / Consequences**. Layer the
archetype shape on top:

### Deliberative (e.g. ADR-43, 45, 46, 26, 35)

```markdown
# ADR-N — <title>

Status: **<state>, <date>.** <one-paragraph what-landed / what-remains.>

Grounding: <links to the note(s) / spike(s) this rests on, if any>

## Context        — the problem, the gap, why now (intent lives here)
## Decision       — the decision + the discriminating CRITERION (the reusable rule)
## Working decisions (WD1…) — the load-bearing sub-choices, each with its reason
## Rejected / deferred alternatives — table or list, each with a reason
## Consequences   — positive / negative / carry-over
## Relationship to other ADRs — cross-refs
```

The two axes that make a deliberative ADR earn its keep (ADR-49 axes 1–2):
a crisp **intent** in Context, and a **decision criterion** in Decision
that is a *reusable rule* ("this class's RBS is authoritative and
complete → a call it omits is a mistake"), not merely "we picked B."

### Mechanical / policy (e.g. ADR-40, 38, 33)

Same skeleton, **shorter**. Intent may be one line (ADR-49 scores it
generously or N/A here — do not pad it). The rejected-alternatives table
still earns Criterion; keep it. **Economy is weighted up** — a small
change must read small. ADR-40 / ADR-33 are the length targets.

### Evaluation / proposal (e.g. ADR-21, 41, 30, 42)

Same skeleton, but the **Status is "Proposed"** and there is no shipped
measurement yet (ADR-49 exempts the evidence sub-part of axis 5 — survey
grounding still counts; a shipped benchmark does not exist yet). State the
**re-evaluation triggers** explicitly (these are the guardrails). Watch
economy hardest here: a "defer / demand-gate this" decision paying
full-deliberation length is the corpus's commonest over-write (audit
finding 2).

## Step 3 — Write the body, sized to the stakes

Defer to ADR-49 for *what good looks like* on each axis. The economy
discipline, concretely:

- **Length tracks stakes.** A `high`-stakes engine/FP decision earns
  ADR-46's length; a `low`/`mid` mechanical or evaluation ADR should read
  like ADR-33 / ADR-40. If a `low`-stakes or evaluation ADR is growing
  past ~ADR-33 length, that is the smell — trim or move material out.
- **Move reference tables to a linked note.** Large PHPStan/TS comparison
  tables or survey dumps belong in `docs/notes/`, cited as grounding (the
  ADR-1 / ADR-16 over-length pattern the audit flagged). Keep the ADR the
  *decision*, not the *research*.
- **The dense landed-status opening paragraph is a sanctioned trade.** A
  one-paragraph "what landed / what remains" status block (ADR-46, ADR-24)
  doubles as a resume bookmark — keep it even though it costs a little
  economy; do not trim a load-bearing status block to chase brevity.
- **Anchor to real code** where you can (file + approx. line + the
  surrounding real symbols) — this is ADR-43 WD2's `rbs_dispatch.rb ~L270`
  shape, and it is what makes an ADR implementable rather than aspirational.

## Step 4 — Mechanical wiring (where authoring slips)

Three files change together. Get the ordering right.

### 4a. The ADR file

Find the next number:

```sh
ls docs/adr/ | grep -E '^[0-9]+-' | sort -n -t- -k1 | tail -3
```

Write `docs/adr/<N>-<kebab-title>.md`.

### 4b. `docs/adr/README.md` index row — **ascending order**

The index table is ordered `ADR-0, 1, 2, …`. Insert the new row **after**
the current-highest row, **before** the `## Adding a New ADR` heading — not
before the previous row. (This ordering is the easy slip: anchor the edit
on the *last* table row + the heading, not on the previous-number row.)
Row shape: `| ADR-N | [Title](N-slug.md) | <status> |`.

The third column is headed **Status** and carries exactly that — the
README's own "How to Read" is the contract: `Accepted` / `Proposed` /
`Superseded`, plus one parenthetical for an in-flight implementation
(which WD/slice landed, what remains, a version or PR). **Cap: 200
characters**, one line, no `|`. Derive it from your ADR's own `Status:`
block so the two cannot disagree — that block is canonical (ADR-92).

Not a summary: no criteria, no rationale, no rejected alternatives, no
measurements. They are in the ADR body, and duplicating them here is what
grew this column to 5,195 characters a cell before
[ADR-97](../../../docs/adr/97-adr-index-budgets.md) capped it.

```
| ADR-40 | [`config_schema` declared defaults](40-config-schema-defaults.md) | Accepted (mechanism + 13 plugins migrated off the `DEFAULT_*` idiom) |
```

### 4c. `CLAUDE.md` — **usually nothing to do**

`CLAUDE.md` is loaded into context at the start of every session, so its
ADR list is a **premise set, not an index** ([ADR-97](../../../docs/adr/97-adr-index-budgets.md)
WD1): only the ADRs an agent would get wrong *without knowing to look
them up* — the foundation / conceptual core (ADR-0–5) and the standing
policies in force. It holds 10 entries against a cap of 12.

**Your ADR almost certainly does not belong there.** 88 of 98 do not. It
earns a line only if it is a new **standing policy** — a rule that binds
a contribution whatever it touches, not merely an important decision in
its own area. "This is significant" is not the test; "a session that
never thought to look this up will do the wrong thing" is. When in doubt,
leave it out: `docs/adr/README.md` is one hop away, and the gate will not
let you quietly spend the session budget.

If it genuinely qualifies, add `- [ADR-N](docs/adr/N-slug.md) — <topic>`
to the matching sub-list: topic only, **≤ 100 characters**, no status, no
dates, no measurements, no WD references.

The gate is `spec/docs/agent_index_spec.rb` under `make docs-check`.

(If the ADR establishes a SKILL, a release process, or anything an agent
should discover, also add/adjust the relevant `CLAUDE.md` / `AGENTS.md`
pointer — most ADRs do not need this.)

## Step 5 — Verify

```sh
git diff --check                                # whitespace
git status --short                              # expect: new ADR file + modified docs/adr/README.md
                                                # (+ CLAUDE.md only in the rare 4c case)
nix … develop --command make docs-check         # gates the index rules (ADR-97)
```

ADR authoring is docs-only, so `make verify` is not required for the ADR
itself. If the ADR lands *alongside* an implementation slice, that slice
follows the normal `make verify` protocol (AGENTS.md) — but the ADR text
does not gate on it.

Do **not** run `bundle exec rake release` or commit unless the user asks
(per CLAUDE.md). Per-slice commits are pre-authorized in this repo; a new
ADR is a reasonable single commit (`Add ADR-N — <title>` or, if it lands
with code, fold it into that slice's commit).

## Quick checklist

- Step 0 cleared: this is a decision/policy, not a CHANGELOG line, a spec
  rule, or a note.
- Archetype + stakes tagged; skeleton chosen to match.
- Intent (Context) and decision criterion (Decision) are present and
  crisp for a deliberative ADR; not padded for a mechanical one.
- Rejected/deferred alternatives recorded with reasons.
- **Length is proportional to stakes** — reference dumps moved to a note;
  not over-written for a low-stakes / evaluation decision.
- `docs/adr/README.md` row inserted in **ascending** position (after the
  last row, before `## Adding a New ADR`) — status only, ≤ 200 chars,
  derived from your ADR's own `Status:` block (ADR-97).
- `CLAUDE.md` — confirmed the ADR is a *lookup*, so no line added (the
  normal case); or it is a new standing policy and earns one (ADR-97).
- `make docs-check` green — it gates both lists.
- `git diff --check` clean; `git status` shows exactly the expected
  entries (normally two: the ADR file + `docs/adr/README.md`).
- Quality re-read against [ADR-49](../../../docs/adr/49-adr-authoring-guidelines.md):
  which one or two axes drag, and is that drag archetype-correct (fine) or
  a real gap (fix)?
