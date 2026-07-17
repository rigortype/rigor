# ADR-98 — Development-flow document roles: handoff, issues, changelog

Status: **Accepted, 2026-07-17 — implemented.** The backlog moves to GitHub Issues
(45 issues migrated after per-item adjudication, triage vocabulary + `area:*`
labels created, `v0.3.0` / `v1.0.0` Milestones opened); `docs/ROADMAP.md` is
**deleted**; `docs/CURRENT_WORK.md` becomes a full-replace session handoff
(75,344 → ~4,100 bytes over the day, two rewrites); `CHANGELOG.md` is unchanged.
The engineering-skills configuration lands under `docs/agents/` with a root
`CONTEXT.md` glossary. Gated in `spec/docs/agent_index_spec.rb` under
`make docs-check`.

Grounding: the same-day autopsies of both files (below), and
[ADR-97](97-adr-index-budgets.md)'s two criteria, which this ADR extends from
index entries to the flow documents themselves.

## Context

Three documents claimed to carry the project's working state, and each had
drifted from its declared intent:

- **`docs/ROADMAP.md`** (103,270 bytes) began life as `MILESTONE.md` — a TODO
  list, never intended as a user-facing commitment surface. By 2026-07-17,
  **seven of its section headings declared themselves SHIPPED / COMPLETE /
  REMOVED**, its "Released milestones (pointers only)" section was 13 KB of
  restated CHANGELOG, and its release-strategy prose restated ADR-50, which is
  normative for it. Adjudicating its items for migration found the drift ran
  deeper than headings: items presented as open — LRU cache eviction,
  coverage-tractability labels, fork-based parallelism, the `ruby.wasm`
  playground — had shipped months earlier.
- **`docs/CURRENT_WORK.md`** intends to be a next-session handoff whose content
  turns over in days. It had become a 75 KB append-only log, and — the sharper
  failure — carried **unverified claims at its highest-priority positions**: its
  2026-07-17 #1 item ("a live bug, do this first") was refuted by its own repro
  (guarded since 2026-05-01), and an "open" AR-lambda item had been fixed since
  2026-05-28 (`fde760a2`).
- **`CHANGELOG.md`** is the one surface whose role was already right: a
  user-facing summary of user-affecting changes, with the git log as the
  detail. It needed no change — which is itself evidence for the criterion: it
  is the only one of the three with a **maintained boundary** (Keep a
  Changelog + the release-prep seal).

## Working decision

**A work item is issue-shaped, not document-shaped.** A backlog entry needs a
state machine (open → triaged → in-progress → closed), an owner, labels,
cross-links, and closure-on-merge. A tracked markdown file has none of those,
so completed items are never evicted — they *accumulate*, and the file decays
into an archive that must be re-adjudicated wholesale (this migration is that
re-adjudication; ~40% of "open" items were not). Conversely, a **handoff** is
document-shaped: it has exactly one reader (the next session), no state beyond
"current", and a natural full-replace lifecycle.

So each surface gets the shape of its content:

### WD1 — GitHub Issues are the backlog; Milestones are release planning

Every mid/long-term work item is an issue carrying one `area:*` label and one
triage label (the five canonical roles — `needs-triage` / `needs-info` /
`ready-for-agent` / `ready-for-human` / `wontfix`). "What the next cut carries"
is expressed by assigning issues to the `v0.3.0` / `v1.0.0` Milestones, the
direct successor of the file's `MILESTONE.md` heritage. Conventions:
[`docs/agents/issue-tracker.md`](../agents/issue-tracker.md). External PRs are
a triage surface (public development makes a PR a feature request with code
attached).

The migration was **adjudicated, not transcribed**: four independent passes
classified every ROADMAP / CURRENT_WORK item live / shipped / stale against
code, ADR status blocks, and git history before drafting; 45 issues came out
the other side, and the shipped-but-listed items were dropped with evidence.

### WD2 — `CURRENT_WORK.md` is a session handoff, nothing else

It answers one question — *what should the next session do?* — and is replaced
wholesale when work crosses the finish line. Anything that would outlive two
sessions has a different home: backlog → an issue, operational pitfalls → the
workflow's skill, decisions → an ADR, measurements → `docs/notes/`, shipped →
`CHANGELOG.md`. **Verify a claim before carrying it forward** — the file's two
refuted items are ADR-92's disease (unshipped behaviour stated in the present
tense) in a bookmark: *unverified state asserted as current*.

