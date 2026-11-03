# Rigor for VS Code

Type-aware diagnostics, hover, completion, and an outline view for
Ruby — powered by the [Rigor](https://github.com/rigortype/rigor)
analyzer's bundled language server (`rigor lsp`).

This extension is a thin LSP client. All language intelligence comes
from the `rigortype` gem; the extension only discovers the server,
exposes settings, and surfaces lifecycle state.

## Features

| Feature | Behaviour |
|---|---|
| Diagnostics | Type errors in the Problems panel and as inline squiggles, on every keystroke (200 ms debounced). `source: "rigor"`, severity- and rule-coded. |
| Hover | Type-aware tooltip — receiver type + RBS signature for calls, FQN + singleton type for constants, narrowed type for locals. |
| Completion | Method completion after `.`, constant-path completion after `::`, driven by the inferred receiver type. |
| Signature help | Parameter list of the method being called, after `(` and `,`. |
| Outline | Class / module / method tree in the Outline view, breadcrumbs, and symbol search. |
| Folding and selection | Folding ranges for classes, methods and blocks; Expand / Shrink Selection by syntax node. |

## Requirements

- **VS Code 1.85+**.
- A **trusted** workspace (the server is not started in restricted mode).
- The **`rigortype` gem ≥ 0.1.6**, installed so `rigor` is on `PATH`
  (or reachable through a `mise` / `asdf` shim). See the manual's
  [Installing Rigor](https://github.com/rigortype/rigor/blob/master/docs/manual/01-installation.md)
  chapter — `mise` is the recommended channel and ships a stable
  `rigor` shim the extension auto-discovers. Rigor is a tool, not a
  library, and does **not** go in the project's `Gemfile`. A legacy
  bundler-based install (`bundle exec rigor`) is still detected — see
  *Server discovery* below.

- A **Rigor config** (`.rigor.yml` or `.rigor.dist.yml`) at the
  project root. The extension only starts a server for folders that
  have a config file or pin `rigortype` in `Gemfile.lock`. When the
  project lives in a subdirectory (a monorepo's `api/`), set
  `rigor.rootDir`; the extension offers to when it finds a nested
  config.

The extension does **not** bundle the gem and does **not** provide
Ruby syntax highlighting — keep your existing Ruby grammar extension.

## Server discovery

For each workspace folder the extension resolves the `rigor`
executable in this order:

1. `rigor.server.path`, if set — explicit path / command.
2. `bundle exec rigor`, when `rigor.server.useBundler` allows it and a
   `Gemfile.lock` pinning `rigortype` is found (`auto`, the default).
3. `rigor` from `PATH`.
4. A `mise` or `asdf` shim — when `rigor` is not on `PATH`, the
   extension looks for a runtime-version-manager shim (e.g.
   `~/.local/share/mise/shims/rigor`) and uses it directly.

If none works, the extension shows an actionable message and stays
loaded — fix the setup and run **Rigor: Restart Server**.

### Runtime version managers (mise / asdf)

`mise` is the recommended way to install Rigor — `mise use
gem:rigortype` (see the manual's
[Installing Rigor](https://github.com/rigortype/rigor/blob/master/docs/manual/01-installation.md)
chapter). A GUI-launched VS Code does not inherit the shell `PATH`
that `mise activate` sets up, so step 3 above often misses a
mise-managed `rigor` — step 4 covers that automatically by finding
the shim, a stable self-contained executable. `asdf` shims
(`~/.asdf/shims/rigor`) are detected the same way.

Auto-detection checks the standard shim locations, honouring
`MISE_DATA_DIR` / `XDG_DATA_HOME` / `ASDF_DATA_DIR`. If your shims
live elsewhere, point `rigor.server.path` at the shim explicitly:

```json
"rigor.server.path": "/Users/you/.local/share/mise/shims/rigor"
```

Use an absolute path — the setting is not `~`-expanded.

## Settings

| Setting | Default | Description |
|---|---|---|
| `rigor.enable` | `true` | Enable the server for the folder. |
| `rigor.rootDir` | `""` | Relative subdirectory holding the Rigor project (such as `api`). Empty uses the folder itself; an absolute path is rejected. |
| `rigor.server.path` | `""` | Explicit `rigor` executable path. |
| `rigor.server.useBundler` | `auto` | `auto` / `always` / `never`. |
| `rigor.server.configPath` | `""` | Passed as `--config=PATH`. |
| `rigor.server.logPath` | `""` | Passed as `--log=PATH`. |
| `rigor.trace.server` | `off` | JSON-RPC trace into the output channel. |

`rootDir` and the `server.*` settings are per-folder; changing one
restarts the server. The server runs in the project root, so a
relative `configPath` or `logPath` resolves against it.

## Commands

- **Rigor: Restart Server**
- **Rigor: Show Output Channel**
- **Rigor: Show Server Version** — the extension version, and for each
  folder the `rigortype` version, how `rigor` was found, and its state.
  Include it in a bug report.
- **Rigor: Show Server Log** (when `rigor.server.logPath` is set)
- **Rigor: Check Workspace** — runs `rigor check` for the folder of the
  active editor (or asks which folder, when the editor has none of
  them). Its results go to the Problems panel, as described below.

The status bar item's tooltip lists the same per-folder detail, and
the output channel logs a startup summary (versions, root, command
line) for each server.

## Whole-project check task

The language server only reports diagnostics for open files. To see
every finding in the project, run the `rigor: check` task
(**Terminal → Run Task…**, or **Rigor: Check Workspace**). The task runs
the same `rigor` the server uses, from the project root, with the same
`rigor.server.configPath`, and its text output fills the Problems panel
through the `$rigor` problem matcher. The problems carry
`source: "rigor"`, like the server's.

The matcher reads each `PATH:LINE:COL: SEVERITY: MESSAGE` line, where
`SEVERITY` is `error`, `warning` or `info`. A trailing `[RULE]` is
optional: when the line ends with one, it is the rule (the last
bracketed token), so a message that itself ends in brackets without a
rule is read as having that rule. Summary lines such as
`1 error(s) in 1 file(s)` and the `Check targets` and timing output
are not problems.

Relative paths resolve against the project root (`rigor.rootDir`, or
the folder itself), through `${config:rigor.rootDir}`. Absolute paths
are used as given. The base was checked per folder in a multi-root
workspace where each folder has its own `rootDir`. An absolute
`rigor.rootDir` is rejected, as it is for the server.

- The task is provided once per managed folder, and only in trusted
  workspaces. In a multi-root workspace the task is named
  `check (<folder>)`.
- Each run replaces the task's previous problems, including those of a
  task for another folder. To clear them, rerun the task or close its
  terminal.
- VS Code keeps one problem per file, line and column. Two findings at
  the same position show only the first one.
- A file open in the editor can show the same finding twice: once from
  the language server and once from the task. Both entries have
  `source: "rigor"` and the same position. VS Code does not merge them,
  so clearing the task's problems does not clear the server's entry.

## Multi-root workspaces

The v1 language server is single-root, so the extension runs one
server per Rigor-configured folder, and each server is sent only the
Ruby files under its own project root. A file outside every such root
— including a gem's or the standard library's source opened from
another file — gets no Rigor features.

## Coexistence with other Ruby tooling

The extension claims no formatter and no language grammar, so it runs
cleanly alongside Shopify Ruby LSP, Solargraph, or Sorbet. Rigor's
diagnostics are tagged `source: "rigor"` in the Problems panel.

## Troubleshooting

See the [editor integration guide](https://github.com/rigortype/rigor/blob/master/docs/manual/09-editor-integration.md)
for diagnostics-not-appearing, empty-completion, and `untyped`-hover
cases. For server-side detail, set `rigor.server.logPath` and open the
log with **Rigor: Show Server Log**.

## License

[MPL-2.0](LICENSE), matching the `rigortype` gem.
