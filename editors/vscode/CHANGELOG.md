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
- CLI-backed commands for the open file, shown in the Command Palette
  only while a folder is managed: Show Type at Cursor, Explain Rule (also
  a quick fix on Rigor diagnostics), Open Config, Generate Signatures for
  File and Update Baseline. The commands that write ask first.
- Status bar item reflecting the server lifecycle.
- One server per Rigor-configured folder in multi-root workspaces.
- Workspace-trust gating — the server is not started in restricted
  mode.
- Extension icon (`icon.png`, from the Rigor branding asset).
- `rigor.rootDir`, a relative subdirectory of the workspace folder
  holding the Rigor project (an absolute path is rejected with a
  warning). When a folder has no root config but a nested
  one, the extension says so and offers to set it, instead of
  activating and staying silent.
- **Rigor: Show Server Version**, a per-folder status bar tooltip
  (state, `rigortype` version, discovery kind, command line), and a
  startup summary in the output channel.
- A `rigor: check` task (`type: "rigor"`) per managed folder, which runs
  `rigor check` from the project root and fills the Problems panel
  through the `$rigor` problem matcher. Trusted workspaces only. The
  matcher's trailing `[RULE]` is optional, so parse and path errors
  appear too.
- **Rigor: Check Workspace**, which runs that task for the active
  editor's folder.
- A **managed Rigor** for first-time users (#2725): when no `rigor` is
  found, **Install Rigor for this editor** (or **Rigor: Install Managed
  Rigor**) installs `rigortype` with an isolated `bundle install` into
  the extension's storage, using a Ruby 4.0 found on the machine, or
  one `mise install ruby@4.0` provides when you agree. It is the last
  discovery kind (`managed`), is never used for a project that pins
  `rigortype`, and installs nothing in an untrusted workspace or
  without a click. A `rigor` on `PATH` or a shim that is found but
  does not run falls through to an installed managed Rigor, and a
  managed Rigor that does not run is offered a repair. When no folder
  has a `.rigor.yml`, the extension offers `rigor init`. VS Code
  windows share the install safely (a lock, an atomic rename, and no
  pruning of a version another window runs). Without a Ruby 4.0 or
  mise, the message points to the installation guide and #926. New settings
  `rigor.runtime.version` and `rigor.runtime.rubyPath`; new commands
  **Rigor: Check for Rigor Update** and **Rigor: Clear Managed Rigor**.

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
