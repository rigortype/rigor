# Rigor for VSCode

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
| Outline | Class / module / method tree in the Outline view, breadcrumbs, and symbol search. |

## Requirements

- **VSCode 1.85+**.
- A **trusted** workspace (the server is not started in restricted mode).
- The **`rigortype` gem ≥ 0.1.6** available to the project. The usual
  setup is a Gemfile entry:

  ```ruby
  group :development do
    gem "rigortype"
  end
  ```

  followed by `bundle install`. A globally installed `rigor` also
  works.

- A **Rigor config** (`.rigor.yml` or `.rigor.dist.yml`) at the
  project root. The extension only starts a server for folders that
  have a config file or pin `rigortype` in `Gemfile.lock`.

The extension does **not** bundle the gem and does **not** provide
Ruby syntax highlighting — keep your existing Ruby grammar extension.

## Server discovery

For each workspace folder the extension resolves the `rigor`
executable in this order:

1. `rigor.server.path`, if set — explicit path / command.
2. `bundle exec rigor`, when `rigor.server.useBundler` allows it and a
   `Gemfile.lock` pinning `rigortype` is found (`auto`, the default).
3. `rigor` from `PATH`.

If none works, the extension shows an actionable message and stays
loaded — fix the setup and run **Rigor: Restart Server**.

## Settings

| Setting | Default | Description |
|---|---|---|
| `rigor.enable` | `true` | Enable the server for the folder. |
| `rigor.server.path` | `""` | Explicit `rigor` executable path. |
| `rigor.server.useBundler` | `auto` | `auto` / `always` / `never`. |
| `rigor.server.configPath` | `""` | Passed as `--config=PATH`. |
| `rigor.server.logPath` | `""` | Passed as `--log=PATH`. |
| `rigor.trace.server` | `off` | JSON-RPC trace into the output channel. |

`server.*` settings are per-folder; changing one restarts the server.

## Commands

- **Rigor: Restart Server**
- **Rigor: Show Output Channel**
- **Rigor: Show Server Log** (when `rigor.server.logPath` is set)

## Multi-root workspaces

The v1 language server is single-root, so the extension runs one
server per Rigor-configured folder. A file outside every such folder
gets no diagnostics.

## Coexistence with other Ruby tooling

The extension claims no formatter and no language grammar, so it runs
cleanly alongside Shopify Ruby LSP, Solargraph, or Sorbet. Rigor's
diagnostics are tagged `source: "rigor"` in the Problems panel.

## Troubleshooting

See the [LSP integration guide](https://github.com/rigortype/rigor/blob/main/docs/lsp-integration.md)
for diagnostics-not-appearing, empty-completion, and `untyped`-hover
cases. For server-side detail, set `rigor.server.logPath` and open the
log with **Rigor: Show Server Log**.

## License

[MPL-2.0](LICENSE), matching the `rigortype` gem.
