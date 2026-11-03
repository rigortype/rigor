# ADR-27's pinned bundle lives at `.github/rigor/`, and the editor-managed install is its own WD10

- **PR:** [#2745](https://github.com/rigortype/rigor/pull/2745)
- **Issue:** [#2725](https://github.com/rigortype/rigor/issues/2725)
- **Class:** open-choice
- **Precedent:** [ADR-27](../docs/adr/27-tool-distribution-model.md)
- **Decided:** 2026-11-04

## Background

On 2026-11-04 the maintainer decided the policy: a committed, Rigor-only pinned bundle becomes a
documented channel below the version manager, and the VS Code extension's managed install is its
per-user form. That decision is the maintainer's and needs no ratification. Two calls in writing it
up were left to the agent: which single path the pinned bundle uses (the policy review listed
`.github/rigor/` and `tools/rigor/` as open), and how ADR-27 records the two forms.

## Options and trade-offs

- Path `.github/rigor/`: already used by the CI template (ADR-27 WD3's CI-only `Gemfile`, manual chapter 11), the
  `rigor-ci-setup` skill and the Dependabot snippet, so nothing existing moves. It reads as
  CI-specific to someone who runs it locally.
- Path `tools/rigor/`: reads as a general tool directory (composer-bin-plugin style), but every
  existing document, the skill and users' Dependabot configs would have to move or carry both.
- One WD with a subsection for the editor form, or WD9 (pinned bundle) plus WD10 (editor-managed
  bundle). Two WDs give each its own acceptance criteria and revisit triggers, which differ.

## Decision

`.github/rigor/`, by precedent: it is the path users already have. WD9 records the pinned bundle and
WD10 the editor-managed form, each cross-referencing the other; WD1 now points to WD9 instead of
ruling the isolated bundle out.

## To undo

Moving to `tools/rigor/` changes WD9, manual chapters 01 and 11, the `rigor-ci-setup` skill, the
extension's pin detection (`editors/vscode/src/discovery.ts`) and the follow-ups #2750 and #2751.
Folding WD10 into WD9 is a text change only.
