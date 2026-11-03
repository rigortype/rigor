# The rigor check problem matcher uses autoDetect with the workspace folder as base

- **PR:** [#2739](https://github.com/rigortype/rigor/pull/2739)
- **Issue:** [#2723](https://github.com/rigortype/rigor/issues/2723)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

Issue #2723 asked for a `$rigor` problem matcher for `rigor check` output and left its file-location form to the implementer. The first draft used `relative` with `${cwd}`. In the Extension Development Host the CLI printed absolute paths for the task's run, and `relative` joined each path onto the base, so the marker landed on a path that does not exist. The task's working directory is the project root, which `rigor.rootDir` can move into a subfolder.

## Options and trade-offs

- `relative` with `${workspaceFolder}`: wrong for absolute paths, which is what the CLI prints today.
- `relative` with `${cwd}`: the variable is the extension host's working directory, not the task's, so it is not a usable base (not re-verified in this lane).
- `autoDetect` with `${workspaceFolder}`: absolute paths land on the right file (observed). A relative path resolves against the workspace folder, so a `rootDir` subfolder loses relative paths (observed, and recorded as a known limit in the PR).
- Changing the CLI to print project-root-relative paths for the task: a Ruby change, which the issue's decision rules out.

## Decision

`autoDetect` with `${workspaceFolder}`. It is the only form that places the output the CLI produces today, and the cost (relative paths in a `rootDir` subfolder) is latent because the CLI does not emit them for this run. The PR records that cost as a known limit with the change that would lift it.

## To undo

Switching to `relative` would misplace the markers the CLI prints today. Revisiting this needs either a CLI change that emits project-root-relative paths, or a VS Code base that names the task's working directory. Nothing depends on the choice beyond the `$rigor` matcher in `editors/vscode/package.json`.
