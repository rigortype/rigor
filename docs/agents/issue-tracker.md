# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues on `rigortype/rigor`. Use the `gh` CLI for all
operations; it infers the repo from the clone.

**GitHub Issues is the backlog** ([ADR-98](../adr/98-development-flow-document-roles.md)): every
mid/long-term work item lives here, not in a tracked markdown file. Release planning is the
**Milestones** surface (`v0.3.0`, `v1.0.0`) — "what the next cut carries" is expressed by assigning
issues to a milestone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line
  bodies. Apply one `area:*` label and one triage label (see `triage-labels.md`).
- **Read an issue**: `gh issue view <number> --comments`.
- **List issues**: `gh issue list --state open --json number,title,labels` with `--label` /
  `--milestone` filters.
- **Comment**: `gh issue comment <number> --body "..."`.
- **Labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."` — when work lands, close from the PR
  (`Closes #N`) so the trail survives.
- Issue bodies are **self-contained**: backticked repo paths (`docs/adr/50-...md`), `#N` references,
  and the acceptance gate if one exists. A future reader has only the issue.

## Pull requests as a triage surface

**PRs as a request surface: yes.** This repo develops in public and an external PR is a feature
request with code attached; `/triage` runs external PRs through the same labels and states as issues.

- **Read a PR**: `gh pr view <number> --comments`, `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`,
  keeping only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE`
  (drop `OWNER` / `MEMBER` / `COLLABORATOR` — collaborators' in-flight PRs are left alone).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label` / `--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs — resolve a bare `#42` with `gh pr view 42`,
falling back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.
