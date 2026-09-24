# Contribution and release flow

Read this only when a task commits, pushes, opens or lands a PR, changes release metadata, or writes
a changelog entry. It is the conditional detail pointed to by `AGENTS.md`.

## Commits and GitHub Markdown

- Use an imperative sentence-case commit subject without Conventional-Commits prefixes. Wrap the
  commit body at about 72 columns and explain why, not the diff.
- Do not wrap paragraphs or list items in GitHub-rendered Markdown: GitHub turns single newlines into
  `<br>`. Tables, headings, and fenced code keep their own lines.
- Version-bump commits use `Bump up version to x.y.z`.

## Branches and pull requests

- **Small, uncontroversial docs** — a typo, a one-line fix, a `docs/CURRENT_WORK.md` update — commit
  straight to `master`; CI skips an all-`.md` push, so a PR here buys nothing but a redundant run.
  **Anything larger** — a multi-point revision, a new document, a reorganization — is a change worth
  reviewing like any other: branch + PR. Touching even one non-`.md` file makes it code regardless of
  size: branch + PR. When unsure which side a change is on, default to a branch — the direct-push
  path is the one that's expensive to undo.
- Name a branch for the change it makes, not the tool that made it: no `claude/`, `codex/`, or other
  tool-identifying prefix. Renaming a branch that already has an open PR is not safe — it can close
  the PR outright — so get the name right at creation instead of fixing it after.
- Push with an explicit refspec: `git push origin HEAD:refs/heads/<branch>`.
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

## Landing a pull request

Once the change is implemented and `make verify-changed` passes:

1. **Push and open the Draft PR.** CI starts on the push and is the full gate; read the result for
   the head commit, not the branch. The changelog fragment needs the PR link, so it is a second
   push.
2. **Start the adversarial review at the same time**, not after CI: the two are independent, and a
   later push re-runs CI anyway. The reviewer is a fresh agent that did not write the change, on the
   strongest model the harness offers — Claude Opus 5.5 under Claude Code; elsewhere a model of that
   class, such as Claude Opus 4.6 at high effort. A harness that offers neither uses its strongest
   model at its highest effort; one that cannot start a separate agent says so in the PR and leaves
   it Draft — the review is never skipped silently. Give the reviewer the base commit, the PR and its
   issue, and this repository's rules (the Flake, read-only `references/`, no local full gates, the
   release gate — a subagent does not inherit them). Ask for findings ranked by severity, each with
   a concrete failure scenario, and scope expansion labelled separately.
3. **Triage.** Fix correctness defects and test gaps. Fix text and nits without calling for another
   round. File scope expansion as issues rather than growing the PR. Answer a finding you reject
   with the reason in a PR comment; rejecting a *severe* finding is a decision for the user, so the
   PR stays Draft. Severity is the reviewer's ranking, not the implementer's. Severe means what
   AGENTS.md's false-positive rule weighs: a diagnostic on correct code, a wrong inferred type, a
   crash, a gate that passes without checking, or guidance that would lead an agent into a wrong
   irreversible or gate-skipping action (a merge, a push, a publish, a skipped gate). Imprecise or
   unclear wording is not severe.
4. **Another round only if this round's fixes addressed a severe defect.** Make it a
   delta review of the fix commits: re-check each prior finding and hunt for regressions the fix
   introduced. In the September 2026 review logs (167 PRs), 63% of the severe defects found in
   rounds 2 and later had been introduced by the previous round's fixes, and a round after a severe
   finding found another half the time, against 16% after a round without one.
5. **Stop at three rounds.** If round 3 still finds a severe defect the design is not converging:
   stop and ask the user whether to take a conservative reading, split the PR, or file the rest.
6. **Merge** (`gh pr ready`, then `gh pr merge --merge`) once CI is green on the head commit and the
   review has stopped — when the landing point was settled before the work began: a
   `ready-for-agent` issue, or a user request that states the expected outcome. When the PR instead
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