### WD3 — `CHANGELOG.md` is unchanged

User-facing summaries of user-affecting changes; details live in the git log.
Already correct; recorded here only so the three-way split is complete.

### WD4 — the gates

Per ADR-97 criterion 2 (an economy rule with no mechanical gate is a temporary
state), `spec/docs/agent_index_spec.rb` grows two axes: `docs/ROADMAP.md` does
not exist (its recreation is the regression this ADR exists to prevent), and
`docs/CURRENT_WORK.md` stays within a 120-line cap (a handoff that needs more
is carrying someone else's content; today's is 62).

Pre-dissolution citations of "ROADMAP § …" in frozen records (ADR bodies,
`docs/notes/`, sealed CHANGELOG sections, code provenance comments) stay as
**historical citations** — they describe where an item lived when written and
resolve via git history. Live markdown links were rewired or de-linked so
`make docs-check`'s link gate stays green.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep `ROADMAP.md` as a thin pointer stub | Rejected | A stub is a regrowth surface — the next "just one queued item" lands in the file because it is there, and the cycle restarts. The pointer's job is done by `AGENTS.md` § "Where the Current State Lives" + the gate. |
| Migrate without adjudication | Rejected | Would have created issues for shipped work — the passes found LRU eviction, tractability labels, fork parallelism, and the wasm playground all listed as open. An issue tracker seeded with dead items teaches people to ignore it on day one. |
| Local-markdown issue tracker (`.scratch/`) | Rejected | The repo develops in public on GitHub with `gh` already in every workflow; a parallel local tracker splits the backlog across two homes, which is the disease being cured. |
| Keep a medium-term section in `CURRENT_WORK.md` | Rejected | That section is where this file's rot lived — "Open engineering items" held a COMPLETE item duplicating a ROADMAP entry that was also marked COMPLETE. Two homes for the same backlog guarantees divergence. |
| Fold this into ADR-97 | Rejected | ADR-97 governs index-entry budgets inside documents; this governs which documents exist and what each carries. Same discipline, different object — and ADR-97 is already implemented and gated as-is. |

## Consequences

Positive:

- Each kind of knowledge has exactly one home keyed to its lifetime, and the
  backlog finally has a state machine — items close on merge instead of
  waiting for a wholesale file audit.
- The handoff is small enough to actually be read at session start, and its
  header carries the verify-before-carry-forward rule with the two refutations
  as evidence.
- The engineering skills (`/triage`, `to-issues`, `qa`, …) become usable here:
  their configuration is scaffolded and the label vocabulary exists.
- The next regression — a recreated ROADMAP, a handoff growing a backlog — is
  a failing `make docs-check`.

Negative:

- The backlog leaves the repository: issues are not versioned in git and need
  network access. Mitigated by self-contained issue bodies (each cites its
  repo paths and gates) and by `gh` being a standing dependency anyway.
- 45 open issues impose triage hygiene that a markdown file never demanded;
  stale issues are now visible debt. That visibility is the point, but it is
  work.
- Historical "ROADMAP §" citations in frozen records now reference a deleted
  file. Accepted: they are citations of a past state, resolvable via git
  history, and rewriting frozen records is out of bounds (ADR-92).

## Relationship to other ADRs

- **[ADR-97](97-adr-index-budgets.md)** — the sibling decision, one week
  apart: ADR-97 fixed what index *entries* may carry; this fixes what the flow
  *documents* may carry. Both rest on the same two criteria (fixed budgets for
  fixed jobs; gates over instructions), share the same spec file, and this ADR
  joins it in the `AGENTS.md` standing-policy premise list.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — owns the
  release strategy normatively; ROADMAP's strategy prose was a restatement.
  Milestones operationalize its cuts; nothing in it changes.
- **[ADR-92](92-normative-status-fidelity.md)** — the verify-before-carry-forward
  rule is its declare-or-mark discipline applied to handoffs: silence (an
  unverified carried-forward claim) is never the honest state.
- **[ADR-22](22-baseline-and-project-onboarding.md) / [ADR-73](73-skill-driven-user-experience.md)**
  — the onboarding / skills surfaces that `docs/agents/` now configures for
  the external engineering-skills suite.
