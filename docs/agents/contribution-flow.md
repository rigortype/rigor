# Contribution and release flow

Read this only when a task commits, pushes, opens or lands a PR, changes release metadata, or writes
a changelog entry. It is the conditional detail pointed to by `AGENTS.md`.

## Commits and GitHub Markdown

- Use an imperative sentence-case commit subject without Conventional-Commits prefixes. Wrap the
  commit body at about 72 columns and explain why, not the diff.
- Do not wrap paragraphs or list items in GitHub-rendered Markdown: GitHub turns single newlines into
  `<br>`. Tables, headings, and fenced code keep their own lines.
- Version-bump commits use `Bump up version to x.y.z`.
- A PR or issue body says what the change does and why, as a commit message would. It does not
  narrate how the PR was assembled (one PR or a stack, which tool, why a rebase).

## Branches and pull requests

- **Small, uncontroversial docs** — a typo, a one-line fix, a `docs/CURRENT_WORK.md` update — commit
  straight to `master` (a skill takes this path only for a typo-class fix; see
  [`skill-authoring.md`](skill-authoring.md) § "The `waza` review"); CI skips an all-`.md` push, so a
  PR here buys nothing but a redundant run.
  **Anything larger** — a multi-point revision, a new document, a reorganization — is a change worth
  reviewing like any other: branch + PR. Touching even one non-`.md` file makes it code regardless of
  size: branch + PR. When unsure which side a change is on, default to a branch — the direct-push
  path is the one that's expensive to undo.
- Name a branch for the change it makes, not the tool that made it: no `claude/`, `codex/`, or other
  tool-identifying prefix. Renaming a branch that already has an open PR is not safe — it can close
  the PR outright — so get the name right at creation instead of fixing it after (recovery:
  § "GitHub and git traps").
- Push a PR branch with `bin/lane-push`: it rebases onto a freshly fetched `origin/master`, reruns
  `verify-changed` on the result, and pushes with an explicit refspec and a lease. By hand, push with
  an explicit refspec, `git push origin HEAD:refs/heads/<branch>`, never `-u`; the
  [`rigor-worktree`](../../.claude/skills/rigor-worktree/SKILL.md) skill says why and how to recover.
- PRs start Draft and land through § "Landing a pull request" below. A stop instruction from the
  user means `gh pr ready --undo` and no merge. Never wait for an author approval on the author's
  own PR.
- Land each PR opened in the current session as soon as it may land; if the merge is denied, report
  it immediately. Batch or stack only when the user must adjudicate the set.
- Another session's open PR or uncommitted tree is in-flight: do not commit, rebase, push, merge, or
  build on it until its owner hands over the lane. A green gate is not a handoff.
- A bug-report fix credits the reporter with `Co-Authored-By: Name <email>` on every fix commit,
  including fragments, and `thank you @handle!` in the changelog. Ask for a missing email; never guess.
  Give the credit when committing. A plan, brief or handoff may say that a fix traces to a report and
  pass the trailer on, but never lists the credit as a task, checklist item or "must": that reads as
  discourteous to the reporter. Trace an AI-filed issue back to the human report it came from.
