# OpenCode (ACP) cross-model validation — driving `rigor-next-steps` across 13 models

Date: 2026-06-20. Status: **tooling/methodology validation.** Companion to
[`20260620-skill-driven-onboarding-dogfood.md`](20260620-skill-driven-onboarding-dogfood.md):
that note ran the [ADR-73](../adr/73-skill-driven-user-experience.md) onboarding flow with Claude
(Sonnet) subagents; this one re-runs the same flow with **13 non-Claude models** (OpenCode Go),
driven over the Agent Client Protocol via the `acp-agent-runner` skill. The question was narrow:
**can other vendors' models drive Rigor's SKILL-driven UX competently?** Answer: **yes — 13/13.**

## Method

- **Models:** every model the OpenCode Go subscription exposes (13): `glm-5.2`, `glm-5.1`,
  `kimi-k2.7-code`, `kimi-k2.6`, `mimo-v2.5-pro`, `mimo-v2.5`, `qwen3.7-max`, `qwen3.7-plus`,
  `qwen3.6-plus`, `minimax-m3`, `minimax-m2.7`, `deepseek-v4-pro`, `deepseek-v4-flash`.
- **Assignment:** each model randomly assigned to a distinct `~/repo/ruby/rigor-survey` project
  (no full matrix — one project per model).
- **Isolation:** each run in a throwaway `cp -Rc` clone of the project (the ACP client auto-approves
  the external agent's edits/shell, so the cwd must be a sandbox).
- **Env abstraction:** a `run-rigor.sh` wrapper staged in each sandbox encapsulates the
  `nix develop <rigor> --command env BUNDLE_GEMFILE=… BUNDLE_PATH=… bundle exec exe/rigor …`
  invocation, so the external model drives Rigor with a single clean command and the test measures
  *tool-driving capability*, not env-wrangling.
- **Task:** the onboarding flow — `version` → `skill describe` → write `.rigor.dist.yml` (only if
  none exists) → `check` → `coverage --protection` → a short structured report.
- **Verification:** `acp_run.py` reads each run's `model_verified` back from OpenCode's own session
  record (prose self-reports are unreliable).

## Result — 13/13 succeeded, all model-verified genuine

| Model | Project | Protection | Errors | Report |
| --- | --- | --- | --- | --- |
| glm-5.2 | erubi | 27.0 % (38/141) | 3 | rich, insightful |
| glm-5.1 | faraday | **24.0 %** (256/1066) | 6 | rich |
| qwen3.7-max | haml | **38.4 %** (617/1606) | 55 | full |
| qwen3.7-plus | parser | 22.0 % (483/2193) | 27 | full |
| qwen3.6-plus | jbuilder | 26.4 % (61/231) | 0 | full |
| deepseek-v4-pro | rubocop-ast | 23.9 % (341/1425) | 6 | full |
| deepseek-v4-flash | numo-narray | 37.1 % (197/531) | — | full |
| minimax-m2.7 | pycall | 44.3 % (228/515) | 0 | full |
| kimi-k2.6 | oj | 57.8 % (178/308) | 2 | concise |
| kimi-k2.7-code | kramdown | 35.5 % (1414/3985) | 55 | concise |
| mimo-v2.5-pro | ox | 30.6 % (119/389) | — | concise |
| mimo-v2.5 | slim | 31.5 % (263/835) | 2 | concise |
| minimax-m3 | mangrove | 13.8 % (147/1068) | — | full, respected existing config |

Wall time 34–68 s per model.

### What worked

- **Every model drove the flow correctly** — wrote `.rigor.dist.yml` where needed, ran all five
  steps via the wrapper, and reported accurate file counts / protection ratios / top holes.
- **Reports are faithful, not hallucinated.** `glm-5.1`/faraday (**24.0 %**) and `qwen3.7-max`/haml
  (**38.4 %**) match the Sonnet field trial's numbers for those same projects **exactly** — the
  models ran Rigor and transcribed its real output rather than inventing figures.
- **Conditional logic respected.** `minimax-m3`'s project (mangrove) already had a `.rigor.yml`;
  the model detected it ("since `.rigor.yml` exists I should NOT create `.rigor.dist.yml`"), even
  noted its `rigor-sorbet` plugin, and correctly skipped the create step.
- **Quality spread (all accurate):** glm / qwen / deepseek wrote richer reports (500–627 words,
  some noting that `check` errors corroborate the top `coverage` holes); kimi / mimo were terser
  (300–426 words) but correct.

### The one operational failure — not a model problem

A first attempt ran **6 sessions in parallel** and lost **5** to
`Error: Unexpected error / database is locked`, surfacing as `timeout waiting for initialize`
(`"ok": false`, `"model_verified": null`, ~0 s). Cause: **OpenCode serialises all sessions through a
single SQLite database** (`~/.local/share/opencode/opencode.db`); concurrent `opencode acp`
processes contend for its write lock. Re-running the same 5 **sequentially succeeded every time** —
a pure concurrency artifact, not a capability gap.

**Lesson (recorded in the skill):** OpenCode ACP sessions must run **sequentially, never in
parallel `&`/background batches** — a multi-model comparison loops the models one `acp_run.py` at a
time. Written into `~/.claude/skills/acp-agent-runner/references/opencode.md` § Gotchas and the
`SKILL.md` "Model comparison" example.

## Takeaways

1. **The SKILL-driven UX is vendor-portable.** All 13 non-Claude models drove `rigor skill
   describe` → onboard → `check` / `coverage --protection` competently and reported faithfully — the
   ADR-73 design does not depend on a particular agent.
2. **The wrapper-script pattern is the reusable lever** for fair cross-model tool tests: hand the
   external model a single command that hides the env wiring, and you measure tool-driving
   capability, not shell/nix/bundler fluency.
3. **OpenCode = sequential only** (the SQLite-lock lesson), now baked into the skill.
