# The VS Code extension caches each folder's discovery result, failures included, and restarts the folder when a pin lockfile changes

- **PR:** [#2778](https://github.com/rigortype/rigor/pull/2778)
- **Issue:** [#2748](https://github.com/rigortype/rigor/issues/2748)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

The coordinator ruled that one resolution is shared by the server, the `rigor: check` task and the
CLI commands, cached per folder "until a restart, settings change or config-file change". Which
files count, whether a failure is cached, and what happens to a running server when the cache is
dropped were left open.

## Options and trade-offs

- **Cache only passing results.** A later command notices a `rigor` installed meanwhile; but VS
  Code calls the task provider many times per window, and a failing walk re-probes every candidate
  each time (six probes in one E2E run).
- **Cache everything (taken).** One walk per folder until a restart; the not-found message already
  says to run **Rigor: Restart Server**.
- **Drop the cache on a lockfile change without restarting.** The task and commands would then run
  a different `rigor` than the running server, which the ruling forbids.

## Decision

Cache passing and failing results. A create, change or delete of the project's `Gemfile.lock` or the
pinned bundle's lockfile (the files that choose a Bundler kind) forgets that folder's result and
restarts its server, debounced; a server-affecting setting change or a restart forgets all.
`rigor.server.bundleGemfile` and `rigor.runtime.rubyPath` join the server-affecting settings.

## To undo

`resolveRigor` / `forgetResolutions` in `editors/vscode/src/resolve.ts` and `watchPins` in
`editors/vscode/src/extension.ts`; the README *Server discovery* paragraph says the same.
