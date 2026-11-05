# The type_of shadow runs in CI as an advisory step over lib and the fixtures

- **PR:** [#2880](https://github.com/rigortype/rigor/pull/2880)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** process
- **Precedent:** none — sets one
- **Decided:** 2026-11-06

## Background

ADR-129 WD5 says G1 runs in CI beside `RIGOR_MEMO_AUDIT` over `lib`, the integration fixtures and the plugin fixtures,
and on a sample of Mastodon. Stage 3 runs the shadow form. The ADR does not say when the step becomes a gate or how a
run that shadowed nothing is told apart from a clean one.

## Options and trade-offs

- **Advisory now, a gate in its own PR** once the stage-3 corpus runs show zero mismatches, over `lib` and the
  integration fixtures only; Mastodon and Redmine stay local runs. The CI cost stays bounded (about a minute and a half
  on a developer machine), and a failure shows as a warning and in the job summary without blocking unrelated PRs while
  stage 3 is still classifying.
- **A gate at once:** stops every PR on a shadow finding before stage 3 has classified the corpora.
- **Mastodon in CI:** needs the corpus checked out in CI, out of proportion for an advisory step.

## Decision

The advisory step in the acceptance job, after the memo audit, with one report per run, judged by
`tool/type_of_shadow_report.rb`, which fails a missing, empty or unreadable report and a run that checked no would-be
hit, so neither run can drop out unseen. The landing loop's triage step names the step's summary, since
`continue-on-error` keeps the job green.
The plugin fixtures join when the step becomes a gate. This follows the coordinating session's direction for stage 3.

## To undo

Remove the step and the report tool, or drop `continue-on-error` to make it a gate.
