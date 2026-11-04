# `rigor.server.useBundler: never` skips the pinned bundle too, and `always` with `rigor.server.bundleGemfile` runs only the pinned bundle

- **PR:** [#2778](https://github.com/rigortype/rigor/pull/2778)
- **Issue:** [#2750](https://github.com/rigortype/rigor/issues/2750)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-04

## Background

#2750 added the pinned bundle (`.github/rigor/Gemfile`, run with `BUNDLE_GEMFILE`) as a discovery
kind and said `useBundler: always` must honour `rigor.server.bundleGemfile`. It did not say what
`never` does with the new kind, nor whether `always` still falls through.

## Options and trade-offs

- **`never` skips only the project's Gemfile.** Keeps the pinned bundle for a user who set `never`
  because their application bundle is broken; but the setting's description is "Never use
  Bundler", and the pinned bundle is Bundler.
- **`never` skips both (taken).** The setting means what it says; a user who wants the pinned
  bundle leaves it at `auto`, where the pinned bundle comes before `PATH`.
- For `always`: falling through after a failed `bundle exec` would contradict the user's explicit
  choice, as an explicit `rigor.server.path` is never replaced.

## Decision

`never` skips both Bundler kinds, and then a lockfile pin no longer makes the walk final (PATH and
the shims may serve; the managed Rigor still may not). `always` makes the Bundler candidate the only one — the pinned
bundle when `rigor.server.bundleGemfile` is set, the project's Gemfile otherwise — and a failure is
reported, not replaced, and never offers the managed Rigor (as before).

## To undo

Change the `mode === "auto"` / `mode === "always"` branches of `walk` in
`editors/vscode/src/resolve.ts`, the `useBundler` enum descriptions in `editors/vscode/package.json`
and the README *Server discovery* paragraph.
