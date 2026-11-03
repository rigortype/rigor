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

### Fixed

- Overlapping starts, restarts and folder or trust changes no longer
  spawn two servers for one folder: lifecycle operations now run one
  at a time.
- A server that does not exit after `shutdown`, or that was spawned
  by a start that failed part way, is killed instead of left running.
- In a multi-root workspace each server is sent only the Ruby files
  under its own folder, not every Ruby file in the window.
- **Rigor: Show Server Log** reads the setting of the active editor's
  folder (or asks) instead of always the first folder.

### Known limitations

- Files outside every Rigor-configured folder get no diagnostics
  (the v1 language server is single-root).
