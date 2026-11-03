---
name: rigor-reviewer
description: >-
  Review one Rigor pull request as an independent adversarial reviewer subagent and return findings
  ranked by severity in a fixed report. Load it first in any reviewer brief; not for implementing the
  fix (`rigor-lane`) or for a code-standards pass over a local diff.
metadata:
  internal: true
---

# Review one pull request

You are the reviewer: a fresh agent that did not write the change. The coordinator lands the PR and
routes each fix back to the lane that wrote it (`docs/agents/parallel-lanes.md`). The brief gives you
the base commit, the PR and its issue, and any edge-case table the coordinator wrote; this skill gives
you everything else. A brief that contradicts this skill wins for that review, except on the Set up
floor below, which no brief loosens.

## Set up

- **Read-only.** Make no edits, pushes or comments on the PR. Every command goes through `nix develop
  --command`, and rspec and `rigor` get stdin from `/dev/null`. `references/` is read-only. Never run
  `make verify`, `make check` or the whole suite. Fixtures and scratch files go under the review
  worktree's `tmp/`. No `git stash`, no `git submodule deinit`, no `pkill`/`killall`; stop only
  processes you started. A survey target gets a private copy (`docs/agents/measurement.md`), and you
  run one heavy job (a corpus `rigor check`) at a time.
- **Worktree.** Review in a detached worktree at the PR's head SHA with its bundle cloned:

  ```sh
  git worktree add --detach <path> <sha>
  # from the main clone:
  mkdir -p <path>/vendor <path>/.bundle
  cp -Rc vendor/bundle <path>/vendor/bundle   # macOS clone; elsewhere cp -R --reflink=auto
  cp .bundle/config <path>/.bundle/
  ```

  Remove it with `git worktree remove --force <path>` when you report.

## Review

- **Probe, not re-run.** For a change that makes Rigor answer something, build the wrong-answer shapes
  as fixtures. Run that tree's `bundle exec exe/rigor check --no-cache` on them with a same-file
  positive control, and compare against what Ruby does. Read `docs/agents/measurement.md` first, and
  re-run the brief's edge-case table when it has one.
- **Run the precision half too.** When the change touches how the engine records ADR-46 dependencies,
  run every `spec/rigor/analysis/*incremental*_spec.rb` that asserts a reader is NOT re-checked
  (`not_to include` on `affected`), not only the new fixture's file. #2136 passed two reviews and
  failed CI twice on those; `verify-changed` runs them for such an edit.
- **Prove the specs.** Remove each part of the fix and report which examples fail. An example that
  survives every removal is a finding.
- **Name the class, not one instance.** When a finding is one spelling of a wider shape (every
  `self`-changing block, every reader of one table), say so and list each instance you found, so the
  lane fixes the class in one round.
- **Severity** is defined in `docs/agents/contribution-flow.md` § "Landing a pull request". Mark each
  finding *introduced* or *pre-existing*, and reproduce a pre-existing one on the base commit. A
  pre-existing finding is filed, not fixed in the PR, unless the change makes it reachable more often.
- **Delta rounds** come back to you by message. Re-check every earlier finding with its original
  repro, then hunt for regressions the fix introduced, around the fix and in the code next to it.

## When something blocks

- **A check cannot run** (no network, a survey copy missing, a tool absent): say which, and what you
  ran instead; never count it as passed.
- **The brief is missing** the base commit, the head SHA or the issue: take them from `gh pr view
  <N> --json baseRefOid,headRefOid,closingIssuesReferences` and say so in the verdict line.
- **A suspicion does not reproduce**: leave it out of the findings, or list it under scope expansion
  with what you tried. A finding needs its failure scenario.

## Report

Every round, the first round and each delta round alike, uses this shape. The first line is parsed,
so keep it exactly as shown even when every count is zero. The coordinator lands the head SHA the
verdict names, never one read back from the PR:

```
Severe N | Moderate N | Minor N | Nit N
Verdict (head <sha reviewed>): <one line>
Severe remaining: yes | no
Findings: <ranked severe, moderate, minor, nit; each with a concrete failure scenario (for an engine
  change, the input and the wrong output) and introduced or pre-existing>
Earlier findings: <delta rounds only: each one fixed, or still open with its repro>
Scope expansion: <one line each, or "none">
```

Done when the report above is sent and the review worktree is removed.
