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
- Push with an explicit refspec: `git push origin HEAD:refs/heads/<branch>`.
- PRs start Draft and stay Draft until the user explicitly says they may land, with CI green and no
  standing stop instruction. A stop instruction means `gh pr ready --undo`. Never wait for an author
  approval on the author's own PR.
- Land each audited, green PR opened in the current autonomous session as soon as it may land. If the
  merge is denied, report it immediately. Batch or stack only when the user must adjudicate the set.
- Another session's open PR or uncommitted tree is in-flight: do not commit, rebase, push, merge, or
  build on it until its owner hands over the lane. A green gate is not a handoff.
- A bug-report fix credits the reporter with `Co-Authored-By: Name <email>` on every fix commit,
  including fragments, and `thank you @handle!` in the changelog. Ask for a missing email; never guess.

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
