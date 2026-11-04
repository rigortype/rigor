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

For each workspace folder the extension tries these candidates in
order and uses the first whose `rigor version` runs. The language
server, the `rigor: check` task and every CLI-backed command use that
same one.

1. `rigor.server.path`, if set — explicit path / command. When it
   fails, the extension says so and tries nothing else.
2. `bundle exec rigor`, when the project's `Gemfile.lock` (or
   `gems.locked`) pins `rigortype` (`rigor.server.useBundler: auto`,
   the default).
3. The **pinned bundle** — `bundle exec rigor` with `BUNDLE_GEMFILE`
   set to `.github/rigor/Gemfile` (or `rigor.server.bundleGemfile`),
   when its lockfile pins `rigortype`. See below.
4. Every `rigor` on `PATH`, in `PATH` order (on Windows `rigor.bat`,
   `rigor.cmd` and `rigor.exe`). Relative entries such as `.` are not
   searched, and the same file reached twice is tried once.
5. A `mise` or `asdf` shim (e.g. `~/.local/share/mise/shims/rigor`),
   used directly.
6. The **managed Rigor**, when you installed one — see below.

A pin is final. A project whose lockfile pins `rigortype` (2 or 3) runs
that and nothing else, and one whose `mise.toml`, `.mise.toml` or
`.tool-versions` (or another mise config file, at the project root or
above it) pins it runs the mise or asdf shim (5) and nothing else: a
different Rigor would report diagnostics that differ from CI's. On
Windows that means mise's shim directory (`%LOCALAPPDATA%\mise\shims`,
or `MISE_DATA_DIR`) must hold `rigor.cmd`, `rigor.bat` or `rigor.exe`;
this is reasoned from the code, not tested on Windows. When the pin does not run, the
message says to install it (`bundle install`, or `mise install`)
instead of falling back. Because `bundle exec rigor` runs any `rigor`
on `PATH` when the bundle has none installed, a Bundler candidate that
reports another version than its lockfile pins (or none) is rejected
too. Your global mise config is not a project
pin: it only keeps the managed Rigor away.

`rigor.server.useBundler: always` makes 2 the only candidate, or 3
when `rigor.server.bundleGemfile` is set; `never` skips 2 and 3, and
then a lockfile pin no longer decides: the extension warns once that
the pinned rigortype is not used (a mise or asdf pin still decides). A candidate that exists but
does not run (an rbenv shim whose Ruby lacks the gem, a broken
script) is rejected for the next one; the output channel logs each
rejected candidate and why (a probe that hangs is rejected after
20 s, and after 45 s in all the candidates no pin requires are
skipped, which can leave out a later one such as the managed Rigor).
Every folder's search starts at once. A `rigor` that runs but is older than 0.1.6 stops the search
with an upgrade warning. The result is kept until **Rigor: Restart
Server**, a settings change, or a change to what pins `rigortype`,
which restarts that folder's server. Only `Gemfile.lock`, `gems.locked`,
`mise.toml`, `.mise.toml`, `mise.local.toml` and `.tool-versions` in the
project root (and the workspace folder), and the pinned bundle's
`Gemfile` and lockfile, are watched, and only a pin that appears,
disappears or names another version (or Ruby) restarts anything. The
other mise files (`.mise/`, `.config/mise/`, parent directories) are
read when the folder is resolved; after changing one, run **Rigor:
Restart Server**. The `rigor: check` task is always
there: while the search is still running it waits for it, and when the
search found no `rigor` that runs it prints why and fails.
**Rigor: Check Workspace** names every folder whose search failed.

If none works, the extension shows an actionable message listing the
candidates it tried and stays loaded — fix the setup and run
**Rigor: Restart Server**.

### The pinned bundle