- Commit with the repository's configured identity. Never pass `--author=` or set `GIT_AUTHOR_*` /
  `GIT_COMMITTER_*`: in September 2026 subagent commits carried the maintainer's private address and
  had to be rewritten (#628). Lane briefs repeat this.
- Put each `Fixes #N` on its own line. GitHub parses only the first reference in a comma-separated
  `Fixes #a, #b, #c`, silently leaving the rest open, and a later session reads them as backlog.
- A spec that pins behaviour you believe is wrong carries an in-place `flip this when #N is fixed`
  comment. Without it the next reader has to re-derive whether the assertion or the engine is the
  bug — and a batch of PRs touching disjoint files can still turn `master` red when one of them
  fixes what another pinned, which no single PR's CI can see.

## GitHub and git traps

Each of these fails silently: the command succeeds and reports something plausible and wrong.
General shell traps are in [`measurement.md`](measurement.md) § "Shell commands that answer wrong
silently".

- **An empty PR body.** `gh pr edit N --body "$var"` with an empty `$var` blanks the body. Pass
  `--body-file`, or guard `[ -n "$var" ]`.
- **CI verdict.** `gh pr checks --watch` exits 1 with "no checks reported" when a push cancels the
  earlier run, and it watches only the check set present when it started. Read the head commit's run
  instead: find its id in `gh run list --branch <branch>` by matching `headSha` (`gh run list
  --commit` needs the full SHA; a short one returns `[]`). `gh run watch <id> --exit-status` can
  return while jobs are still running, so poll `gh run view <id> --json status` until it reads
  `completed`, then read `conclusion` and `headSha`. The same check applies to the master run after
  a merge. `gh pr view --json merged` is not a field; read `state`, `mergedAt` or `mergeCommit`.
- **Stacked PRs.** Delete a parent branch only after the parent reads `MERGED` and its merge commit is
  an ancestor of `origin/master`: a queued parent is not merged yet, and deleting a queued PR's branch
  closes it. That applies to both kinds below. Two kinds of stack. A GitHub-native stack (`gh stack`)
  needs no retargeting: GitHub retargets the next PR to `master` when the bottom one merges (observed
  on #2200 after #2194). Run `bin/land-pr` on the next PR only after the one below has merged and
  GitHub has retargeted it to `master`; it refuses a PR whose base is not `master`. Never use
  `gh stack merge`: it queues without the reviewed-SHA and `CI required` checks. Queue each stacked PR
  with `bin/land-pr`.
  For a hand-made base chain: a child merged while its base is still the parent branch reports MERGED,
  but its commits land on that branch, never reach `master`, and its `Fixes` never fires. Deleting a
  parent branch closes its stacked child instead of retargeting it. So land the parent (`bin/land-pr`
  deletes no branch), retarget each child yourself (`gh pr edit <child> --base master`), delete the
  parent branch under the rule above, then merge the child. Prove each landing against `origin/master`
  (see "Cleanup after a merge" below), not by the PR state.
- **A head ref that vanished.** When an open PR's head branch was renamed or deleted, the PR closes
  and `gh pr reopen` fails until the ref exists again: push the old SHA back to the old name, reopen,
  and retarget a stacked child with `gh pr edit --base master`.
- **Squashing.** Never `git reset --soft origin/master`: other sessions' fetches move that ref, and
  the commit then reverts every PR merged in between while CI stays green. Reset to `git merge-base
  HEAD origin/master`, and before pushing check that `git diff --stat origin/master...HEAD` lists
  only your files.
- **Re-applying a reverted change.** On a branch that already contains the commit as an ancestor, a
  rebase replays nothing and fast-forwards onto the revert; cherry-pick it instead.
- **Cleanup after a merge.** Remove a worktree or local branch only once the PR's content is on
  `origin/master`: `gh pr view N --json state,baseRefName,mergeCommit` must read `MERGED` with base
  `master`, and `git merge-base --is-ancestor <mergeCommit.oid> origin/master` must exit 0. This holds
  for merge-commit, `--rebase` and `--squash` landings alike; after a rebase or squash the head SHA
  itself is never an ancestor, and a child merged into its parent branch fails on `baseRefName`.
  Chain the removal after `bin/land-pr` only with `&&`, never `;` (a refused merge still runs the
  rest of the line), and never after `--no-wait`, which exits 0 while the PR is still queued.
- **The merge queue.** Queue a PR with `bin/land-pr N <reviewed-head-sha>`, not `gh pr merge`: gh
  enqueues through the auto-merge API, which this repository keeps off, and fails with "Auto merge
  is not allowed". `bin/land-pr` queues only the head that was reviewed (a commit pushed since is
  refused; pass the SHA the reviewer reported on, never one read back from the PR), checks that
  head's `CI required` passed, and refuses when `master` has no merge queue (nothing would then test
  the merged result; stop and tell the user). It then polls once a minute until the PR merges (exit
  0, merge commit printed) or leaves the queue (exit 1), and it is that PR's one watcher. For a PR in
  a native stack it falls back to the asynchronous merge REST API, and `--no-wait` can return while
  that request is still pending. A wait
  outlasts a foreground command (the queue batches for up to five minutes and CI takes about
  twelve), so run it in the background; run again on a queued PR, it only waits. When the merged
  tree is one a `pull_request` run into `master` passed `CI required` on (its signed `Tested tree`
  attestation, from a branch of this repository; usually because the head already contained
  `master`), the queue run reuses that result and finishes in
  about a minute ([ADR-123](../adr/123-merge-queue-and-post-hoc-approval.md), amended 2026-10-19);
  otherwise it runs the full CI. A dropped PR stays
  `OPEN` exactly as a queued one does: read the failed run in `gh run list --event merge_group`, or
  the new push or manual removal that took it out, and fix it on the branch. Never `gh pr merge
  --admin`: it skips the queue and its check.
