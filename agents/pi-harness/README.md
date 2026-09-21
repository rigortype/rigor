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
`/orchestrator`.

## Roles

| Role | Model band | Skill | Owns |
| --- | --- | --- | --- |
| `architect` | Opus / Grok | `rigor-architect` | Direction, contracts, planning |
| `lane` | DeepSeek Flash | `rigor-lane` | Worktree imitation; push head SHA and stop |
| `reviewer` | Fable (or Opus/Grok-class) | `rigor-reviewer` | Adversarial review of engine changes |
| `docs` | Gemini Flash | `rigor-docs` | JA publish + EN docs finish; docs-only |
| `orchestrator` | Opus / Grok-class | `rigor-orchestrator` | Issue selection, CI watch, merge judgment |

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

## Package layout

```
agents/pi-harness/
  package.json          # keywords: ["pi-package"]; pi.skills / pi.prompts
  README.md
  roles/*.md            # reference stubs
  contracts/README.md
  skills/rigor-*/SKILL.md
  prompts/*.md          # slash /architect /lane /reviewer /docs /orchestrator
  scripts/run-role.sh
```

## Non-goals (v1)

- No full in-tree orchestrator yet; **takt is optional**.
- No parallel full-suite `make verify` on the host.
- Lanes do not own long-lived CI watchers / sleep loops.
- Issues remain the backlog (ADR-98).
- Survey (B) and docs (C) flows wait until architect→lane works once.
- mise stays runtimes-only (ADR-115 WD5).
