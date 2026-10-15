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
- Push with an explicit refspec: `git push origin HEAD:refs/heads/<branch>`, never `-u`; the
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
- Put each `Fixes #N` on its own line. GitHub parses only the first reference in a comma-separated
  `Fixes #a, #b, #c`, silently leaving the rest open, and a later session reads them as backlog.
- A spec that pins behaviour you believe is wrong carries an in-place `flip this when #N is fixed`
  comment. Without it the next reader has to re-derive whether the assertion or the engine is the
  bug — and a batch of PRs touching disjoint files can still turn `master` red when one of them
  fixes what another pinned, which no single PR's CI can see.

## GitHub and git traps

Each of these fails silently: the command succeeds and reports something plausible and wrong.

- **CI verdict.** `gh pr checks --watch` exits 1 with "no checks reported" when a push cancels the
  earlier run, and it watches only the check set present when it started. Read the head commit's run
  instead: find its id in `gh run list --branch <branch>` by matching `headSha` (`gh run list
  --commit` needs the full SHA; a short one returns `[]`). `gh run watch <id> --exit-status` can
  return while jobs are still running, so poll `gh run view <id> --json status` until it reads
  `completed`, then read `conclusion` and `headSha`. The same check applies to the master run after
  a merge. `gh pr view --json merged` is not a field; read `state`, `mergedAt` or `mergeCommit`.
- **Stacked PRs.** A child merged while its base is still the parent branch reports MERGED, but its
  commits land on that branch, never reach `master`, and its `Fixes` never fires. Deleting a parent
  branch closes its stacked child instead of retargeting it. So merge the parent without
  `--delete-branch`, retarget each child yourself (`gh pr edit <child> --base master`), delete the
  parent branch only after that, then merge the child. Prove each landing against `origin/master`
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
  Never chain the removal after `gh pr merge` with `;`: a refused merge still runs the rest of the
  line.
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
   later push re-runs CI anyway. The reviewer is a fresh agent that did not write the change, on the
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
   finding is a decision for the user, so the PR stays Draft. Severity is the reviewer's ranking, not
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
5. **Stop at three rounds.** When round 3 still finds a severe defect, the next step depends on its
   shape. A narrow finding with a conservative fix (one that only declines or widens more, and
   touches nothing else) lands: apply the fix, run one delta review limited to the fix commits, and
   merge if it finds nothing severe; otherwise the PR stays Draft for the user. A finding that
   shows the design is not converging (each round finds another spelling of the same gap) holds the
   PR as Draft, and the user chooses whether to take a conservative reading, split the PR, or file
   the rest. Other fixes made after round 3 land without another round.
6. **Merge** (`gh pr ready`, then `gh pr merge --merge`) once CI is green on the head commit and the
   review has stopped — when the landing point was settled before the work began: a
   `ready-for-agent` issue, or a user request that states the expected outcome. A PR that changes a
   skill also needs its `waza` review comment; until one is posted it stays Draft. When the PR instead
   embodies a decision nobody has made, leave it Draft and put the decision to the user: a
   `ready-for-human` issue, a trade-off between designs, an ADR, a spec edit that picks what the
   issue left open (writing down behaviour the issue already stated is settled), or a severe finding
   you rejected. Anything not settled by one of the former stays Draft; naming an issue adopts its
   outcome only when it is `ready-for-agent`. A skill with its own landing rule
   (`rigor-release-prep`, `rigor-dependency-update`) keeps that rule; the review in steps 2–5 still
   runs.

## Release Cadence

- The only release path is the user's explicit `/rigor-release-prep` invocation. A date or release
  goal is context only; otherwise leave versioned metadata and `[Unreleased]` untouched.
- Never run `bundle exec rake release` without explicit authorization: it tags, pushes, and publishes.
- Release prep alone changes `Rigor::VERSION`, released `CHANGELOG.md` sections, `Gemfile.lock`, and
  the README status line. Version components are single-digit and carry recursively (`0.0.9` → `0.1.0`).
- At landing, put one user-facing sentence and its full PR link in
  `changelog.d/<section>/<branch-slug>.md`, with `<section>` in `added changed deprecated removed fixed
  security`. Release prep consolidates fragments into `[Unreleased]`; ordinary work does not edit that
  section directly. The fragment gate is `spec/docs/changelog_fragments_spec.rb`.
