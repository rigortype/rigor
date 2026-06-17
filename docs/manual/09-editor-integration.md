# Rigor LSP — Editor Integration

`rigor lsp` is the in-process Language Server bundled with the
`rigortype` gem. It speaks the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
over stdio and exposes Rigor's analyzer as a live editor experience —
diagnostics on every keystroke, hover-to-type, outline view, and
type-aware completion.

This page is the entry point for wiring it into your editor. The
design + capability matrix lives in
[`docs/design/20260517-language-server.md`](../design/20260517-language-server.md)
(v1) and
[`docs/design/20260517-lsp-hover-completion.md`](../design/20260517-lsp-hover-completion.md)
(v2). Packaging rationale is in
[`docs/adr/19-language-server-packaging.md`](../adr/19-language-server-packaging.md).

## Features at a glance

| LSP method | Behaviour |
|---|---|
| `textDocument/publishDiagnostics` | Pushed on every `didChange`, 200ms debounced. Severity / rule / source map directly to Rigor's diagnostic taxonomy. |
| `textDocument/hover` | Type-aware markdown. Per-node-class dispatch surfaces receiver type + RBS signature for method calls, FQN + singleton type + defined-in path for constants, narrowed type + bound-at for locals, canonical refinement names (`non-empty-string`, …) for `Refined` / `Difference` carriers. |
| `textDocument/completion` | Method completion after `.` (driven by inferred receiver type), constant-path completion after `::`. Composite receivers (Union → intersection of methods, Tuple / HashShape → ancestor nominal, Refined → underlying nominal) handled. Parse-recovery sentinel makes mid-edit `obj.` / `Foo::` buffers work. |
| `textDocument/documentSymbol` | Outline tree from Prism AST: `class` / `module` / `def` with nesting. |
| `workspace/didChangeWatchedFiles` | Invalidates the per-session `Environment` + `Cache::Store` cache so saved files repropagate. |
| `workspace/didChangeConfiguration` | Same — re-reads `.rigor.yml` / `Gemfile.lock` etc. |

## Prerequisites

The single prerequisite is **`rigor` on your `PATH`** — the same
executable `rigor check` and `rigor type-of` already use. Any of the
install channels in [Installing Rigor](01-installation.md) provide it;
`mise` is the recommended one because its shims make `rigor` available
to GUI-launched editors that do not inherit your shell environment.

Do **not** add `rigortype` to your project's `Gemfile`. Rigor is a
tool, not a library — installing it standalone keeps its Ruby version
and its dependencies out of your application's resolution. See
[Installing Rigor § Recommended — a runtime version manager](01-installation.md#recommended--a-runtime-version-manager).

The LSP server runs as `rigor lsp`, using the same binary as
`rigor check` / `rigor type-of`. There is no separate gem and no
addon registration.

## CLI

```sh
rigor lsp [--transport=stdio] [--log=PATH] [--config=PATH]
```

- `--transport=stdio` — default; only value accepted in v1. TCP /
  Unix-socket transports are queued.
- `--log=PATH` — wire log + server debug to a file. Without it,
  server-side logs go to stderr.
- `--config=PATH` — mirrors `rigor check --config=PATH`. Without
  it, `Configuration.discover` walks `.rigor.yml` / `.rigor.dist.yml`
  from the project root.

## Editor wiring

Every snippet below invokes `rigor lsp` directly, which works as soon
as `rigor` is on the editor's `PATH` (the `mise` shim path, an
`asdf` shim, or whatever your install channel set up — see
[Installing Rigor](01-installation.md)).

If you have an older, project-local install that puts `rigortype` in
the project's `Gemfile`, swap `rigor lsp` for `bundle exec rigor lsp`
(and add `cwd` / `BUNDLE_GEMFILE` as your editor requires). This is
a legacy fallback; new installs should not need it.

### Neovim — nvim-lspconfig

Add a custom server entry. `nvim-lspconfig` doesn't ship a built-in
preset for Rigor yet, so register it manually:

```lua
local configs = require('lspconfig.configs')
local lspconfig = require('lspconfig')

if not configs.rigor then
  configs.rigor = {
    default_config = {
      cmd = { 'rigor', 'lsp' },
      filetypes = { 'ruby' },
      root_dir = lspconfig.util.root_pattern('.rigor.yml', '.rigor.dist.yml', 'Gemfile', '.git'),
      single_file_support = false,
    },
  }
end

lspconfig.rigor.setup({})
```

Place this in your `init.lua` (or under `lua/plugins/`). Restart
Neovim and open a Ruby file inside a Rigor-configured project; you
should see diagnostics appear on save and hover work via `K`. For a
legacy bundler-based install, set `cmd = { 'bundle', 'exec', 'rigor', 'lsp' }`.

### VS Code — generic LSP client

