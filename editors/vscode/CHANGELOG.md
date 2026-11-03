# Changelog

All notable changes to the Rigor VSCode extension are documented in
this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the extension is versioned independently of the `rigortype` gem.

## [Unreleased]

### Added

- Initial extension: an LSP client over `rigor lsp` providing
  diagnostics, hover, completion, and the outline view for Ruby.
- Server discovery — explicit `rigor.server.path`, Bundler
  (`auto` / `always` / `never`), and `PATH` fallback.
- Startup `rigor version` probe with actionable messages for a
  missing or pre-0.1.6 gem.
- Configuration: `rigor.enable`, `rigor.server.path`,
  `rigor.server.useBundler`, `rigor.server.configPath`,
  `rigor.server.logPath`, `rigor.trace.server`.
- Commands: Restart Server, Show Output Channel, Show Server Log.
- Status bar item reflecting the server lifecycle.
- One server per Rigor-configured folder in multi-root workspaces.
- Workspace-trust gating — the server is not started in restricted
  mode.
- Extension icon (`icon.png`, from the Rigor branding asset).
- `rigor.rootDir`, for a Rigor project in a subdirectory of the
  workspace folder. When a folder has no root config but a nested
  one, the extension says so and offers to set it, instead of
  activating and staying silent.
- **Rigor: Show Server Version**, a per-folder status bar tooltip
  (state, `rigortype` version, discovery kind, command line), and a
  startup summary in the output channel.
- A `rigor: check` task (`type: "rigor"`) per managed folder, which runs
  `rigor check` from the project root and fills the Problems panel
  through the `$rigor` problem matcher. Trusted workspaces only.
- **Rigor: Check Workspace**, which runs that task for the active
  editor's folder.

### Fixed

- Overlapping starts, restarts and folder or trust changes no longer
  spawn two servers for one folder: lifecycle operations now run one
  at a time.
- On stop or restart, a server that has not exited after `shutdown`
  is killed together with the worker processes it forked (on Windows,
  the `ruby.exe` behind the `cmd.exe` wrapper). A start that does not
  answer `initialize` within 60 s is abandoned the same way instead of
  blocking every later restart.
- Creating or deleting a Rigor config re-syncs the managed folders,
  and a folder whose `rigor version` probe fails is reported once per
  restart rather than on every sync.
- In a multi-root workspace each server is sent only the Ruby files
  under its own folder, not every Ruby file in the window.
- A server that crashes more often than the client's restart limit
  allows now shows the folder as `error` in the status bar, tooltip and
  **Show Server Version**, instead of staying `running`.
  **Rigor: Restart Server** brings it back.
- A start that does not answer `initialize` within 60 s now shows one
  error ("Show Output" opens the log) instead of two unrelated ones.
- Changing `rigor.rootDir` or `rigor.enable` in one folder re-explains
  only that folder, not the other folders' dismissed messages.
- Closing the window during a multi-folder sync no longer runs
  `rigor version` for the folders not yet reached.
- **Rigor: Show Server Log** reads the setting of the active editor's
  folder (or asks) instead of always the first folder.

### Known limitations

- Files outside every Rigor-configured folder get no diagnostics
  (the v1 language server is single-root).
