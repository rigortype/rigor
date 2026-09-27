# Authoring a skill in this repo

Two trees, two audiences. Each `SKILL.md`'s `description:` is the routing surface; do not maintain a
second catalogue of triggers.

- [`.claude/skills/`](../../.claude/skills/) contains contributor workflows. They assume this repo's
  `Makefile` and layout and carry `metadata.internal: true`.
- [`skills/`](../../skills/) contains user-facing workflows. They use only the public `rigor` CLI; no
  `make` targets, repository paths, or Flake commands. The two trees may share a name while serving
  different readers.

Third-party plugin authors are routed out of the monorepo — see `rigor-plugin-author` Phase 0.5 and
[ADR-31](../adr/31-contribution-and-supply-chain-policy.md) WD2/WD4.

## Description

Keep the description short enough to route from metadata alone: state the action, the concrete event or
artifact that triggers it, and only the non-obvious boundary that routes elsewhere. Prefer one or two
sentences over a catalogue of examples, implementation details, or exact flags. A trigger should name
the task this skill owns, not every task in its neighborhood; an anti-trigger is useful when two skills
could plausibly match.

Treat the description as a pointer, not a mini-procedure. Put exact commands, version-coupled values,
long examples, and branch-specific steps in the body or a conditional `references/` file. The body should
be the stable workflow spine: goal, phases, decision points, and an observable completion criterion.
When a skill has multiple branches, route to the relevant reference instead of loading every branch.

## The `waza` review

A change to a skill ships only after a `waza` review, in addition to the adversarial review in
[`contribution-flow.md`](contribution-flow.md) § "Landing a pull request". The agent reviewer reads the
change against the repository; `waza` reads the skill as the routing and instruction surface an agent
follows. Any change to a skill therefore takes a PR; only a typo-class fix (spelling, a broken link
target) may go straight to `master`, after a local `waza check`. Deleting a skill needs no `waza` run.

Which commands run depends on what changed, in either skill tree:

| Changed | Run |
| --- | --- |
| `SKILL.md` | `waza check <skill-path>` and `waza quality <skill-path> --model <judge>` |
| only `references/`, `scripts/`, or `evals/` | `waza check <skill-path>`. `waza quality` reads only `SKILL.md`, so it would score text the PR did not touch; the adversarial review carries the content. |

A mechanical sweep across many skills runs `waza check` on each and `waza quality` on one
representative skill, named in the PR comment. A sweep is mechanical only when it changes no
`description:` and no instruction wording — paths, links, formatting. A sweep that rewrites
descriptions or instructions runs `waza quality` on every changed `SKILL.md`.

`waza quality` needs a GitHub Copilot login and the Flake's waza at 0.38.7 or later; waza 0.31.0
returns `parsing judge response: no JSON found` for every judge. Pick the strongest judge `waza models`
lists that answers. If a named judge fails on the Copilot side (`model.call_failure` under `--debug`),
fall back to `--model auto`; record which judge ran. The judge is non-deterministic and scores the same text
differently run to run, so read its feedback, not its number.

Triage the output with the adversarial review's findings:

- Only two sections of `waza check` bind: "Spec Compliance" and "Links". A failure there is a
  defect; fix it. The ❌ lines under Compliance Score, Token Budget, Advisory Checks, and the overall
  verdict are publication-profile advisories and follow the next rule. A link check that fails for
  lack of network is "`waza` cannot run", not a defect.
- `waza quality` output is advisory and never severe on its own. Adopt an item only when it identifies
  a real defect independent of the agentskills.io publication profile; Rigor's comprehensive workflows
  do not need to be reshaped for its token budget or labels, and a low completeness score for detail
  kept in `references/` is the progressive disclosure this guide asks for. The adversarial reviewer
  may promote an item to severe. See [ADR-81](../adr/81-skill-set-optimization.md) for the standing
  calibration.
- Re-running `waza` after a fix round is part of that round's delta review, not a separate round, and
  never opens one by itself.

Post the commit scored, the judge, the scores, and what you adopted or rejected, with reasons, as a
PR comment. If `waza`
cannot run — not installed, too old, no Copilot login, every judge fails — say so in the PR and leave
it Draft. A session where `waza` runs clears it by running the review and posting the comment; the
review is never skipped silently.

Never run `waza dev --auto`: it injects boilerplate that is often false. The hand-written `name:` and
`description:` pair is the binding surface.
