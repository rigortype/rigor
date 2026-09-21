# pi-harness (ADR-115)

Installable **pi package** for a role-bound multi-model harness on
[pi](https://pi.dev). Owns role×model bindings, skills, slash prompts, and
lane I/O contracts. Does **not** yet own a full long-loop orchestrator —
that remains optional (takt under `.takt/`, or a later in-tree driver).

See [ADR-115](../../docs/adr/115-pi-multi-model-harness.md). Backlog and
flow rules stay in [ADR-98](../../docs/adr/98-development-flow-document-roles.md)
and [`docs/agents/contribution-flow.md`](../../docs/agents/contribution-flow.md).

## Install (project-local)

From the Rigor repo root (requires Node ≥ 22.19 and `pi` on `PATH`):

```bash
export PATH="$HOME/.local/share/mise/shims:$PATH"
# npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi install -l ./agents/pi-harness --approve
# or rely on committed .pi/settings.json:
#   { "packages": ["../agents/pi-harness", "npm:pi-subagents"] }
pi install -l npm:pi-subagents --approve   # if settings already list it, pi list is enough
pi list
```

Only `.pi/settings.json` is written (project-local), plus install artifacts under
`.pi/npm/` (gitignored). Do not use global `~/.pi` for this package. Project
agents under `.pi/agents/` are committed.

After install, skills register as `/skill:rigor-architect` (etc.) and
slash prompts as `/architect`, `/lane`, `/reviewer`, `/docs`,
`/orchestrator`, `/queue-release`, `/queue-survey`.

## Roles

| Role | Model band | Skill | Owns |
| --- | --- | --- | --- |
| `architect` | Opus / Grok | `rigor-architect` | Direction, contracts, planning |
| `lane` | DeepSeek Flash | `rigor-lane` | Worktree imitation; push head SHA and stop |
| `reviewer` | Fable (or Opus/Grok-class) | `rigor-reviewer` | Adversarial review of engine changes |
| `docs` | Gemini Flash | `rigor-docs` | JA publish + EN docs finish; docs-only |
| `orchestrator` | Opus / Grok-class | `rigor-orchestrator` | Issue selection, CI watch, merge judgment |
| queue (release) | Opus / claude-bridge opus / Grok | `rigor-queue-release` | Interactive pre-clear before a cut (`/queue-release`) |
| queue (survey) | Opus / claude-bridge opus / Grok | `rigor-queue-survey` | Interactive survey coverage holes (`/queue-survey`) |

I/O shapes: [`contracts/README.md`](contracts/README.md). Role stubs:
[`roles/`](roles/).

## Model binding (critical)

Free `/model` must not demote an architect task. Prefer the wrapper, which
sets `--model` and scopes Ctrl+P via `--models`:

```bash
./agents/pi-harness/scripts/run-role.sh architect
ISSUE=123 ./agents/pi-harness/scripts/run-role.sh lane
MODEL=anthropic/claude-opus-5 ./agents/pi-harness/scripts/run-role.sh architect
DRY_RUN=1 ./agents/pi-harness/scripts/run-role.sh architect   # print argv only
PRINT=1 ./agents/pi-harness/scripts/run-role.sh architect -nt "…"  # pi -p
```

Defaults (first match from `pi --list-models`; override with `MODEL=`):

| Role | Preferred id | Fallback patterns |
| --- | --- | --- |
| architect / orchestrator | `anthropic/claude-opus-5` | `xai/grok-4.5`, `*opus*`, `grok*` |
| lane | `deepseek/deepseek-flash` | `deepseek/*flash*` |
| reviewer | `anthropic/claude-fable-5` | `*fable*`, then Opus/Grok-class |
| docs | `antigravity/gemini-3.8-flash` | `opencode/gemini*flash*`, `google/gemini*flash*` |

If no provider is configured, the script **exits with `pi auth` / `/login`
guidance** instead of silently using an unbound default.

Auth cheatsheet: `ANTHROPIC_API_KEY` / Claude subscription, `XAI_API_KEY`,
`DEEPSEEK_API_KEY`, `GEMINI_API_KEY`. Inspect: `pi --list-models`.

## v1 path (architect → lane)

Acceptance is [ADR-115 WD6](../../docs/adr/115-pi-multi-model-harness.md).

```bash
# 1) Architect fixes LaneInput for one issue
ISSUE=https://github.com/rigortype/rigor/issues/NNNN \
  ./agents/pi-harness/scripts/run-role.sh architect
# inside session: /architect NNNN   or rely on skill already loaded

# 2) Lane implements under that contract, pushes, prints head SHA, stops
ISSUE=NNNN ./agents/pi-harness/scripts/run-role.sh lane
```

Or in an already-running trusted project session (package installed):

```text
/architect 1234
/lane       # paste LaneInput
```


## Interactive queues

Primary entry: open **`pi`** in the Rigor repo (trusted project; packages already
listed in `.pi/settings.json`), then invoke the slash prompt or skill. Stay in
that session and drive the turn protocol with `next` / `do #N` / `skip` / `stop`
(Japanese: `次` / `やる #N` / `スキップ` / `止めて`). Resume later with
`pi -c` (same project session).

### Parallel lanes via pi-subagents

Requires project package `npm:pi-subagents` in [`.pi/settings.json`](../../.pi/settings.json)
alongside `../agents/pi-harness`. Custom agents live in
[`.pi/agents/`](../../.pi/agents/) (`rigor-lane.md`, `rigor-reviewer.md`).

After ranking in a `/queue-release` or `/queue-survey` session, say `spawn` /
`spawn N` / `全部やれ` / `parallel` (or `next` / `do #N` for one unit) and the
parent should fan out with managed worktrees — not ask you to run
`run-role.sh` in another terminal.

Managed `worktree: true` is documented for `workflowScript` children
(`runs.run` / `runs.all`), not as a reliable direct `{ agent, task }` knob:

```text
# One lane
subagent({
  async: true,
  worktree: true,
  workflowScript: `return runs.run("lane", { agent: "rigor-lane", task: <LaneInput>, worktree: true })`
})

# N lanes (one top-level async workflow)
subagent({
  async: true,
  worktree: true,
  workflowScript: `return runs.all([
    { key: "i1", agent: "rigor-lane", task: <LaneInput1>, worktree: true },
    { key: "i2", agent: "rigor-lane", task: <LaneInput2>, worktree: true }
  ])`
})
```

**Caveats**

- Source checkout must be **clean** before managed worktree fanout (excluding
  `.pi/subagents/` runtime state). Isolation is rejected for a dirty tree.
- Do **not** auto-merge worktree patches into master without a human.
- Lane model default is `deepseek/deepseek-flash`; reviewer prefers
  `claude-bridge/claude-fable-5`. If those ids do not resolve for your
  providers, pin with `MODEL=` on `run-role.sh`, pass `model:` on the
  `subagent` / child launch, or set `subagents.agentOverrides` in Pi settings.
- **Survey:** a managed worktree of *rigor* does **not** satisfy exclusivity of
  `~/repo/ruby/rigor-survey/<project>` — still assign disjoint survey checkouts.

Fallback when pi-subagents is unavailable: LaneInput +
`./agents/pi-harness/scripts/run-role.sh lane`.

### Release pre-clear

Clears merge-valuable Issues before a cut. Example user ask:
「vX.Y.Z リリース前に対処した方がいいタスクを解消して」.

```bash
export PATH="$HOME/.local/share/mise/shims:$PATH"
cd /path/to/rigor
pi
# then:
/queue-release v1.2.3
# or: /skill:rigor-queue-release
```

Hard rule: target version is **context only**. Never seal changelog, bump
VERSION, open `release/x.y.z`, or run `/rigor-release-prep` unless the user
explicitly invoked release-prep. When appropriate, say the cut is one
`/rigor-release-prep` away.

### Survey coverage

Collects rigor-survey coverage holes → prefer Issues → sequential着手.
Example: 「rigor-survey カバレッジの穴を収集して順次着手して」.

```bash
pi
/queue-survey
# or: /queue-survey /Users/megurine/repo/ruby/rigor-survey
# or: /skill:rigor-queue-survey
```

Hard rule: measuring targets need **disjoint** checkouts across agents.

### Optional wrapper

If you want a dedicated `--session-id` / bound orchestrator model without a
bare `pi` first:

```bash
DRY_RUN=1 ./agents/pi-harness/scripts/run-queue.sh release
TARGET=v1.2.3 ./agents/pi-harness/scripts/run-queue.sh release
CONTINUE=1 ./agents/pi-harness/scripts/run-queue.sh survey
```

Skills remain the source of truth for the turn protocol; the wrapper only
launches pi with skill + session-id.

## Package layout

```
agents/pi-harness/
  package.json          # keywords: ["pi-package"]; pi.skills / pi.prompts
  README.md
  roles/*.md            # reference stubs
  contracts/README.md
  skills/rigor-*/SKILL.md   # includes rigor-queue-release / rigor-queue-survey
  prompts/*.md          # slash /architect … /queue-release /queue-survey
  scripts/run-role.sh
  scripts/run-queue.sh  # optional; prefer pi → /queue-…

.pi/settings.json       # packages: ../agents/pi-harness, npm:pi-subagents
.pi/agents/*.md         # project subagents (rigor-lane, rigor-reviewer)
```



## Providers (subscriptions)

| Provider package | Auth | Used for |
| --- | --- | --- |
| [`pi-claude-bridge`](https://github.com/elidickinson/pi-claude-bridge) | Claude Code login (`claude` CLI) + `~/.pi/agent/claude-bridge.json` `"plan": "max"` | architect / orchestrator / reviewer (Opus, Fable) |
| [`pi-antigravity`](https://pi.dev/packages/pi-antigravity) | `/login antigravity` (Google OAuth) | docs (Gemini Flash); optional Flash research |
| OpenCode / API keys | provider-specific | lane DeepSeek Flash; fallbacks |

Install (global, once per machine):

```bash
pi install npm:pi-claude-bridge
pi install npm:pi-antigravity
# then in pi:
#   /login antigravity
#   /model antigravity/gemini-3.8-flash
pi --list-models antigravity
```

Do not leave `ANTHROPIC_API_KEY` exported when using claude-bridge (it overrides the Claude Code child).

## Model routing criteria (roles + subagents)

| Role / agent | Band | Prefer | Criterion (why this band) | Never |
| --- | --- | --- | --- | --- |
| `architect` / orchestrator queue parent | Opus / Grok | `claude-bridge/claude-opus-5` | Sets direction, contracts, merge judgment; cheap models thrash policy (ADR-115) | DeepSeek / Gemini as architect |
| `rigor-lane` / `/lane` | DeepSeek Flash | `deepseek/deepseek-flash` | Parallel imitation under fixed LaneInput; failure is local | Self-promoting to Opus mid-lane |
| `rigor-reviewer` / `/reviewer` | Fable (else Opus) | `claude-bridge/claude-fable-5` | Adversarial engine review; wrong-answer shapes | Gemini for engine review |
| `rigor-docs` / `/docs` | Gemini Flash | `antigravity/gemini-3.8-flash` | JA/EN docs quality on Google AI Pro; docs-only | Engine edits |
| queue release/survey parent | Opus-class | same as architect | Ranking + spawn decisions are policy | Letting Flash rank the backlog alone |

**Subagent fan-out rule:** parent (queue) stays Opus-class; children inherit the agent file `model:` (`rigor-lane` → DeepSeek, `rigor-reviewer` → Fable, `rigor-docs` → Antigravity Gemini). Override with launch `model:` only when the user asks.

**Override:** `MODEL=… ./agents/pi-harness/scripts/run-role.sh <role>` or `subagents.agentOverrides` in Pi settings.

## Non-goals (v1)

- No full in-tree orchestrator yet; **takt is optional**.
- No parallel full-suite `make verify` on the host.
- Lanes do not own long-lived CI watchers / sleep loops.
- Issues remain the backlog (ADR-98).
- Docs (C) flow waits until architect→lane works once; survey queue is available via `/queue-survey`.
- mise stays runtimes-only (ADR-115 WD5).
