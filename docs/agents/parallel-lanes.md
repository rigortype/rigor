# Parallel lanes

Read this before fanning a batch of issues out to subagents: a **lane** is one issue implemented by
one subagent in its own worktree, landed through [`contribution-flow.md`](contribution-flow.md)
§ "Landing a pull request". This file holds what that section leaves to the coordinator: how to
plan the batch, what the coordinator does itself, what every lane and reviewer brief carries, and the
order things land in. A subagent cannot be relied on to follow `AGENTS.md`, so a lane brief tells it to
load the [`rigor-lane`](../../.claude/skills/rigor-lane/SKILL.md) skill first, and a reviewer brief
points at the [reviewer contract](#reviewer-contract) below.

The rules below come from the 27-PR batch of the v0.4.3 milestone (October 2026). Its rework
clustered in five places: specs that passed with the fix removed, Ruby-semantics edge cases found
only in review, claims in docs and changelog fragments wider than the change, gates satisfied by
reshaping code, and lanes that collided or started on a premise master had already fixed.

## What stays in the main loop

The v0.4.6 window (October 2026; one coordinator's share was about 40 of the window's 76 PRs)
measured what a subagent buys. Independent review found a severe defect the implementer had missed in
five PRs (#2286, #2288, #2290, #2295, #2301), and lanes on
disjoint issues ran in parallel; both earn their own context. Everything else lost fidelity in the
hand-off: lanes started on premises master had already fixed, the coordinator's rewrite of a finding
into a fix brief carried its own mistakes, a fresh fixer agent lost the implementer's context, and
full reports from every lane filled the coordinator's context until it was compacted. So the
coordinator keeps these in its own loop and spawns an agent only for implementation and review:

- **Premise checks** (step 1), before any lane starts. A batch of independent issues can be swept by
  one read-only agent that reports a table, which is cheaper than a lane that starts and stops.
- **Small edits after review**: wording in docs and a PR body. Make them yourself on the lane's
  branch by step 7's procedure, only while the lane is idle and has pushed everything, rather than
  resuming the lane for one line. That procedure's temporary worktree has no bundle and runs no
  `verify-changed`, so a code or comment edit in a checked file (a `# sig-gen gap:` marker
  included) goes back to the lane; once the lane has ended, make it in the
  lane's own worktree and push with `bin/lane-push`. Never rewrite a lane's pushed history: a squash
  or rebase makes the lane's next `bin/lane-push` refuse.
- **Rulings, issues and landing**: decide open choices, file scope expansion and a `known-limitation`
  issue for each line under a lane's `Known limits`, run `bin/land-pr`.

Keep what comes back short. Lanes report in the shape the `rigor-lane` skill gives and reviewers in
the shape below; the detail lives in the PR body and the issues, which the coordinator reads only when
a decision needs it.

## Coordinator steps

1. **Check each premise before it enters the batch.** Reproduce the issue on current `origin/master`
   and search for an existing implementation by concept. An issue whose premise is gone leaves the
   batch with a comment pointing at where the behaviour lives. A status comment is not a ledger: for
   a multi-item issue read `gh pr list --state merged --search '#N'` and what each PR says it closes.
   A repro that no longer fires does not make the defect unreachable; probe the other exits of the
   mechanism (a fixpoint's pass cap, guards, jumps) before calling a backstop dead. Done when every
   issue in the batch has a reproduction or a cited code path that shows the defect.
2. **Design first where the answer is semantic.** For a change to Ruby semantics, path or symlink
   handling, cache keys, or anything that makes Rigor answer a new type, the coordinator writes the
   edge-case table into the brief before a lane starts: each input shape, what Ruby does (a
   `nix develop --command ruby -e` witness), and the answer Rigor must give. Shapes that recur:
   symlinked and logical-vs-physical paths, `Complex`/`Rational`/`BigDecimal` numerics, a
   user-defined or refined method of the same name, `send`/`public_send`, nested blocks and loops,
   pool mode (`--workers N`), warm and `--incremental` reruns, and a multi-file project for any change
   to the discovery fold (`scope_indexer.rb`, `scope.rb`), whose cross-file merge a single-file
   fixture never runs. Three more drew a severe review round in October 2026 (#2003, #2016): a block
   that changes `self` (`Class.new`, `Struct.new`, `Data.define`, `Module.new`, `*_eval`,
   `class << self`), where a body-level reading must not count what the block says; a sibling file
   that defines the same name, where file order is not load order; and a statement that may not run
   (inside an `if`, a loop or a block), which must leave the answer uncertain rather than flip it to
   the opposite certain one. Two more did in the v0.4.5 batch: a check that declines must answer the
   narrowest sound type, not fall through to a wider one (a declined `**` reached RBS `Numeric`,
   #2122); and a rule about "another object" must probe a receiver that may be `self` (#2077, four
   rounds). Done when every shape the review would probe has a row.
3. **Map overlap, then batch.** List the modules each issue will touch, and include open PRs from
   other sessions (`gh pr list --state open`, then their files): an issue whose mechanism one of
   them changes waits for it to land or for its owner to hand over the lane. Two issues that change
   the same mechanism (one inference pass, one cache key, one diagnostic channel) run one after the
   other; disjoint ones run up to three at a time, with one heavy job (a corpus `rigor check`) on the
   machine at a time. PRs that regenerate a shared gate file
   (`spec/rigor/declaration_facts/admission_census.yml`, `producers.yml`, ADR-119's errata) also land
   one after another, each regenerating it at its rebase.
4. **Route by difficulty.** Ruby semantics, cache and incremental soundness, and anything from step 2
   go to the strongest model. A contained lane (a crash guard, a marker re-point, a CLI field, a
   config or plugin change, a spec- or doc-only change) goes to the small model; the middle tier
   only when a lane needs more than that, with the reason in the brief. Review is always the
   strongest model. Two batches measured why (ADR-119 PR C, about 20 PRs; v0.4.3, 27 PRs): severe
   review rounds cluster in Ruby-semantics logic whichever model wrote it, so semantics goes to the
   strongest model with Ruby-run witnesses; the small model's misses are posture, not logic (dropping
   an assertion, raising a pin, shaping code for a gate, scope creep), which the `rigor-lane` skill
   names, and its fix-round count matched the middle tier's. Lane wall time is Nix and RSpec, not the
   model.

   A comment-only sweep is contained work but does not check itself. In
   [#2338](https://github.com/rigortype/rigor/pull/2338) (October 2026) 37 small-model lanes trimmed the
   comments of 289 files in the merged diff; every lane reported a clean parse and a comment-only diff. An
   independent review of three shards still found two severe and four moderate errors, all new comments
   asserting something false about the code (a fold boundary one bit off, a regex note a probe disproved, a
   constant name "fixed" into a self-reference), and fourteen minor ones. A delta round then caught a
   severe error in the fix written for the first round's severe finding. A corrected comment is a claim
   about the code, so the reviewer tests it by running the expression (`2 ** 13_606`, the pattern on the
   input) rather than by reading. Have a lane change a comment only where the code confirms the new
   text, and brief it to keep rationale, ADR and issue references and engine notation, and to leave a
   comment it cannot check unchanged.
5. **Brief the lane** with the issue, its worktree (`bin/rigor-worktree <branch> origin/master`, plus
   `--with-references` when a gate the lane runs reads `references/`; see the
   [`rigor-worktree`](../../.claude/skills/rigor-worktree/SKILL.md) skill), any decision the
   coordinator settled, the related issues and any approach already withdrawn (a withdrawn approach
   comes back unless the brief says so), the reporter's name, email and handle for a fix of an
   external report, and a first line telling it to load the
   [`rigor-lane`](../../.claude/skills/rigor-lane/SKILL.md) skill. Do not paste the contract; the
   skill is the one copy. Every brief still carries this floor inline, because a lane that cannot load
   the skill falls back on `AGENTS.md`, which ends a change at its landing: every command through
   `nix develop --command`; never `make verify`, `make check` or the whole suite; `references/`
   read-only; push only with `bin/lane-push`; never `gh pr ready`, a merge or `bin/land-pr`; no version
   bump, `CHANGELOG.md` edit or `rake release`; commit with the configured identity, never `--author=`
   or `GIT_*`; and "if the skill does not load, read it with
   `git show origin/master:.claude/skills/rigor-lane/SKILL.md`; if that fails, stop and report".
   Settle the decisions you can foresee before the lane starts, per contribution-flow.md § "Decisions
   and the approval queue".
6. **Review when the Draft PR lands**, with the [reviewer contract](#reviewer-contract), and triage
   per contribution-flow.md step 3, including the "Engine allocations (advisory)" summary. A PR
   whose allocation delta is above `pr_allocations_pct` (`bench/thresholds.yml`) does not land until
   you have its attribution and either the lane cuts the cost or an approval-queue entry accepts it.
   Accepting one when the release gate's measurement (`make bench-perf` against
   `bench/baseline.json`) would then exceed its band is on contribution-flow.md's serious list.
   #2295's +31% passed as an advisory warning and surfaced only at the v0.4.6 release gate, where
   #2329 had to win it back. Send each fix back to the lane that wrote the change with SendMessage,
   so it keeps its context; do not start a fresh fixer, which re-derives what the lane knew. Route a
   severe fix in intricate logic to the strongest model by resuming the lane on it only when the
   lane already runs that model. Delta rounds go to the same reviewer with SendMessage and follow
   contribution-flow.md steps 4–5: three rounds at most; after round 3, a narrow severe finding with
   a conservative fix lands only through one fix-only delta check that finds nothing severe, and a
   non-converging design goes to the user. When a lane stops at a gate or an open choice, decide it
   per contribution-flow.md § "Decisions and the approval queue" and send the lane the decision with
   its approval-queue entry to commit; only a serious decision goes to the user.
7. **Land through the merge queue** with `bin/land-pr N <reviewed-head-sha>` in the background, as
   soon as the PR may land (contribution-flow.md step 6 and § "GitHub and git traps"); it refuses
   when `master` has no queue, and a PR behind `master` then waits for the user. It is the PR's
   watcher, so start no other. The queue runs CI on the PR merged onto `master` and the PRs ahead of
   it, which is the check of how changes in different files interact (an engine fix on one side
   flipping a pinned answer on the other). So a PR is not re-pushed because `master` moved. Check
   `mergeable` first: a `CONFLICTING` PR starts no CI and cannot enter the queue, so send it back to
   its lane to run `bin/lane-push` and resolve the rebase it stops on; when the lane has ended, run
   `bin/lane-push` in its worktree yourself. A PR the queue drops goes back to its lane like a
   review finding. After the batch, watch the resulting master CI run.
   Watching is bounded by GitHub's API budgets (REST and GraphQL are separate 5000-an-hour budgets
   per user; `gh pr view` spends GraphQL), which a batch of watchers exhausts, and every watcher then
   dies with HTTP 403. Read the verdict per contribution-flow.md § "GitHub and git traps", at most
   once a minute, one watcher per PR, never `gh pr checks` in a loop, and check `gh api rate_limit`
   when watchers fail oddly. To add a commit to a lane's branch yourself, never in the lane's
   worktree or the main clone: `git worktree add --detach <tmp> origin/<branch>`, make the edit,
   commit, `git push origin HEAD:refs/heads/<branch>` (a fast-forward), then `git worktree remove
   --force <tmp>`, and tell the lane with SendMessage to `git fetch && git merge --ff-only
   origin/<branch>` before its next commit. Do it only while the lane has pushed everything;
   otherwise the push rejects or the branches diverge. Rebasing first makes the push
   non-fast-forward.
8. **File the review's scope expansion** as issues outside the milestone. When a merged commit
   carried a `Fixes #N` for an issue the PR only partly fixed, reopen #N with what remains.

## Lane contract

The lane contract is the [`rigor-lane`](../../.claude/skills/rigor-lane/SKILL.md) skill: scope,
environment, gate, mutation table, honest gates, engine cost, reach, claims, decisions, closing
keywords and the hand-back report. Change it there; a second copy here drifts.

## Reviewer contract

The reviewer is a fresh agent on the strongest model that did not write the change. Its brief
carries the base commit, the PR and its issue, the Environment bullet of the `rigor-lane` skill, no
`make verify`, `make check` or whole-suite run, and:

- A detached review worktree at the PR's head SHA with its bundle cloned (`git worktree add --detach
  <path> <sha>`, then from the main clone `mkdir -p <path>/vendor <path>/.bundle && cp -Rc
  vendor/bundle <path>/vendor/bundle && cp .bundle/config <path>/.bundle/`; `cp -Rc` is the macOS
  clone, elsewhere `cp -R --reflink=auto`), removed at the end; no edits, pushes or comments on the
  PR.
- **Probe, not re-run.** For a change that makes Rigor answer something, build the wrong-answer
  shapes as fixtures, run that tree's `bundle exec exe/rigor check --no-cache` with a same-file
  positive control, and compare against Ruby; read [`measurement.md`](measurement.md) first.
  Re-run the edge-case table from coordinator step 2 when the brief has one.
- **Run the precision half too.** For a change to how the engine records ADR-46 dependencies, run
  every `spec/rigor/analysis/*incremental*_spec.rb` that asserts a reader is NOT re-checked
  (`not_to include` on `affected`), not only the new fixture's file: #2136 passed two reviews and
  failed CI twice on those. `verify-changed` runs them for such an edit.
- **Prove the specs.** Remove each part of the fix and report which examples fail; an example that
  survives every removal is a finding.
- **Name the class, not one instance.** When a finding is one spelling of a wider shape (every
  `self`-changing block, every reader of one table), say so and list each instance found, so the
  lane fixes the class in one round instead of one spelling per round.
- **Report** opening with one line, `Severe N | Moderate N | Minor N | Nit N`, and a one-line
  verdict, then the findings ranked severe / moderate / minor / nit, each with a concrete failure
  scenario (for an engine change, the input and the wrong output) and marked *introduced* or
  *pre-existing* (reproduced on the base commit), scope expansion listed separately, and a plain
  statement of whether anything severe remains. Severity is defined in contribution-flow.md §
  "Landing a pull request"; a pre-existing finding is filed, not fixed in the PR, unless the PR's
  change makes it reachable more often.
- A delta round re-checks every earlier finding with its original repro, then hunts for regressions
  the fix introduced.
