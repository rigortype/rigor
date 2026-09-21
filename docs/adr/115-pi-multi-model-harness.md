# ADR-115 — Multi-model agent harness via pi (own-software first)

Status: **Proposed, 2026-09-21.** Records the standing shape for a
pi.dev-based, role-bound multi-model harness aimed at Rigor’s own
development flows (and later Steins). Thin stubs under
`agents/pi-harness/` land with this amendment; the decision stays
Proposed until the parallel acceptance path (WD6) works once.

Grounding: [`docs/notes/20260921-takt-trial-setup.md`](../notes/20260921-takt-trial-setup.md)
(TAKT trial setup + outcome on #1090 / PR #1144).

## Context

Running many coding agents by hand (Claude Code sessions, ad-hoc model
switching, copy-paste between harnesses) pays a [Harness Tax](https://harnesstax.github.io/):
tokens and attention go to the shuttle, not the work. pi is a minimal,
extensible agent harness; the useful move is to **bind roles to models
and package the contracts**, not to chase a single “best” model.

Rigor already has a working agent development pattern (triage → GitHub
Issues → worktree-parallel implementation → adversarial review → remote
CI as gate → merge), with hard-won operating constraints in the Claude
project memory and in `docs/agents/` (especially
[`contribution-flow.md`](../agents/contribution-flow.md),
[`measurement.md`](../agents/measurement.md)). The harness must encode
that pattern, not replace the backlog rules in [ADR-98](98-development-flow-document-roles.md).

Observed pain: assigning a cheap fast model (e.g. DeepSeek Flash) to
**direction** yields quick diffs and expensive policy thrash. Cheap
capacity belongs in **parallel degree of freedom**, not in architecting.

Three Rigor-owned flows are in view (v1 prioritises A; B and C follow):

- **A. Own-implementation** — direction → baseline implementation →
  same-shaped parallel lanes.
- **B. Survey → issues** — parallel corpus/`rigor-survey` probes →
  synthesis → issue filing.
- **C. Docs** — JA site publish and EN docs finish (docs-only).

### pi vs takt

**pi** is the package surface for role×model binding and parallel lane
contracts (this ADR). **takt** is an optional orchestrator for long
quality-stable loops (plan → implement → draft PR → CI → adversarial →
fix). They are complementary: pi owns the role contracts; takt (or a
later in-tree orchestrator) may drive the long loop that consumes them.
v1 does not require takt; a thin architect→lane path on pi skills is
enough to prove WD6.

### Trial findings (2026-09-21)

An attended TAKT run of `rigor-ready-for-agent` on #1090 produced draft
PR #1144 after human intervention. Two recurring bottlenecks:

1. **Non-interactive git push / PR create** often need human approval in
   the agent session — the ship step cannot be assumed unattended.
2. **CI waiting inside the agent session** stalls when sleep/monitor
   tools are refused. **External poll + resume** works until an
   orchestrator can wait without per-poll tool approval.

These harden WD4 (lanes do not own long CI watchers) and point CI
ownership at the orchestrator / external poller, not the lane.

## Decision

Adopt a **role-bound multi-model harness on pi**, incubated **inside
Rigor**, for **own-software** workflows first.

**Criterion:** a role may use a cheaper/faster model only when (1) the
input contract and acceptance gate are already fixed by a higher-tier
role, and (2) failure modes are local (a bad lane is discarded or
rewritten), not policy-setting. If a task sets direction, contracts, or
merge judgment, it stays on Opus/Grok-class (or Fable for adversarial
engine review). Docs-only quality work may use Gemini Flash.

### WD1 — Own-software first

v1 targets Rigor (and isomorphic Steins later). External OSS
contribution has different pain (upstream norms, delayed review) and is
deferred.

### WD2 — Five roles, model-bound in the package

| Role | Model band | Owns |
| --- | --- | --- |
| `architect` | Opus / Grok | Direction, contracts, planning |
| `lane` | DeepSeek Flash | Worktree-parallel imitation; push head SHA and end |
| `reviewer` | Fable (or Opus/Grok-class) | Adversarial review of engine changes |
| `docs` | Gemini Flash | JA publish + EN docs finish; **docs-only** |
| `orchestrator` | Opus / Grok-class | Issue selection, CI watch, merge judgment |

Bindings live in pi prompt templates / skills so free `/model` switching
cannot quietly demote an architect task. OpenCode remains available for
peripheral drafts outside these five.

### WD3 — Incubate in-tree, then extract

Land a thin package under Rigor first (prompts/skills + I/O contracts;
e.g. `agents/pi-harness/`). When the Steins-shareable core
(`orchestrator` + `lane` + `reviewer` + `docs`) stabilises, extract to a
new repository under [`rigortype`](https://github.com/rigortype).
Rigor-only skills stay installable add-ons.

### WD4 — Preserve existing lane / gate discipline

The harness must not weaken current rules: no parallel full-suite gates
on the host; prefer remote CI; lanes do not own long-lived CI watchers;
survey targets need disjoint checkouts; Issues remain the backlog
(ADR-98). Detail stays in `docs/agents/` and project memory — this ADR
does not duplicate that catalogue.

### WD5 — mise is not this harness

mise remains runtimes and package managers only. Machine bootstrap /
dotfile ownership is out of scope here.

### WD6 — Parallel readiness (v1 acceptance)

v1 succeeds when this path works **once**:

1. `architect` fixes contracts for a scoped change.
2. **N** disjoint worktree lanes (DeepSeek Flash-class) implement under
   those contracts.
3. Each lane **pushes its head SHA and stops** (no CI watcher).
4. `orchestrator` (or external poll + resume) owns CI.
5. A **triple Approved gate** judges the result: Grok:max → Opus:high → Fable:medium (unanimous `Approved` only; any `Needs fix` → fix loop).

Survey (B) and docs (C) wait until that path has landed once. Stubs in
`agents/pi-harness/` are not the acceptance proof; the end-to-end run is.

## Rejected / deferred alternatives

| Alternative | Why not (for v1) |
| --- | --- |
| Start as a brand-new empty `rigortype/*` repo | Feedback loop with Rigor conventions is too slow; incubate first (WD3). |
| Single-model / single-agent for all phases | Pays Harness Tax; cheap models thrash policy when used for direction. |
| Flash (or similar) as `architect` | Causes direction rework; violates the Decision criterion. |
| Gemini for engine adversarial review | Wrong failure mode; Gemini is docs-tier (WD2). |
| Put the harness in mise bootstrap / self-saving dotfiles | Conflicts with mise-as-runtimes scope (WD5). |
| External-OSS contribution in the same v1 package | Different pain; deferred (WD1). |
| Require takt as the only v1 orchestrator | takt is optional; pi contracts must stand alone (pi vs takt). |
| Lane-owned long CI sleep loops | Trial finding: agent-session waits stall on tool approval; orchestrator / external poll owns CI (WD4, WD6). |

## Consequences

**Positive.** Clear place to put role contracts; subscription capacity
(Claude / Grok / OpenCode / Gemini) maps to jobs; Steins can reuse the
extracted core later. TAKT trial bottlenecks (push approval, CI wait)
are now explicit acceptance constraints rather than folklore.

**Negative.** Until extract, Rigor carries another in-tree agent
artefact; role bindings need occasional retuning as models change.
Human-in-the-loop for push/PR remains until sessions can ship
non-interactively.

**Carry-over.** Wire one architect→lane path end-to-end (WD6); only then
survey (B) and docs (C). Re-evaluate extract triggers: Steins wants the
same four shared roles, or a second consumer appears. Revisit in-session
CI waiting once an orchestrator can poll without per-tick approval.

## Relationship to other ADRs

- [ADR-98](98-development-flow-document-roles.md) — Issues remain the
  backlog; this harness consumes that backlog, it does not replace it.
- Agent operating detail continues to live under `docs/agents/`
  ([`contribution-flow.md`](../agents/contribution-flow.md),
  measurement), not in this ADR.
- Trial note:
  [`docs/notes/20260921-takt-trial-setup.md`](../notes/20260921-takt-trial-setup.md)
  — setup + outcome on #1090 via PR #1144 (human push, external CI poll,
  resume). takt workflow facets under `.takt/` are a complementary
  long-loop experiment, not a substitute for the pi role package.
