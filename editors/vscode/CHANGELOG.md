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
  The Ruby search takes the first Ruby 4.0 with Bundler and OpenSSL,
  skips a preview or dev build unless `rigor.runtime.rubyPath` names it,
  and tries the next one once when the build fails because the Ruby
  cannot load OpenSSL (never for a named `rubyPath`); a `mise install ruby@4.0` in progress finishes when the window
  closes.
- One discovery path for the language server, the `rigor: check` task
  and every CLI-backed command (#2748): each candidate is probed with
  `rigor version` in order, and one that exists but does not run is
  rejected for the next one (every `rigor` on `PATH` in turn, each mise
  or asdf shim, then the managed Rigor). The output channel logs each
  rejected candidate and why, and the not-found message lists them. An
  explicit `rigor.server.path` that fails is reported, never replaced,
  and a `rigor` that runs but is too old gets the upgrade warning. A
  project pin is final: a lockfile pin runs only Bundler, a project
  `mise.toml` / `.tool-versions` pin only the shim, and a failure says
  to install the pin; a Bundler candidate that runs another rigortype
  than its lockfile pins (compared in full, prerelease included) is
  rejected. `useBundler: never` warns once that a lockfile pin is not
  used. A hung probe is rejected after 20 s and the
  search skips unpinned candidates after 45 s. The result is kept per
  folder until a restart, a settings change, or a change to what pins
  `rigortype`. A project `gems.locked` counts as a lockfile pin. The
  `rigor: check` task is always offered: it waits for a search still
  running, and reports a failed one. On Windows, `rigor.bat` / `.cmd` /
  `.exe` on `PATH` and as mise (`%LOCALAPPDATA%\mise`) or asdf shims.
- The pinned bundle (ADR-27 WD9, #2750): when `.github/rigor/Gemfile.lock`
  pins `rigortype`, the extension runs `bundle exec rigor` with
  `BUNDLE_GEMFILE` set to `.github/rigor/Gemfile`, from the project root,
  under the first Ruby that the managed runtime's search finds matching
  the lockfile's `RUBY VERSION`, else the Gemfile's `ruby` line, else
  rigortype's range (falling back to `bundle` on `PATH`), without the
  inherited `GEM_HOME`, `GEM_PATH`, `RUBYOPT`, `RUBYLIB` and Bundler
  overrides. It comes after the
  project's own `Gemfile.lock` and before `PATH`; the kind shows as
  `pinned-bundle`. A folder with only that pin is managed. New setting
  `rigor.server.bundleGemfile` for another location inside the project
  root, which `rigor.server.useBundler: always` also uses.
- Background update checks for the managed Rigor (#2746):
  `rigor.runtime.autoUpdate` (on by default) and
  `rigor.runtime.updateCheckIntervalHours` (24). While a folder runs it
  and `rigor.runtime.version` is `latest`, a newer `rigortype` is offered
  shortly after startup, at most once per interval across the machine's
  windows; it installs beside the current version on **Install update**
  and is used after a restart, and **Later** is remembered. Never in an
  untrusted workspace; a failed check logs one line.

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
- Each start that times out no longer leaves an empty diagnostics
  collection registered, nor a timer, until the window closes.
- **Rigor: Restart Server**, a setting change, or closing the window while
  the client is still (re)starting a server no longer shows the client's
  two "Pending response rejected" / "couldn't create connection" errors.
- A server the client restarts after a crash, and which then never
  answers `initialize`, is abandoned after 60 s and shown as `error`
  instead of `starting` forever.
- On Windows the language server and the `rigor version` probe are now
  quoted for `cmd.exe`, so a `rigor` or `rigor.server.path` whose path
  contains a space (a user profile such as `C:\Users\First Last`,
  `Program Files`) is no longer split. Not yet tried on a Windows host.

### Known limitations

- Files outside every Rigor-configured folder get no diagnostics
  (the v1 language server is single-root).
