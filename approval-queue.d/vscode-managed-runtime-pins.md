# The VS Code extension reads rigortype pins and Rubies from files, never by running mise, and a global pin counts only while installed

- **PR:** [#2745](https://github.com/rigortype/rigor/pull/2745)
- **Issue:** [#2725](https://github.com/rigortype/rigor/issues/2725)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

The managed Rigor must never serve a project that pins `rigortype`, and must find a Ruby 4.0. The
issue named `mise where ruby@4.0`, and the review suggested `mise ls --current` as the authority for
pins. While building this, one `mise ls --current --json` on the maintainer's machine ran the
configured auto-prune and uninstalled four superseded tool versions. Separately, the maintainer's
global `~/.config/mise/config.toml` pins `gem:rigortype`, so a rule that counts every ancestor
config as a pin made every project under `$HOME` "pinned".

## Options and trade-offs

- Run `mise` (`ls --current`, `where`): authoritative, but any `mise` command may apply the user's
  settings, auto-prune included, which uninstalls tools without asking.
- Read the files: mise's config file names, `conf.d`, the relocated global config and its install
  directory, plus `.tool-versions`. It never changes the machine, but it is a reading of mise's
  rules that can miss a form mise accepts (a key spelled in a TOML shape the line parser skips).
- Global config always a pin: safe, but a global pin that was never installed blocks the managed
  Rigor in every project. Global config never a pin: a user who installed Rigor through a global
  mise pin and whose shim breaks would be silently moved to the managed install.

## Decision

Read files only. The extension's one `mise` invocation is tier B's `mise install ruby@4.0`, after a
click, with a prompt that says mise applies the user's own settings. A pin in the project directory
or its ancestors below `$HOME` always counts. The global config (`$HOME` and above, `MISE_*` /
`XDG_CONFIG_HOME` locations) counts only while a rigortype is installed under mise's or asdf's
install directory.

## To undo

Running `mise` again means restoring a `mise where` / `mise ls` call in `editors/vscode/src/runtime.ts`
and `discovery.ts`. Changing the global rule is the `globalPinInstalled` check in `discovery.ts`, and
the matching sentences in ADR-27 WD10 and the extension README.
