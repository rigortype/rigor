# rigor init writes the bundled plugins Gemfile.lock declares as active entries

- **PR:** [#2557](https://github.com/rigortype/rigor/pull/2557)
- **Issue:** [#2536](https://github.com/rigortype/rigor/issues/2536)
- **Class:** open-choice
- **Precedent:** [ADR-96](../docs/adr/96-plugin-target-gems.md)
- **Decided:** 2026-11-01

## Background

ADR-0 section 4 (Smart Initialization, `docs/adr/0-concept.md`) says `rigor init` will analyse `Gemfile.lock` and suggest and configure the plugins a project needs, such as Rails and RSpec. Its status note recorded the goal as not built; the `rigor-project-init` skill and `rigor doctor` had taken over the job. `rigor init` itself wrote an empty `plugins:` list, so a user who did not run `rigor doctor` got false positives from the first `rigor check` on a Rails or RSpec project. Issue #2536 asked for `rigor init` to use `PluginGapAdvisory` to fill the list.

Filling the list needed a choice the issue left open: whether the detected plugins are written as active entries, or as commented-out lines the user uncomments.

## Options and trade-offs

- **Active entries (taken).** The project gets the plugins it depends on on the first run. The cost is that a user who does not want one must delete its line, and a Rails lockfile yields about ten entries, since `rails` expands to the Rails family through `UMBRELLA_GEMS`.
- **Commented-out entries.** Nothing loads until the user acts, so the false positives the issue describes remain until someone reads the file. It is the safer default for loading, but the detection then informs without configuring.
- **A new prompt during init.** Interactive, which `rigor init` does not do today, and it breaks the non-interactive CI use the command already has.

Each detected plugin is a bundled one whose `target_gems:` the lockfile declares. An active entry loads at the next `rigor check`; a commented one loads nothing until the user uncomments it.

## Decision

Active entries, with a comment above the list saying they were detected from `Gemfile.lock` and that the user may remove any. The issue asks for the matching plugins to be written, and the fix is only useful if the first `rigor check` runs with them. The comment and the `--no-plugins` flag keep the choice reversible at init time. The precedent is ADR-96's gap advisory, which already treats a declared gem with no enabled plugin as the case to act on, but its own text keeps the advisory as advice; this entry turns the same read into configuration, which is the step ADR-96 did not take.

## To undo

Revert the detection in `run_init` (`detected_plugins` returning `[]`) to restore the empty list. Projects that ran `rigor init` between this change and the revert keep the entries they were given, since nothing reads the comment back. The `--no-plugins` flag and the next-steps branch go with it. The manual section and ADR-0 status note need the same edit.