- **Mergeability lags a push.** When `git merge-base --is-ancestor origin/master origin/<branch>`
  confirms the branch contains master, a "Head branch is out of date" refusal clears on its own;
  retry with backoff rather than merging `master` in again.
- **The main clone is shared.** Uncommitted edits in it follow every branch switch and are swept in
  by the next `git add -A`. Each parallel worker gets its own worktree.

## Landing a pull request

Once the change is implemented and `make verify-changed` passes:

1. **Push and open the Draft PR.** CI starts on the push and is the full gate; read the result for
   the head commit, not the branch (how: § "GitHub and git traps"). The changelog fragment needs the
   PR link, so it is a second push.
2. **Start the adversarial review at the same time**, not after CI: the two are independent, and a
   later push re-runs CI anyway, and the merge queue runs it once more on the merged result. The
   reviewer is a fresh agent that did not write the change, on the
   strongest model the harness offers — Claude Opus 5.5 under Claude Code; elsewhere a model of that
   class, such as Claude Opus 4.6 at high effort. A harness that offers neither uses its strongest
   model at its highest effort; one that cannot start a separate agent says so in the PR and leaves
   it Draft — the review is never skipped silently. Give the reviewer the base commit, the PR and its
   issue, and this repository's rules (the Flake, read-only `references/`, no local full gates, the
   release gate — a subagent does not inherit them). Ask for findings ranked by severity, each with
   a concrete failure scenario, and scope expansion labelled separately; the batch version of this
   brief is the reviewer contract in [`parallel-lanes.md`](parallel-lanes.md). A PR that changes a skill
   also runs the `waza` review in [`skill-authoring.md`](skill-authoring.md) at the same time; its
   findings join this triage.
3. **Triage.** For a PR that changes the engine, read the "Engine allocations (advisory)" job's summary
   too: it stays green when it warns, so `gh pr checks` does not show it. A warning is a finding, fixed
   or answered with the reason in a PR comment like any other. Fix correctness defects and test gaps.
   Fix text and nits without calling for another round. File scope expansion as issues rather than
   growing the PR. Answer a finding you reject with the reason in a PR comment; rejecting a *severe*
   finding is a serious decision (§ "Decisions and the approval queue"), so the PR stays Draft.
   Severity is the reviewer's ranking, not
   the implementer's. Severe means what AGENTS.md's false-positive rule weighs: a diagnostic on correct
   code, a wrong inferred type, a crash, a gate that passes without checking, or guidance that would
   lead an agent into a wrong irreversible or gate-skipping action (a merge, a push, a publish, a
   skipped gate). Imprecise or unclear wording is not severe.
