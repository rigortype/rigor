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
#   { "packages": ["../agents/pi-harness"] }
pi list
```

Only `.pi/settings.json` is written (project-local). Do not use global
`~/.pi` for this package.

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
MODEL=claude-bridge/claude-opus-5 ./agents/pi-harness/scripts/run-role.sh architect
DRY_RUN=1 ./agents/pi-harness/scripts/run-role.sh architect   # print argv only
PRINT=1 ./agents/pi-harness/scripts/run-role.sh architect -nt "…"  # pi -p
```

Defaults (first match from `pi --list-models`; override with `MODEL=`):

| Role | Preferred id | Fallback patterns |
| --- | --- | --- |
| architect / orchestrator | `claude-bridge/claude-opus-5` | `anthropic/claude-opus-5`, `xai/grok-4.5`, `*opus*`, `grok*` |
| lane | `deepseek/deepseek-flash` | `deepseek/*flash*` |
| reviewer | `claude-bridge/claude-fable-5` | `anthropic/*fable*`, then Opus/Grok-class |
| docs | `google/gemini-3.8-flash` | `gemini-flash-latest`, `*gemini*flash*` |

### Claude Max via [pi-claude-bridge](https://github.com/elidickinson/pi-claude-bridge)

Rigor’s Claude Max subscription is preferred over Anthropic API keys for
architect / reviewer / orchestrator:

```bash
# once per machine (global; not in this repo)
pi install npm:pi-claude-bridge
# ~/.pi/agent/claude-bridge.json — Max plan
# { "provider": { "plan": "max" } }
pi --list-models claude-bridge   # should list opus/fable/…
```

Requires `claude` CLI logged in. Models appear as `claude-bridge/claude-opus-5`
etc. Do **not** leave `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` exported when
using the bridge (they override the Claude Code child).

If no provider is configured, the script **exits with `pi auth` / `/login`
guidance** instead of silently using an unbound default.

Auth cheatsheet: Claude Max via bridge (preferred), else `ANTHROPIC_API_KEY`,
`XAI_API_KEY`, `DEEPSEEK_API_KEY`, `GEMINI_API_KEY`. Inspect: `pi --list-models`.

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

Primary entry: open **`pi`** in the Rigor repo (trusted project; package already
listed in `.pi/settings.json`), then invoke the slash prompt or skill. Stay in
that session and drive the turn protocol with `next` / `do #N` / `skip` / `stop`
(Japanese: `次` / `やる #N` / `スキップ` / `止めて`). Resume later with
`pi -c` (same project session).

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
```

## Non-goals (v1)

- No full in-tree orchestrator yet; **takt is optional**.
- No parallel full-suite `make verify` on the host.
- Lanes do not own long-lived CI watchers / sleep loops.
- Issues remain the backlog (ADR-98).
- Docs (C) flow waits until architect→lane works once; survey queue is available via `/queue-survey`.
- mise stays runtimes-only (ADR-115 WD5).
