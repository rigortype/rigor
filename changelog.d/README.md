# Changelog fragments

`[Unreleased]` entries land here as one file per PR, instead of editing `CHANGELOG.md` directly.
GitHub ignores `.gitattributes merge=union` for PR mergeability, so same-anchor `CHANGELOG.md`
edits serialize otherwise-independent PRs — the full story is
[ADR-105](../docs/adr/105-pr-landing-flow.md).

- **Path**: `changelog.d/<section>/<branch-slug>.md`, where `<section>` is one of `added`,
  `changed`, `deprecated`, `removed`, `fixed`, `security` (Keep a Changelog 1.1.0, downcased).
  Create the section directory if it does not exist yet.
- **Content**: one bullet line in the standard entry grammar —
  `- **[subsystem]** One user-facing sentence. ([#N](https://github.com/rigortype/rigor/pull/N))`
  — optionally followed by `  - ` child items. Write it right after `gh pr create`, when the PR
  number exists. Full entry rules: the `rigor-release-prep` skill.
- Release prep consolidates every fragment into `CHANGELOG.md` at the cut and deletes it; only
  release prep writes `[Unreleased]`.
- **Gate**: `spec/docs/changelog_fragments_spec.rb`.
