---
name: rigor-next-steps
description: |
  Route a project to its next Rigor step from a single entry point: resolve the `rigor` command (install it if missing), onboard the project if it has no Rigor config, then ask `rigor skill describe` what to do next and hand off to the matching skill. Triggers: "what should we do next with Rigor?", "I want to use Rigor on this project", "help me move this project forward with Rigor", "where do I start with Rigor?". NOT a replacement for the task-specific skills it routes to — it hands off to them.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Next Steps

The single entry point for "what should we do next with Rigor on this
project?" This skill is deliberately **thin**: it only does the
bootstrap that must happen before `rigor` can speak for itself, then it
hands the decision to the installed `rigor` binary via
`rigor skill describe`. That keeps the advice **current to the
installed version** — the routing intelligence lives in the gem, not
frozen in this file (ADR-73).

Work top to bottom. Stop at the first step that is not yet satisfied,
complete it, then continue.

## Autonomous / non-interactive runs

When the user has delegated the journey up front ("set this project up
and get it healthy; don't wait for me"), the skills below still contain
ask-the-user points. Handle them like this:

- A choice the user **already made in their instruction** (e.g. the
  adoption mode) is settled — record it and proceed; do not re-ask.
- A low-risk, reversible, in-repo action a skill says to confirm
  (installing an RBS collection, a `.gitignore` addition) is covered by
  the standing delegation — do it, and note the self-answer in your
  report.
- **Committing, pushing, or publishing is never covered** by a general
  delegation — leave the files uncommitted and list them for the user.
- A step only a human can complete or verify (watching a CI run
  execute, confirming live diagnostics inside an editor) is a
  **handoff, not a stall**: do the file-level part if it is safe,
  then report what remains for the user instead of waiting.

## Step 1 — Resolve the `rigor` command

```sh
rigor --version
```

If it prints a version (`rigor 0.x.y`), `rigor` is installed — go to
**Step 3**. If the command is not found, go to **Step 2**.

## Step 2 — Install Rigor (only if Step 1 failed)

Rigor is a standalone tool, **not** a project dependency — do not add it
to the `Gemfile`. Fetch and follow the install guide, which is written
for an AI agent and picks the right channel (mise / asdf / gem / Docker)
for the environment:

- <https://raw.githubusercontent.com/rigortype/rigor/master/docs/install.md>

Follow it until `rigor --version` succeeds, then continue to Step 3.

(This is the one step that cannot be driven by `rigor skill describe` —
there is no binary to ask yet. It is the only install knowledge this
skill carries, kept as a pointer rather than a copy so it does not go
stale.)

## Step 3 — Set the project up if it has no Rigor config

Check the project root for `.rigor.yml` or `.rigor.dist.yml`. If
**neither** exists, the project has never been onboarded — set it up
first:

```sh
rigor skill --full rigor-project-init
```

(`rigor skill <name>` prints the skill body alone; `--full` inlines its
`references/` files too, so one call fetches the complete procedure.)
Follow that skill's body top to bottom (it detects the stack, picks
plugins, writes `.rigor.dist.yml`, and snapshots a baseline if needed),
then come back to Step 4.

## Step 4 — Ask `rigor skill describe` what to do next

Once `rigor` is installed and the project is configured, let the live
command pick the next move:

```sh
rigor skill describe
```

Its output reports the project's current state (config / baseline /
`sig/` / CI), names a **recommended next skill** with a one-line reason,
and lists every skill you can run next with its current description.

## Step 5 — Route and act

Read the `## Recommended next step` and `## For the agent` sections of
the `describe` output, then:

- **Present the recommendation to the user proactively** — e.g. "Rigor
  is set up but not wired into CI; I suggest the `rigor-ci-setup` skill
  to lock in the regression guard. Shall I?" — rather than only asking
  an open question.
- If the user has a different goal, ask which skill they want from the
  listed catalog.
- Then load the chosen skill and follow it:

  ```sh
  rigor skill --full <chosen-skill>
  ```

Re-run `rigor skill describe` any time you want the next step again — it
always reflects the project's current state, so this skill stays useful
across the whole adoption journey, not just the first run.

## Reading the docs offline

Once Rigor is installed (Step 1 succeeded), the full manual **and
handbook** ship inside the gem — read any chapter **without the
network**:

```sh
rigor docs                 # the offline doc index (what's available)
rigor docs <name>          # a chapter, e.g. `rigor docs editor-integration`
rigor docs --list          # name + absolute path for every bundled doc
rigor docs --list handbook # just the handbook chapters
```

Prefer this over fetching the same page from the web: it is the exact
copy that shipped with the installed `rigor`, so it always matches the
binary's behaviour. (The web copy at <https://rigor.typedduck.fail/llms.txt>
is for the contributor-facing corpus and for reading before install.)
