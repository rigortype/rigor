---
name: rigor-lane
description: >-
  The contract a lane subagent follows when a coordinator hands it one Rigor issue to implement in its
  own worktree and return as a Draft PR. Load it first in any lane brief; not for reviewing a PR (the
  reviewer contract in docs/agents/parallel-lanes.md) or for coordinating a batch.
metadata:
  internal: true
---

# Implement one issue as a lane

You are a lane: one issue, one worktree, one Draft PR. The coordinator plans the batch, reviews your
PR and lands it (`docs/agents/parallel-lanes.md`). The
brief gives you the issue, the worktree branch, any decision already settled and anything withdrawn;
this skill gives you everything else. A brief that contradicts this skill wins for that lane.

## Before you write code

1. Create the worktree the brief names with `nix develop --command bin/rigor-worktree <branch>
   origin/master` (add `--with-references` when a gate you run reads `references/`) and work only
   there.
2. Reproduce the issue on the fresh `origin/master`. When the premise is already fixed, or the work
   needs a decision on contribution-flow.md's serious list, stop and report; open no PR.

## While you work

- **Scope.** Change only what the issue asks. Report anything wider for the coordinator to file. Leave
  the review, `gh pr ready`, the merge and other PRs to the coordinator.
- **Environment.** Every command through `nix develop --command`; stdin from `/dev/null` for rspec and
  `rigor`; this worktree's `bundle exec exe/rigor` as the oracle; `references/` read-only; scratch
  files under the worktree's `tmp/`. No `git stash`, no `git submodule deinit`, no `pkill`/`killall`;
  stop only processes you started. No version bump, no edit to `CHANGELOG.md`, never `rake release`.
  Commit with the configured identity, never `--author=` or `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, and add
  no attribution lines. Leave `# rigor:` and `# rubocop:` lines in fixtures alone. A survey target gets
  a private copy (`docs/agents/measurement.md`); run one heavy job at a time.
- **Gate.** `make verify-changed </dev/null` in the foreground, re-run after the last edit. Never `make
  verify`, `make check` or the whole suite. A change to dispatch, scope resolution or the discovery
  tables also runs `spec/rigor/scope/ancestry_walker_detection_spec.rb` and
  `spec/rigor/declaration_facts/producers_spec.rb`.
- **Mutation table.** For every new or changed example, remove the line of the fix it pins and show it
  fails: commit first, mutate with `perl -pi -e` (the Flake's `sed -i ''` edits nothing), prove the
  edit with `git diff --stat`, restore with `git checkout HEAD -- <path>`. An example that survives
  every removal is a labelled guard or is rewritten. The shapes that survive are in
  `docs/agents/measurement.md` § "Specs and gates that pass without checking".
- **Honest gates.** When a provenance pin, residue count or other gate moves, stop and report the row.
  A `# sig-gen gap:` or `# authored:` marker, a `gap_issues.yml` row or a moved pin needs the brief's
  authorisation or a precedent (contribution-flow.md § "Decisions and the approval queue"); the rules
  are ADR-107 and `docs/agents/type-authoring.md`. Copy no type into a
  declaration without checking it against every write site. Code keeps the shape it would have without
  the gate.
- **Engine cost.** For an engine change, run `tool/engine_alloc_ab.rb` against the merge base. A rise
  above 1% is reported with where it comes from; the coordinator decides whether it lands
  (`docs/agents/parallel-lanes.md` step 6).
- **Reach.** After deleting or renaming a method, `git grep --untracked -nw <name> -- ':!references'`.
- **Claims.** The PR body, doc edits and changelog fragment say what the specs pin and no more. A
  binding doc under `docs/type-specification/` or `docs/internal-spec/` changes with the behaviour. A
  `fixed` fragment needs the broken behaviour to have shipped (`git merge-base --is-ancestor <commit>
  "$(git describe --tags --abbrev=0 origin/master)"`); an unshipped regression gets none.
- **Decisions.** Decide what is not serious by precedent and take the conservative option; record each
  in an `approval-queue.d/` entry (its README has the format).
- **Closing keywords.** `Fixes #N` only when the PR closes all of #N, on its own line; otherwise
  `Refs #N`. Start every GitHub body with a one-line note that it was AI-generated.

## When something blocks

- **A gate fails** and the failure is yours: fix it and re-run. When it predates your branch and has an
  issue, `bin/lane-push --no-verify=<reason>` is the one bypass; quote the reason in the report.
- **A check cannot run** (no network, a survey copy missing, a tool absent): say which, and what you ran
  instead; never report it as passed.
- **The brief and the code disagree**, or a fix would need more than the issue asks: stop and report
  with the evidence rather than widening the change.

## Hand back

Push only with `nix develop --command bin/lane-push`, for every push. Open the PR as a Draft after the
first push. Fix rounds come back to you by message; push each through `bin/lane-push` again.

Report in this shape, and put the detail in the PR body, not the report:

```
PR: #N  head: <sha>  base: <sha>  verify-changed: OK | <failure>
Outcome: <one line: what now works, or why you stopped>
Mutations: <example> <- <removed line>; ... (guards labelled)
Engine cost: <alloc A/B delta, or "not an engine change">
Decisions: <approval-queue entry, one line each>
Filed or for the coordinator to file: <one line each>
Open: <anything the coordinator must decide>
```

Done when the Draft PR is open, `verify-changed` passed on its head, and the report above is sent.
