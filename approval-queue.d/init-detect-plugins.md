# rigor init suggests the Gemfile.lock plugins as comments, not active entries

- **PR:** [#2557](https://github.com/rigortype/rigor/pull/2557)
- **Issue:** [#2536](https://github.com/rigortype/rigor/issues/2536)
- **Class:** open-choice
- **Precedent:** [ADR-96](../docs/adr/96-plugin-target-gems.md)
- **Decided:** 2026-11-01

## Background

ADR-0 section 4 (Smart Initialization, `docs/adr/0-concept.md`) says `rigor init` will analyse `Gemfile.lock` and suggest and configure the plugins a project needs, such as Rails and RSpec. Its status note recorded the goal as not built, and `rigor init` wrote an empty `plugins:` list, so a user who did not run `rigor doctor` got false positives from the first `rigor check` on a Rails or RSpec project. Issue #2536 asked for `rigor init` to use `PluginGapAdvisory` to fill the list. Its Done-when allows the entries to be commented.

The first version wrote the matching plugins as active entries. Review found that this runs a plugin's code on the strength of a lockfile alone, which ADR-96 Criterion 2 (Accepted) does not allow without the user's explicit opt-in.

## Options and trade-offs

- **Commented suggestions under `plugins: []` (taken).** Nothing loads until the user acts, and the detection still tells them what their stack needs. The cost is one manual step: delete the `[]` on the `plugins:` line and uncomment the entries, then run `rigor plugins --strict`.
- **Active entries.** The project gets the plugins on the first run. This loads plugin code the user has not chosen, which ADR-96 Criterion 2 rules out without opt-in, and a Rails lockfile yields about ten entries the user may not want.
- **A prompt during init.** Interactive, which `rigor init` does not do today, and it breaks the non-interactive CI use the command already has.

## Decision

Commented suggestions. ADR-96 Criterion 2 is the reason: a lockfile's presence is evidence for advice, not for running a plugin. The issue's Done-when already allows the commented form, so this is the reading it names rather than a new one. `plugins: []` stays a valid, schema-clean list at every step.

## To undo

Make the detected entries active again by writing them under `plugins:` instead of as comments, which would need ADR-96 Criterion 2 to be revisited first. Reverting to no suggestions means `detected_plugins` returns `[]` in `run_init`. Projects that already ran `rigor init` keep whatever they wrote; nothing reads the comment back. The `--no-plugins` flag, the next-steps branch and the manual section go with it.
