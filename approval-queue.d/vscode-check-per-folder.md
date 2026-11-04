# The rigor check task parses its own output into a per-folder collection instead of using the problem matcher

- **PR:** [#2794](https://github.com/rigortype/rigor/pull/2794)
- **Issue:** [#2747](https://github.com/rigortype/rigor/issues/2747)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

Issue #2747 reported that in a multi-root workspace the `rigor: check` tasks of different folders clear each other's problems, because every task uses the contributed `$rigor` matcher, whose owner is `rigor`. VS Code keeps one set of problems per owner, so a run replaces whatever the previous run under that owner reported. The issue left the scheme open ("a per-folder owner ... or a different scheme"). It was labelled ready-for-human, and the coordinator ruled on the design.

## Options and trade-offs

- A per-folder owner. A contributed matcher's owner is static, declared in package.json, so owners per folder cannot exist. A task may also name an inline matcher, but that cannot be generated per workspace folder from a provider without hand-written matcher objects whose paths and rules would duplicate the contributed one.
- Keep one owner and document the limit, as #2739 did. This leaves the acceptance criterion unmet.
- Run every provided task as a pseudoterminal that spawns `rigor check`, echoes its output and parses each line itself, publishing into one extension-owned `DiagnosticCollection` with a per-folder index. This costs a second implementation of the parse (one shared regex, a test holds it equal to the matcher's) and the extension owns clearing.

## Decision

The third option. Every provided task is a `CustomExecution`; results go into one collection `rigor check` with `source: "rigor check"` (distinct from the server's `rigor`). A folder's run replaces only its own files, and a file reported by two folders (nested roots) holds both folders' findings. Results clear when the folder leaves the workspace or is no longer managed, on the new command **Rigor: Clear Check Results**, and on deactivate. The provided task no longer attaches `$rigor`, so nothing is reported twice. The matcher stays for user-authored `tasks.json` shell tasks. The `source` changes from `rigor` to `rigor check` for task problems. A folder's results are replaced only when `rigor check` finishes (exit 0 or 1); a cancel, a spawn or discovery failure, 64 (usage or config error), 70 and 127 keep the earlier results. 64 is treated as not finished because it prints no findings for the project; the coordinator ruled that results are never cleared at run start. The task definition has an optional `folder` property (the folder name) set on provided tasks, because VS Code looks a pseudoterminal up by definition and identical definitions in two folders ran the wrong folder's check. A `tasks.json` entry is resolved by `resolveTask` with its own definition; in a multi-root workspace, entries that start together (`runOn: folderOpen`) still need distinct `folder` values, which the README says.

## To undo

Reattach `$rigor` to the provided task and delete `src/checkOutput.ts`, `src/checkResults.ts`, the command and the prune hook; the multi-folder clearing returns. Users who filter the Problems panel on `source: rigor` will not see task problems under it.
