# rigor-worktree trigger evals

`trigger-eval.json` is a 20-query set that checks whether the `rigor-worktree`
skill's `description:` routes correctly — it fires on real worktree needs and
stays quiet on near-misses that belong to a sibling skill (`rigor-dependency-update`,
`rigor-add-reference`, `rigor-regression-sweep`, `rigor-ruby-version-bump`) or to
no skill at all.

Ten queries should trigger, ten should not. The should-not set is deliberately
adversarial — each shares keywords or concepts with the skill (`bundle`, `gems`,
`submodule`, `references/`, `git worktree`, `parallel`) but needs something else.

## Format

`[{ "query": "<realistic user message>", "should_trigger": <bool> }]` — the
`--eval-set` shape that skill-creator's `scripts/run_loop.py` and `scripts/run_eval.py`
consume, and `waza`'s trigger scaffolding can read the same pairs.

## Running it

The rigorous path is skill-creator's loop, which injects the description as a
`.claude/commands/` entry and runs `claude -p` per query to see whether Claude
consults it:

```sh
cd <rigor repo>
PYTHONPATH=<skill-creator> python3 -m scripts.run_eval \
  --eval-set .claude/skills/rigor-worktree/evals/trigger-eval.json \
  --skill-path .claude/skills/rigor-worktree \
  --model <session model id>
```

`run_eval` only counts a trigger when Claude invokes the *injected* command, so
move the real `.claude/skills/rigor-worktree/` aside for the run (it has a
near-identical description) and restore it after — otherwise Claude picks the
real skill and every such run reads as a false negative.

This needs a working `claude -p` login. Where that is unavailable, classify each
query with independent subagents instead: give each the live routing table (all
skill `name` + `description` pairs) and the queries, and ask which skill it would
consult.

## Last validated

2026-09-07, subagent method (three independent judges, `claude -p` login was not
available): **20/20** — recall 10/10, specificity 10/10, zero false fires, zero
misses, all three judges unanimous on every query. The "Also the reference for
worktree gotchas" clause in the description is what routed the two
gotcha-reference queries (empty `references/`, shared-`.git` stash bleed); it
stays for that reason despite being flushable on token grounds.

Spec-compliance (`waza check .claude/skills/rigor-worktree`) is a separate gate
and was 9/9 at the same date. Per `docs/agents/skill-authoring.md`, `waza`'s
other advisories (token budget, `USE FOR:` markers) target agentskills.io
publication and do not bind a contributor skill.
