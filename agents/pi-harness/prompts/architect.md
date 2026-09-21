---
description: Bind architect role — load rigor-architect skill and emit Plan ready
argument-hint: "[issue URL or number]"
---
You are running as **architect** (Opus/Grok-class; do not demote via `/model`).

1. Load and follow skill `/skill:rigor-architect` (read its SKILL.md if not already loaded).
2. Scope: ${@:-the current issue / user request}.
3. Produce a LaneInput-shaped contract per the skill / `contracts/README.md`.
4. End with exactly `Plan ready` or `Blocked — need human`.
