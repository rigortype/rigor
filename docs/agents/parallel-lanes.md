# Parallel lanes

Read this before fanning a batch of issues out to subagents: a **lane** is one issue implemented by
one subagent in its own worktree, landed through [`contribution-flow.md`](contribution-flow.md)
§ "Landing a pull request". This file holds what that section leaves to the coordinator: how to
plan the batch, what every lane and reviewer brief restates, and the order things land in. A
subagent cannot be relied on to follow `AGENTS.md`, so the two briefs below are pasted into every
prompt.

The rules below come from the 27-PR batch of the v0.4.3 milestone (October 2026). Its rework
clustered in five places: specs that passed with the fix removed, Ruby-semantics edge cases found
only in review, claims in docs and changelog fragments wider than the change, gates satisfied by
reshaping code, and lanes that collided or started on a premise master had already fixed.

## Coordinator steps

1. **Check each premise before it enters the batch.** Reproduce the issue on current `origin/master`
   and search for an existing implementation by concept. An issue whose premise is gone leaves the
   batch with a comment pointing at where the behaviour lives. Done when every issue in the batch
   has a reproduction or a cited code path that shows the defect.
2. **Design first where the answer is semantic.** For a change to Ruby semantics, path or symlink
   handling, cache keys, or anything that makes Rigor answer a new type, the coordinator writes the
   edge-case table into the brief before a lane starts: each input shape, what Ruby does (a
   `nix develop --command ruby -e` witness), and the answer Rigor must give. Shapes that recur:
   symlinked and logical-vs-physical paths, `Complex`/`Rational`/`BigDecimal` numerics, a
   user-defined or refined method of the same name, `send`/`public_send`, nested blocks and loops,
   pool mode (`--workers N`), warm and `--incremental` reruns. Done when every shape the review would
   probe has a row.
3. **Map overlap, then batch.** List the modules each issue will touch, and include open PRs from
   other sessions (`gh pr list --state open`, then their files): an issue whose mechanism one of
   them changes waits for it to land or for its owner to hand over the lane. Two issues that change
   the same mechanism (one inference pass, one cache key, one diagnostic channel) run one after the
   other; disjoint ones run up to three at a time, with one heavy job (a corpus `rigor check`) on the
   machine at a time.
4. **Route by difficulty.** Ruby semantics, cache and incremental soundness, and anything from step 2
   go to the strongest model; contained CLI, config and plugin changes to the middle tier;
   mechanical edits, wording and docs to the small model. Review is always the strongest model.