A Rigor-only `Gemfile` and lockfile committed at `.github/rigor/` (the
manual's
[pinned bundle](https://github.com/rigortype/rigor/blob/master/docs/manual/01-installation.md#secondary--a-pinned-bundle))
is enough for the extension to manage the folder and run it, kind
`pinned-bundle`. It runs from the project root, with `BUNDLE_GEMFILE`
set to the Gemfile's absolute path, as `<ruby> <bundle> exec rigor`.
The Ruby is found among the ones the managed Rigor considers
(`rigor.runtime.rubyPath`, `ruby` on `PATH`, the version managers'
install directories, each asked once), so the project's own Ruby does
not have to be 4.0: the first that matches the lockfile's `RUBY
VERSION`, else the Gemfile's `ruby` line, else rigortype's own Ruby
range. When that does
not run, `bundle exec rigor` from `PATH` is tried with the same
`BUNDLE_GEMFILE`. Both drop the inherited `GEM_HOME`, `GEM_PATH`,
`RUBYOPT`, `RUBYLIB`, `BUNDLE_BIN_PATH`, `BUNDLER_*` and
`BUNDLE_GEMFILE`, and keep your other `BUNDLE_*` settings (a
`BUNDLE_PATH` you install with). Install the bundle under that Ruby
first (`BUNDLE_GEMFILE=.github/rigor/Gemfile bundle install`). Set
`rigor.server.bundleGemfile` (relative to the project root, and inside
it) for a bundle somewhere else.

### The managed Rigor (first-time setup)

When no `rigor` is found, the not-found message offers **Install Rigor
for this editor** (also **Rigor: Install Managed Rigor**). The
extension then installs `rigortype` into its own storage, outside
every project:

- **A Ruby 4.0 is on the machine** — the first that qualifies of
  `rigor.runtime.rubyPath`, `ruby` on `PATH`, and the mise, rbenv,
  chruby and asdf install directories. It must carry Bundler and load
  OpenSSL; a preview or dev build is used only when
  `rigor.runtime.rubyPath` names it. When the build fails because the
  Ruby cannot load OpenSSL or another standard library, the next Ruby
  that qualifies is tried once (not when `rigor.runtime.rubyPath`
  named it); a certificate error or a missing compiler is reported
  with a hint instead. The
  extension runs `bundle install` for a one-line
  `Gemfile` (`gem 'rigortype', '= X'`), then starts the server as
  `ruby <bundle> exec rigor lsp` in the project. Bundler's config
  files are ignored, and the inherited `BUNDLE_*`, `GEM_HOME`,
  `GEM_PATH`, `RUBYOPT` and `RUBYLIB` variables are dropped, except
  `BUNDLE_MIRROR__*`: a mirror set that way is still used. Only
  `rigortype` is pinned; its dependencies resolve to their newest
  matching releases when you install. Progress and
  Bundler's output appear in the Rigor output channel. **Rigor: Show
  Server Version** reports the kind as `managed`.
- **No Ruby 4.0, but `mise`** — the extension offers to run
  `mise install ruby@4.0` first. That installs Ruby into mise's own
  store, and no file in the project changes, but mise applies your
  own mise settings while it runs (an auto-prune, for example). It is
  the only `mise` command the extension runs: it reads mise's files to
  find pins and Rubies. Closing the window does not stop it: it
  finishes on its own, writing its output to a
  `.mise-install-<pid>.log` file in the extension's storage. While
  that log is still growing and does not show mise finishing, no
  window starts another; the message names the log.
- **Neither** — the extension points you to the
  [installation guide](https://github.com/rigortype/rigor/blob/master/docs/install.md).
  A self-contained Rigor that needs no Ruby is tracked in
  [#926](https://github.com/rigortype/rigor/issues/926).

The managed Rigor is the last thing discovery tries, so a `rigor` you
install yourself wins over it; one that is found but does not run
falls through to it. A project that pins `rigortype` — in
`Gemfile.lock` or `.github/rigor/Gemfile.lock`, or in the `[tools]` of
a `mise.toml` (or another mise config file) or `.tool-versions` at the
project root or above it — is never served by it: install that pin
instead. Your global mise or asdf config counts only while a
rigortype is installed through it. Nothing is installed in an
untrusted workspace, or without your click. When no folder has a
`.rigor.yml` yet, the extension offers to create one with
`rigor init`.

`rigor.runtime.version` chooses the version (`latest` by default).
**Rigor: Check for Rigor Update** installs a newer release, which
takes effect when the server restarts. While a folder runs the managed
Rigor and the version is `latest`, the extension also checks by itself
(`rigor.runtime.autoUpdate`, on by default): shortly after the
server starts, and at most once every
`rigor.runtime.updateCheckIntervalHours` (24) across all windows on
the machine. A newer release is offered with **Install update** /
**Later**; it installs beside the current one and is used after a
restart, which the extension offers. **Later** is remembered, so no
window asks about that version again. A pinned version never updates, an untrusted
workspace is never checked, and an unreachable rubygems.org leaves
the install alone and logs one line. Every VS Code window shares
the install: the extension keeps the newest two versions plus any
version a window's server still runs, and **Rigor: Clear Managed
Rigor** deletes them all. Clear stops this window's servers and starts
them again; servers in other windows keep running from the deleted
files and fail until those windows restart them.

### Runtime version managers (mise / asdf)

`mise` is the recommended way to install Rigor — `mise use
gem:rigortype` (see the manual's
[Installing Rigor](https://github.com/rigortype/rigor/blob/master/docs/manual/01-installation.md)
chapter). A GUI-launched VS Code does not inherit the shell `PATH`
that `mise activate` sets up, so step 4 above often misses a
mise-managed `rigor` — step 5 covers that automatically by finding
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
| `rigor.server.bundleGemfile` | `""` | Gemfile of a pinned bundle, relative to the project root and inside it. Empty uses `.github/rigor/Gemfile` when its lockfile pins `rigortype`. |
| `rigor.server.configPath` | `""` | Passed as `--config=PATH`. |
| `rigor.server.logPath` | `""` | Passed as `--log=PATH`. |
| `rigor.runtime.version` | `latest` | `rigortype` version of the managed Rigor; `latest` resolves the newest release on rubygems.org. |
| `rigor.runtime.autoUpdate` | `true` | Background update checks for the managed Rigor while `rigor.runtime.version` is `latest`. |
| `rigor.runtime.updateCheckIntervalHours` | `24` | Hours between those checks (1–168). |
| `rigor.runtime.rubyPath` | `""` | Ruby 4.0 the managed Rigor is installed with. Empty searches `PATH` and the version managers' install directories, in that order; a prerelease Ruby is used only when named here. |
| `rigor.trace.server` | `off` | JSON-RPC trace into the output channel. |

`rootDir` and the `server.*` settings are per-folder; changing one
restarts the server. The `runtime.*` settings are user settings only. The server runs in the project root, so a
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
- **Rigor: Install Managed Rigor**, **Rigor: Check for Rigor Update**,
  **Rigor: Clear Managed Rigor** — see *The managed Rigor* above.

### Commands that run the CLI for the open file

These appear in the Command Palette only while at least one workspace
folder is managed by Rigor. Each runs the same `rigor` executable the
language server uses (same discovery, project root and
`rigor.server.configPath`), refuses to run in an untrusted workspace, logs
the command line and its output to the Rigor output channel, and shows a
cancellable progress notification while it runs.

- **Rigor: Show Type at Cursor** — `rigor type-of` at the cursor (1-based
  line and byte column). The result opens in a read-only document beside
  the editor. An unsaved buffer is probed as it stands.
- **Rigor: Explain Rule** — pick a rule from `rigor explain`, and its
  catalogue entry opens beside the editor. A Rigor diagnostic with a rule
  code also offers an **Explain `<rule>`** quick fix that opens the same
  entry.
- **Rigor: Open Config** — opens `.rigor.yml` or `.rigor.dist.yml` of the
  project root (or the file named by `rigor.server.configPath`). When none
  exists it offers to run `rigor init`, after a confirmation, and opens the
  result.
- **Rigor: Generate Signatures for File** — shows `rigor sig-gen --diff`
  for the open file in a read-only diff document, then asks before running
  `rigor sig-gen --write`. `rigor sig-gen --check` runs first: when
  `--write` would change nothing, the command says so and shows no diff or
  prompt. Nothing is written without the confirmation. Save the file first;
  `sig-gen` reads it from disk.
- **Rigor: Update Baseline** — only when the project already has a baseline
  (the top-level `baseline:` file of the config; a config without the key
  has none, and `baseline: false`, `null` or a bare `baseline:` also means
  none). When the config has `includes:`
  the command asks you to pick the baseline file rather than guess. A
  confirmation names the file, which the whole team shares, then runs
  `rigor baseline regenerate` and shows its output.

Boundary: these run only when you ask, and nothing they learn feeds the
language server's analysis.

Show Type at Cursor and Generate Signatures work on Ruby files only. The
"Explain" quick fix is offered only for rules `rigor explain` lists. The
column sent to `rigor type-of` is a byte offset computed as UTF-8, so a file
in another encoding can be off. Outside Production mode (the Extension
Development Host) the write commands accept an internal `{ confirmed: true }`
argument for automated tests; an installed extension ignores it.

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
