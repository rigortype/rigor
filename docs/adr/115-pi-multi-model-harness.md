# ADR-115 — Multi-model agent harness via pi (own-software first)

Status: **Proposed, 2026-09-21.** Records the standing shape for a
pi.dev-based, role-bound multi-model harness aimed at Rigor’s own
development flows (and later Steins). No package has landed; this ADR
is the decision, not the implementation.

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

## Rejected / deferred alternatives

| Alternative | Why not (for v1) |
| --- | --- |
| Start as a brand-new empty `rigortype/*` repo | Feedback loop with Rigor conventions is too slow; incubate first (WD3). |
| Single-model / single-agent for all phases | Pays Harness Tax; cheap models thrash policy when used for direction. |
| Flash (or similar) as `architect` | Causes direction rework; violates the Decision criterion. |
| Gemini for engine adversarial review | Wrong failure mode; Gemini is docs-tier (WD2). |
| Put the harness in mise bootstrap / self-saving dotfiles | Conflicts with mise-as-runtimes scope (WD5). |
| External-OSS contribution in the same v1 package | Different pain; deferred (WD1). |

## Consequences

**Positive.** Clear place to put role contracts; subscription capacity
(Claude / Grok / OpenCode / Gemini) maps to jobs; Steins can reuse the
extracted core later.

**Negative.** Until extract, Rigor carries another in-tree agent
artefact; role bindings need occasional retuning as models change.

**Carry-over.** Implement the thin package; wire one architect→lane
path end-to-end; only then survey (B) and docs (C). Re-evaluate extract
triggers: Steins wants the same four shared roles, or a second consumer
appears.

## Relationship to other ADRs

- [ADR-98](98-development-flow-document-roles.md) — Issues remain the
  backlog; this harness consumes that backlog, it does not replace it.
- Agent operating detail continues to live under `docs/agents/`
  (contribution-flow, measurement), not in this ADR.