5. **Brief the lane** with the issue, its worktree (`bin/rigor-worktree <branch> origin/master`, plus
   `--with-references` when a gate the lane runs reads `references/`; see the
   [`rigor-worktree`](../../.claude/skills/rigor-worktree/SKILL.md) skill), any decision the
   coordinator settled, the reporter's name, email and handle for a fix of an external report, and
   the [lane contract](#lane-contract).
6. **Review when the Draft PR lands**, with the [reviewer contract](#reviewer-contract), and triage
   per contribution-flow.md step 3, including the "Engine allocations (advisory)" summary. Send each
   fix back to the lane that wrote the change with SendMessage, so it keeps its context; route a
   severe fix in intricate logic to the strongest model instead. Delta rounds go to the same
   reviewer with SendMessage and follow contribution-flow.md steps 4–5: three rounds at most, then
   the decision is the user's.
7. **Land in order.** Before merging, fetch, merge `origin/master` into a detached copy of the
   branch, and rerun the spec files the PR touched; a clean textual merge can still break a sibling's
   spec. Check `mergeable` before waiting on CI: a `CONFLICTING` PR starts no run, so send it back to
   its lane to merge master and resolve. After the batch, watch the resulting master CI run.
8. **File the review's scope expansion** as issues outside the milestone. When a merged commit
   carried a `Fixes #N` for an issue the PR only partly fixed, reopen #N with what remains.

## Lane contract

A lane brief restates these:

- **Scope.** You implement and open a Draft PR; the coordinator reviews and lands it. Leave the
  review, `gh pr ready`, the merge and other PRs to the coordinator, whatever `AGENTS.md` says about
  landing.
- **Environment.** Every command through `nix develop --command`, stdin from `/dev/null` for rspec
  and `rigor`, this worktree's own `bundle exec exe/rigor` as the oracle, `references/` read-only,
  scratch files under the worktree's `tmp/`. No `git stash`, no `git submodule deinit`, no
  `pkill`/`killall`; stop only processes you started, and leave none running when you report. No
  version bump, no edit to `CHANGELOG.md` or its `[Unreleased]` section, never `rake release`.
- **Gate.** `make verify-changed` in the foreground, re-run after the last edit. Never `make
  verify`, `make check` or the whole suite.
- **Mutation table.** For every new or changed example, name the line of the fix whose removal makes
  it fail, and run that removal: commit first, mutate, restore with `git checkout HEAD -- <path>`.
  An example that passes with the fix removed is a guard, labelled as one, or it is rewritten until
  it fails. The table goes in the report.
- **Honest gates.** When a provenance pin, residue count or other gate moves, stop and report the
  row and what `rigor sig-gen --print` proposes. Adding a `# sig-gen gap:` or `# authored:` marker,
  extending `spec/rigor/sig_gen/gap_issues.yml`, or moving a pin needs the brief's authorisation;
  the marker rules are ADR-107 and its G3 gate, the hand-edit rule is
  [`type-authoring.md`](type-authoring.md) § "RBS". Code keeps the shape it would have without the
  gate. Keep each rewritten spec's original assertion.
- **Reach.** After deleting or renaming a method, `git grep -nw <name> -- ':!references'`:
  `verify-changed` lists a deletion as uncovered and does not search for its callers.
- **Claims.** The PR body, doc edits and changelog fragment say what the specs pin and no more. A
  binding doc under `docs/type-specification/` or `docs/internal-spec/` that describes the changed
  behaviour changes in the same PR. A `fixed` fragment needs the broken behaviour to have shipped:
  find the commit that introduced it (`git log -S`, blame or bisect), and `git merge-base
  --is-ancestor <that commit> "$(git describe --tags --abbrev=0 origin/master)"` must exit 0. A
  regression that never shipped gets no fragment; every other user-facing change gets one, per
  contribution-flow.md § "Release Cadence".
- **Closing keywords.** `Fixes #N` only when the PR closes all of #N, on its own line, in the PR body
  and commit messages alike; otherwise `Refs #N`. Credit an external reporter per
  contribution-flow.md.
- **Hand-back.** Push with `git push origin HEAD:refs/heads/<branch>`, open the PR Draft, add the
  fragment as a second push, then report: PR and head SHA, files changed, the mutation table, the
  `verify-changed` result, and every decision the issue left open. Stop and report instead of
  opening a PR when the premise is already fixed or a decision belongs to the maintainer.

## Reviewer contract

The reviewer is a fresh agent on the strongest model that did not write the change. Its brief
carries the base commit, the PR and its issue, the Environment bullet of the lane contract, and:

- A detached review worktree at the PR's head SHA with its bundle cloned (`git worktree add --detach
  <path> <sha>`, then `cp -Rc vendor/bundle <path>/vendor/` and copy `.bundle/config`), removed at
  the end; no edits, pushes or comments on the PR.
- **Probe, not re-run.** For a change that makes Rigor answer something, build the wrong-answer
  shapes as fixtures, run that tree's `bundle exec exe/rigor check --no-cache` with a same-file
  positive control, and compare against Ruby; read [`measurement.md`](measurement.md) first.
  Re-run the edge-case table from coordinator step 2 when the brief has one.
- **Prove the specs.** Remove each part of the fix and report which examples fail; an example that
  survives every removal is a finding.
- **Report** findings ranked severe / moderate / minor / nit, each with a concrete failure scenario
  (for an engine change, the input and the wrong output), scope expansion listed separately, and a
  plain statement of whether anything severe remains. Severity is defined in contribution-flow.md
  § "Landing a pull request".
- A delta round re-checks every earlier finding with its original repro, then hunts for regressions
  the fix introduced.