4. **Another round only if this round's fixes addressed a severe defect or changed behaviour.** Make it a
   delta review of the fix commits: re-check each prior finding and hunt for regressions the fix
   introduced. In the September 2026 review logs (167 PRs), 63% of the severe defects found in
   rounds 2 and later had been introduced by the previous round's fixes, and a round after a severe
   finding found another half the time, against 16% after a round without one. A fix for a
   non-severe finding that changes behaviour rather than wording or specs gets the same delta
   review; it counts toward the three rounds. In the v0.4.3 batch each of these (#1884, #1890,
   #1894) found a further gap worth fixing before merge.
5. **Stop at three rounds.** When round 3 still finds a severe defect, first ask whether the design is
   converging. If any severe finding is another spelling of a gap an earlier round fixed, or has no
   conservative fix, hold the PR as Draft: the user chooses whether to take a conservative reading,
   split the PR, or file the rest. Otherwise every severe finding is narrow and has a conservative fix,
   one that only moves toward saying less or checking more (in the engine, drops a diagnostic or widens
   an inferred type toward `Dynamic`; in a gate, checks more; in guidance, holds or asks more) and
   changes nothing beyond it and its own specs and spec text. Apply those fixes and run one delta
   review limited to the fix commits, asking the reviewer to confirm each fix is conservative. If it
   finds nothing severe and confirms every fix as conservative, merge per step 6; otherwise the PR
   stays Draft for the user. A non-severe finding from that check is fixed only in wording or specs;
   anything that would change behaviour is filed as an issue. Other fixes made after round 3 land
   without another round.
6. **Merge through the queue** (`gh pr ready`, then `bin/land-pr N <reviewed-head-sha>`; see
   § "GitHub and git traps") once CI is green on the head commit and the review has stopped, and
   when the landing point is settled: a `ready-for-agent` issue, a user request that states the
   expected outcome, or every decision the PR embodies made under § "Decisions and the approval
   queue" below. A PR need not contain the latest `master` to be queued; the queue tests the merged
   result. Re-push it (`bin/lane-push`) only when it is `CONFLICTING`, which starts no CI and
   cannot enter the queue, or when the queue drops it. A PR that changes a skill also needs its
   `waza` review comment; until one is posted it stays Draft. A PR carrying a serious decision
   stays Draft until the user makes it. A skill with its own landing rule (`rigor-release-prep`,
   `rigor-dependency-update`) keeps that rule; the review in steps 2–5 still runs.

## Decisions and the approval queue

Work regularly needs a decision nobody has made yet: a gate row, a reading the issue left open, a
part of an issue to defer. Make the ones below the line yourself, following precedent, land them,
and record each for the user to ratify at release time; stop and ask before landing only the
serious ones. The reasoning is [ADR-123](../adr/123-merge-queue-and-post-hoc-approval.md).

**Serious — ask the user first; the PR stays Draft until they answer:**

- a release, a version bump, publishing, or anything `rake release` does;
- a default users see change behaviour under: a rule on or off by default, a default severity, a
  default flag or config value (#120);
- a breaking change to a public contract: a CLI option, exit code or output format, a
  configuration key, the plugin API;
- a new cache format, native code, or a new runtime dependency (ADR-31);
- a new ADR decision, or an amendment that reverses an Accepted one;
- a gate that checks less: deleting or loosening a check, skipping the review, `--no-verify`
  without a pre-existing issue, or an allow-list row or a residue pin moving up where no precedent
  of the same kind exists (the same gate file, for the same kind of reason);
- this section itself, the approval-queue gate (`spec/docs/approval_queue_spec.rb` and its CI
  step), or the ratification step in `rigor-release-prep`;
- repository, organisation or CI settings: required checks, rulesets, secrets, permissions;
- rejecting a severe review finding, or a design still not converging after round 3 (§ "Landing a
  pull request" steps 3 and 5);
- a `ready-for-human` issue, or anything the user said to bring back to them.

**Everything else — decide, land, record.** Follow the closest precedent: a ratified entry, a
merged PR whose decision the user approved, or an ADR. An entry still waiting in the queue is not
a precedent. Where none fits and the decision is not serious, take your own recommendation and say
it sets a precedent; a `gate-row` never sets one, because a gate row without a precedent is
serious. Then add an entry under
[`approval-queue.d/`](../../approval-queue.d/README.md) in the same PR: why a decision was needed,
the options and their trade-offs, the precedent, and how to undo it. Write it for a reader who was
not there. Tell the user about the decision in your report as well; the entry is what remains
when the session is gone.

No entry is needed for a decision that only tightens (a residue pin moving down, a check that now
checks more) or that writes down an outcome a `ready-for-agent` issue already stated.

## Release Cadence

- The only release path is the user's explicit `/rigor-release-prep` invocation. A date or release
  goal is context only; otherwise leave versioned metadata and `[Unreleased]` untouched, and end by
  saying the cut is one `/rigor-release-prep` away. The gate exists for rhythm: when every landed
  batch was followed by a version bump (v0.0.5 to v0.0.8), releases came too close together to each
  carry user-visible value. A release cut without being asked (0.3.8, read from "release by 11
  o'clock") is a trust failure, not a process slip.
- Never run `bundle exec rake release` without explicit authorization: it tags, pushes, and publishes.
- A release ships only ratified decisions: `/rigor-release-prep` reports
  [`approval-queue.d/`](../../approval-queue.d/README.md) first, and the release waits until it holds
  nothing but its README.
- Release prep alone changes `Rigor::VERSION`, released `CHANGELOG.md` sections, `Gemfile.lock`, and
  the README status line. Version components are single-digit and carry recursively (`0.0.9` → `0.1.0`).
- At landing, put one user-facing sentence and its full PR link in
  `changelog.d/<section>/<branch-slug>.md`, with `<section>` in `added changed deprecated removed fixed
  security`. Release prep consolidates fragments into `[Unreleased]`; ordinary work does not edit that
  section directly. The fragment gate is `spec/docs/changelog_fragments_spec.rb`.
