# The VS Code extension checks for managed-Rigor updates in the background by default, and installs one only on a click

- **PR:** [#0000](https://github.com/rigortype/rigor/pull/0000)
- **Issue:** [#2746](https://github.com/rigortype/rigor/issues/2746)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

The extension-managed Rigor (#2745, ADR-27 WD10) had only a manual **Rigor: Check for Rigor
Update** command. #2746 asked for background checks after PHPantom's model (`autoUpdate` and
`updateCheckIntervalHours` settings, a newer release installed beside the current one and used on
the next restart) and said "default on", but left open what the default does without a click, how
often it checks, and when it is silent. It is a new feature's default, not a change to an existing
one, so it was decided here.

## Options and trade-offs

- **Off by default.** No network request the user did not ask for; but a first-time user, the only
  user the managed Rigor serves, would stay on the version they first installed, and Rigor ships
  often.
- **On by default, installing silently.** PHPantom's shape: no prompt at all. A `bundle install`
  then runs (compilers, minutes, network) without the user's click, which WD10 rules out for the
  first install ("nothing installs without a click").
- **On by default, asking before installing (taken).** The check is one HTTPS GET to rubygems.org's
  `latest.json`; the install runs only on **Install update**, through the same staging-and-lock path
  as every other install, and takes effect on the next restart, which is offered.

## Decision

`rigor.runtime.autoUpdate` (boolean, default `true`, application scope) and
`rigor.runtime.updateCheckIntervalHours` (number, default 24, clamped to 1–168). A check runs only
while some folder of the window runs the managed Rigor, `rigor.runtime.version` is `latest` (a pin
or a development install never checks), and the workspace is trusted: once 30 s after the first
managed server starts, then on the interval. Each newer version is offered once per session
(**Install update** / **Later**); one another window already installed is offered as a restart. A
network failure logs one line and leaves the install alone. The default follows PHPantom; the click
keeps WD10's no-install-without-a-click rule.

## To undo

Flip `rigor.runtime.autoUpdate`'s default to `false` in `editors/vscode/package.json` and the
`get("runtime.autoUpdate", true)` fallback in `editors/vscode/src/runtime.ts`, and the README,
editor CHANGELOG and ADR-27 WD10 wording. Nothing else depends on it.
