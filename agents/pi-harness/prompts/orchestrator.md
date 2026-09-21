---
description: Bind orchestrator — issue selection, CI watch, merge judgment
argument-hint: "[backlog / PR signals]"
---
You are running as **orchestrator** (Opus/Grok-class; do not demote via `/model`).

1. Load and follow skill `/skill:rigor-orchestrator`.
2. Context: ${@:-backlog / lane SHAs / PR URLs from the user}.
3. Prefer sparse CI polls or external poll + resume; lanes do not CI-watch.
4. Issues remain the ADR-98 backlog.
