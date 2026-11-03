# The rigor check matcher resolves relative paths against rigor.rootDir, and rejects an absolute rootDir

- **PR:** [#2739](https://github.com/rigortype/rigor/pull/2739)
- **Issue:** [#2723](https://github.com/rigortype/rigor/issues/2723)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

Issue #2723 asked for a `$rigor` problem matcher for `rigor check` output and left the file-location form to the implementer. Two facts decided it, both checked in the Extension Development Host.

First, the CLI prints paths in two forms. With a `paths:` list in `.rigor.yml`, findings print absolute. With no `paths:`, the default `lib` is used and findings print relative to the project root, as `lib/a.rb:2:3`. Config diagnostics such as `.rigor.yml:1:1` are relative to the project root too. The issue's premise that paths are always project-root-relative holds only for the second case.

Second, the task runs in the project root, which `rigor.rootDir` can move into a subfolder. A relative finding must therefore resolve against `rootDir`, not the workspace folder.

The first draft used `relative` with `${cwd}`. In the round-1 review `${cwd}` behaved like `${workspaceFolder}`, so it cannot name the project root. Absolute output then joined onto the base and landed on a path that does not exist.

## Options and trade-offs

- `relative` with `${workspaceFolder}`: wrong for absolute paths, which the CLI prints when `paths:` is set. Wrong for any `rootDir` subfolder.
- `autoDetect` with `${workspaceFolder}`: absolute paths land correctly. Relative paths land in the workspace folder, so a `rootDir` subfolder loses them (no config, relative output: `lib/a.rb` resolves to `<folder>/lib/a.rb`, which is wrong when `rootDir` is `sub`).
- `autoDetect` with `${workspaceFolder}/${config:rigor.rootDir}`, chosen. Absolute paths land correctly. Relative paths land under `rootDir`. Checked in the EDH: `rootDir: sub` puts `lib/a.rb` on `sub/lib/a.rb`; no `rootDir` puts `lib/a.rb` on `lib/a.rb`, relative and absolute alike. In a two-folder workspace with `rootDir: sub` on one folder and none on the other, each folder's task places its findings under its own root (`${config:}` resolves per folder).
- Changing the CLI to always print absolute, or always project-root-relative, paths: a Ruby change, which the issue's decision rules out.

## Decision

`autoDetect` with `${workspaceFolder}/${config:rigor.rootDir}`. It is the only form that places both path forms the CLI prints. Alongside it, `projectRoot` rejects an absolute `rigor.rootDir` (the server and the task share it), so the base is always a relative path under the folder. Before this, an absolute value produced a doubled `//` in the base. The existing warning fires for it, but its text says "is outside the workspace folder", which is inaccurate for an absolute path inside the folder; that wording is left for a later change.

Two behaviours are not verified. The config diagnostic (`path: ".rigor.yml"`) resolves against the base, which is correct when `.rigor.yml` lives in the project root, but no such diagnostic appeared in the EDH runs (no Gemfile.lock). The untrusted-workspace branch of **Rigor: Check Workspace** was not run in the EDH (the window stalled); it is checked by reading the code only.

## To undo

Reverting to `relative`, or to `${workspaceFolder}` alone, would misplace the findings the CLI prints today: absolute ones under `paths:`, and relative ones under a `rootDir`. Undoing the absolute-`rootDir` rejection would let the server and the task root in an absolute directory again. Nothing else depends on the matcher's base beyond the `$rigor` matcher in `editors/vscode/package.json`.
