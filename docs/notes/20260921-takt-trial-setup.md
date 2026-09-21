# TAKT trial setup (2026-09-21)

Companion to [ADR-115](../adr/115-pi-multi-model-harness.md) evaluation of
long-running quality-stable agent loops vs role-bound pi packages.

## Installed

- `mise use -g npm:takt@0.66.0` (CLI on PATH via mise shims)
- Global config: `~/.takt/config.yaml` — `language: ja`, default `provider: mock`
  (override per run with `--provider`)

## Smoke

- `takt workflow doctor pure simple review` — OK (ja builtins)
- `takt --provider mock --pipeline --skip-git -w pure -t "…"` — engine boots;
  mock fails at first step with `rule_no_match` (expected; not a real agent)

## Available providers on this machine

- `claude` (Claude Code 2.1.278)
- `pi` (0.86.0 via mise)
- `opencode`

## Next real trial (manual / attended)

Prefer a tiny docs-only or throwaway task, not a full `default` loop on master:

```bash
cd ~/repo/ruby/rigor
takt --provider claude -w pure   # interactive: describe task, /go, Queue as task
takt run                         # worktree-isolated execution
```

Evaluation axes (unchanged):

1. Lane contract (push-and-end) vs TAKT long-lived steps
2. Long quality-stable loops (`review-fix` / `default`)
3. Multi-provider mixing (claude / pi / opencode)

Do not commit `.takt/runs/`, `.takt/tasks/`, or credentials.