There's no first-party VS Code extension yet. Use a generic
LSP-client wrapper extension, or write a minimal extension that
registers the server:

```ts
// extension.ts (minimal example)
import { workspace, ExtensionContext } from 'vscode';
import { LanguageClient, ServerOptions, TransportKind } from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: ExtensionContext) {
  const serverOptions: ServerOptions = {
    command: 'rigor',
    args: ['lsp'],
    transport: TransportKind.stdio,
  };
  client = new LanguageClient(
    'rigor',
    'Rigor Language Server',
    serverOptions,
    { documentSelector: [{ scheme: 'file', language: 'ruby' }] }
  );
  client.start();
}

export function deactivate() { return client?.stop(); }
```

For a legacy bundler-based install, set `command: 'bundle', args: ['exec', 'rigor', 'lsp']`.

Publish as a private extension or run via `--extensionDevelopmentPath`.
A community-maintained marketplace extension may surface later;
contributions welcome.

### Helix

Add to `~/.config/helix/languages.toml`:

```toml
[language-server.rigor]
command = "rigor"
args = ["lsp"]

[[language]]
name = "ruby"
language-servers = ["rigor"]
```

Helix auto-detects `.rigor.yml` via its project-root walk. If you
also use Solargraph / ruby-lsp, list them alongside `rigor` —
Helix runs multiple servers per language. For a legacy bundler-based
install, use `command = "bundle"` and `args = ["exec", "rigor", "lsp"]`.

### Emacs — Eglot

```elisp
(require 'eglot)
(add-to-list 'eglot-server-programs
             '(ruby-mode . ("rigor" "lsp")))
;; Or for ruby-ts-mode (Emacs 30+):
(add-to-list 'eglot-server-programs
             '(ruby-ts-mode . ("rigor" "lsp")))
```

`M-x eglot` in a Ruby buffer to attach. For a legacy bundler-based
install, replace `("rigor" "lsp")` with `("bundle" "exec" "rigor" "lsp")`.

### Emacs — lsp-mode

```elisp
(with-eval-after-load 'lsp-mode
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection '("rigor" "lsp"))
    :activation-fn (lsp-activate-on "ruby")
    :server-id 'rigor)))
```

For a legacy bundler-based install, swap the connection list to
`'("bundle" "exec" "rigor" "lsp")`.

## Troubleshooting

**The server starts but no diagnostics appear.**

- Confirm your project has a `.rigor.yml` or `.rigor.dist.yml` (or
  the LSP root walk finds one). The LSP uses
  `Configuration.discover` — same logic as `rigor check`.
- Check the LSP log (`--log=/tmp/rigor-lsp.log`) for plugin-load
  errors or RBS-env build failures.
- Run `rigor check <path>` from the same project root; if it works
  there, the LSP should too. If `rigor check` fails, fix that
  first.

**Completion popup is empty.**

- Completion only fires on a node with a known type. Receivers
  whose type collapses to `Dynamic[Top]` produce no completions.
  Look at `rigor type-of <file>:<line>:<col>` to see what type the
  analyzer assigns the receiver.
- Mid-edit buffer support is best-effort. If parse fails AND the
  cursor isn't right after `.` / `::`, the v1 LSP returns no
  completions; deeper recovery is queued (see ROADMAP §
  "Editor / IDE integration").

**Hover shows `untyped` everywhere.**

- The analyzer hasn't loaded your project's RBS. Verify `.rigor.yml`
  has the right `signature_paths:` and `libraries:`. Check the
  LSP log for `RBS::DuplicatedDeclarationError` or similar.

**Concurrent LSP sessions conflict.**

- They shouldn't — the LSP uses a read-only `Cache::Store` so
  multiple processes against the same project don't race on the
  on-disk cache. If you see corruption, file a bug with the log.

## Performance expectations

Per LSP v1's design targets (warm session, 5K-file project,
current laptop):

- Cold start (`initialize` → first publish): < 3s.
- `didChange` → `publishDiagnostics`: p50 < 250ms, p95 < 500ms.
- `hover`: p95 < 100ms.
- `documentSymbol`: p95 < 50ms.
- Memory steady-state: < 600 MB.

Cold start is dominated by RBS environment build; warm starts
(`rigor check`-warmed `.rigor/cache`) land sub-1.5s.

## Status + roadmap

LSP v1 + v2 landed in v0.1.6 and ship in the `0.1.x` line. Queued
follow-ups (`textDocument/signatureHelp`, hash-key completion,
`textDocument/definition`, incremental `didChange` sync, Ractor
pool dispatch, codeAction / rename / semanticTokens / inlayHint)
are demand-driven; see ROADMAP § "Editor / IDE integration" for
the current queue.

To request a queued feature or report an LSP issue, open a GitHub
issue with: the editor + version, the Rigor version
(`rigor version`), the LSP log (`--log=PATH`), and a minimal
reproduction.
