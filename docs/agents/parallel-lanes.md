# Parallel lanes

Read this before fanning a batch of issues out to subagents: a **lane** is one issue implemented by
one subagent in its own worktree, landed through [`contribution-flow.md`](contribution-flow.md)
§ "Landing a pull request". This file holds what that section leaves to the coordinator: how to
plan the batch, what every lane and reviewer brief restates, and the order things land in. A
subagent inherits none of `AGENTS.md`, so the two briefs below are pasted or linked into every
prompt.

The rules below come from a 27-PR batch (v0.4.3, October 2026). Its rework clustered in five places:
specs that passed with the fix removed, Ruby-semantics edge cases found only in review, claims in
docs and changelog fragments wider than the change, gates satisfied by reshaping code, and lanes
that collided or started on a premise master had already fixed.

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
3. **Map overlap, then batch.** List the modules each issue will touch. Two issues that change the
   same mechanism (one inference pass, one cache key, one diagnostic channel) run one after the
   other, never in the same batch; disjoint ones run up to three at a time.
4. **Route by difficulty.** Ruby semantics, cache and incremental soundness, and anything from step 2
   go to the strongest model; contained CLI, config and plugin changes to the middle tier;
   mechanical edits, wording and docs to the small model. Review is always the strongest model.
5. **Brief the lane** with the issue, its worktree (`bin/rigor-worktree <branch> origin/master`, see
   the [`rigor-worktree`](../../.claude/skills/rigor-worktree/SKILL.md) skill), any decision the
   coordinator settled, and the [lane contract](#lane-contract).
6. **Review when the Draft PR lands**, with the [reviewer contract](#reviewer-contract). Route each
   fix back to the lane that wrote the change; route a severe fix in intricate logic to the strongest
   model instead. After a fix that changes behaviour, not just wording or specs, send the delta
   commit range back to the same reviewer even when nothing was severe.
7. **Land in order.** Before merging, fetch, merge `origin/master` into a detached copy of the
   branch, and rerun the spec files the PR touched; a clean textual merge can still break a sibling's
   spec. Check `mergeable` before waiting on CI: a `CONFLICTING` PR starts no run, so send it back to
   its lane to merge master and resolve. After the batch, watch the resulting master CI run.
8. **File the review's scope expansion** as issues outside the milestone, and close the loop on
   every `Refs` / `Fixes` the merged commits carry.

## Lane contract

A lane brief restates these, because the subagent has not read `AGENTS.md`:

- **Environment.** Every command through `nix develop --command`, stdin from `/dev/null` for rspec
  and `rigor`, this worktree's own `bundle exec exe/rigor` as the oracle, `references/` read-only,
  scratch files under the worktree's `tmp/`. No `git stash`, no `git submodule deinit`, no
  `pkill`/`killall`; stop only processes you started, and leave none running when you report.
- **Gate.** `make verify-changed` in the foreground, re-run after the last edit. Never `make
  verify`, `make check` or the whole suite.
- **Mutation table.** For every new or changed example, name the line of the fix whose removal makes
  it fail, and run that removal. An example that passes with the fix removed is a guard, labelled as
  one, or it is rewritten until it fails. The table goes in the report.
- **Honest gates.** When a provenance pin, residue count or other gate moves, mark the declaration
  (`# authored:`, `# sig-gen gap:`) per [`type-authoring.md`](type-authoring.md) or stop and report;
  code keeps the shape it would have without the gate. Keep each rewritten spec's original assertion.
- **Reach.** After deleting or renaming a method, `grep -rn` it across `lib/`, `spec/` and `plugins/`;
  `verify-changed` runs only the affected specs.
- **Claims.** The PR body, doc edits and changelog fragment say what the specs pin and no more. Write
  a fragment only when the broken behaviour shipped: `git merge-base --is-ancestor <commit that
  introduced it> <latest tag>`. A binding doc under `docs/type-specification/` or
  `docs/internal-spec/` that describes the changed behaviour changes in the same PR.
- **Closing keywords.** `Fixes #N` only when the PR closes all of #N, on its own line; otherwise
  `Refs #N` in the body and in every commit message.
- **Hand-back.** Push with `git push origin HEAD:refs/heads/<branch>`, open the PR Draft, add the
  fragment as a second push, then report: PR and head SHA, files changed, the mutation table, the
  `verify-changed` result, and every decision the issue left open. Stop and report instead of
  opening a PR when the premise is already fixed or a decision belongs to the maintainer.

## Reviewer contract

The reviewer is a fresh agent that did not write the change. Its brief carries the environment rules
above plus:

- A detached review worktree at the PR's head SHA, removed at the end; no edits, pushes or comments
  on the PR.
- **Probe, not re-run.** For a change that makes Rigor answer something, build the wrong-answer
  shapes as fixtures, run the CLI, and compare against Ruby. Re-run the edge-case table from
  coordinator step 2 when the brief has one.
- **Prove the specs.** Remove each part of the fix and report which examples fail; an example that
  survives every removal is a finding.
- **Report** findings ranked severe / moderate / minor / nit, each with input and wrong output, scope
  expansion listed separately, and a plain statement of whether anything severe remains. Severity is
  defined in [`contribution-flow.md`](contribution-flow.md) § "Landing a pull request".
- A delta round re-checks every earlier finding with its original repro, then hunts for regressions
  the fix introduced.
