# Language Server — in-process Ruby LSP for Rigor

**Status:** Draft. Supersedes only when a future ADR is opened against
the contract.

[ADR-0](../adr/0-concept.md) deferred LSP integration so the CLI-first
inference engine could mature. Editor mode v1
([`docs/design/20260516-editor-mode.md`](20260516-editor-mode.md)) is
the CLI-shell-out floor and works today. This doc designs the
**in-process Ruby Language Server** that turns that floor into a
"keystroke-fast" feedback loop without re-spending Ruby VM / RBS
env startup on every keystroke.

The framing decisions, language comparison, and architecture-three-way
discussion are not repeated here; see the chat thread that produced
this doc. This file binds the decisions.

## Decisions

- **Architecture: B (in-process Ruby LSP).** One LSP process hosts
  `Rigor::Analysis::Runner`, plugins, `Environment`, the RBS load,
  and a Ractor pool. Per-request work is per-buffer inference only.
- **Language: Ruby.** Same runtime as the analyzer. No IPC, no
  shell-out, no cross-language type marshalling.
- **Library: `language_server-protocol` gem (thin).** Provides
  JSON-RPC framing + the LSP type set. Solargraph / RuboCop LSP /
  Steep all use it. Rigor owns its own dispatcher, lifecycle, and
  message routing rather than living inside `ruby-lsp`'s addon
  framework (which assumes a Shopify-style lifecycle Rigor doesn't
  fit).
- **CLI surface: `rigor lsp` subcommand.** Same gem, same binary,
  same configuration discovery as `rigor check` / `rigor type-of`.
  No separate gem to publish today; the v1 LSP is part of the
  rigor gem itself. The packaging shape (bundled vs.
  standalone `rigor-lsp` gem vs. `ruby-lsp-rigor` addon) is
  decided in [`ADR-19`](../adr/19-language-server-packaging.md)
  along with the trigger conditions that would re-open the
  question.
- **Transport: stdio JSON-RPC.** No TCP / IPC / Unix socket in v1.

## Why architecture B beats A and C for Rigor

The bottleneck is not LSP protocol overhead. It's Ruby VM startup
(~150ms) plus `Environment.for_project` (~100-300ms warm,
1000ms+ cold) plus plugin loading. Editor mode v1's CLI shell-out
pays that cost on every keystroke; in-process pays it once and
amortizes across the session.

| | A (CLI shell-out) | B (in-process Ruby) | C (polyglot + Ruby daemon) |
|---|---|---|---|
| Wall clock per request | 500ms–1.5s | 30–200ms | 50–250ms |
| Analyzer interop | subprocess args | direct require | JSON-RPC / msgpack |
| Plugin facts shared across requests | no | **yes** | requires daemon API |
| Ractor pool reuse | impossible (one-shot) | **yes** | yes, daemon-side |
| Codebase footprint | 0 (editor mode v1) | LSP server | LSP shell + daemon + IPC schema |
| Distribution | single gem | single gem | single static binary + gem |

Architecture C wins on protocol-side perf and binary distribution
but loses on every other axis Rigor cares about today. If LSP
protocol latency ever becomes the bottleneck (no signal it will),
revisit C with Go or Rust as the protocol shell.

## CLI surface

```sh
rigor lsp [--transport=stdio] [--log=PATH] [--config=PATH]
```

- `--transport=stdio` (default; only value accepted in v1). TCP /
  Unix socket transports are queued behind concrete demand.
- `--log=PATH` writes LSP wire log + server-side debug output. When
  unset, server-side logs go to `stderr` (clients route via
  `window/logMessage`).
- `--config=PATH` mirrors `rigor check --config=PATH`. The LSP
  uses `Configuration.discover` (the same code path) when unset.

No positional arguments. The LSP server has no "paths" — the
client tells it what's open via `textDocument/didOpen`.

## Request → internal API mapping

| LSP method | Direction | Rigor internal | Notes |
|---|---|---|---|
| `initialize` | C→S | bootstrap `Environment.for_project` + plugin `#prepare` + pre-passes | Returns advertised capabilities. Project root from `rootUri` / `workspaceFolders`. |
| `initialized` | C→S | no-op | Triggers optional `workspace/didChangeWatchedFiles` registration. |
| `shutdown` | C→S | release runner, drain workers | Server stays alive until `exit`. |
| `exit` | C→S | `exit 0` | Terminates the process. |
| `textDocument/didOpen` | C→S | virtual file table `{uri => bytes}` | Triggers diagnostic publish. |
| `textDocument/didChange` | C→S | mutate virtual table | Triggers debounced diagnostic publish. |
| `textDocument/didSave` | C→S | no-op in v1 | Diagnostics already fresh from `didChange`. |
| `textDocument/didClose` | C→S | drop entry from virtual table | Publish empty diagnostics for the URI to clear inline markers. |
| `textDocument/publishDiagnostics` | S→C | `Runner.run(buffer:)` → `Result#diagnostics` → LSP `Diagnostic[]` | Per-file emission; one notification per dirty file. |
| `textDocument/hover` | C↔S | `Scope#type_of` at position (`Source::NodeLocator` + `ScopeIndexer`) — the existing `rigor type-of` core | Returns markdown body. |
| `textDocument/definition` | C↔S | (deferred) `Reflection` symbol index | Slice 7+. |
| `textDocument/documentSymbol` | C↔S | walk Prism AST collecting `ClassNode`/`ModuleNode`/`DefNode` → LSP `DocumentSymbol[]` | |
| `workspace/didChangeConfiguration` | C→S | `Configuration.discover` reload + Environment rebuild | Drops cached pre-passes. |
| `workspace/didChangeWatchedFiles` | C→S | per-file cache invalidation | See § "Project context refresh". |

Everything else is unadvertised in `ServerCapabilities`; clients
that ask receive `MethodNotFound`. Out-of-scope methods are
enumerated in § "Out of scope for v1".

## Buffer state model

The LSP server maintains a per-session `BufferTable` keyed by
`DocumentUri`:

```ruby
class BufferTable
  # uri -> { bytes: String, version: Integer, dirty: Boolean }
end
```

- `didOpen` populates an entry.
- `didChange` mutates `bytes` + bumps `version`. `dirty: true` until
  diagnostic publish completes.
- `didClose` deletes the entry. Diagnostics for the URI are
  cleared with an empty publish.

When a diagnostic run fires, the server materializes one
`BufferBinding` per dirty entry:

```ruby
BufferBinding.new(
  logical_path: uri_to_project_path(uri),
  physical_path: write_tempfile(bytes)
)
```

Path mapping (`uri_to_project_path`) normalises `file://...` to
the project-root-relative path the runner expects. On Windows the
URI decode is responsible for drive-letter folding; v1 spec for
that case lives in § "Open questions".

Why temp files instead of an in-memory `{path => bytes}` parser
override? `Runner` / `WorkerSession` / pre-pass scanners already
parse from physical paths through `BufferBinding.resolve`. Routing
the LSP buffer through a temp file reuses that contract bit-for-bit
— no new parser entry point, no second code path to maintain. The
temp file lives under `Dir.tmpdir` and is unlinked when the buffer
entry is dropped.

## Concurrency

- The LSP boots one Ractor pool sized N (`parallel.workers:` /
  `RIGOR_RACTOR_WORKERS`, mirroring `rigor check`).
- Workers are pre-warmed with `Environment` + plugins at
  `initialize` time, NOT lazily on first request. The session is
  long-lived (minutes to hours), so the cold-start tax is paid
  exactly once.
- Each `publishDiagnostics` request dispatches to one worker. The
  pool's existing per-worker reporters and FactStore continue to
  work as in `rigor check` pool mode.
- `hover` / `documentSymbol` requests can run inline on the main
  Ractor (cheap; no per-buffer inference).
- Cancellation: LSP `$/cancelRequest` is honored in v1 by setting
  a per-request cancel flag the worker checks between scope-index
  build steps. Granularity is coarse (one cancellation point per
  request mid-flight) — fine-grained AST-walk cancellation is
  deferred.

Editor mode v1 forces `workers: 0` because per-buffer one-shot
costs are dominated by pool warm-up. The LSP inverts that: the
pool warms once and stays alive, so the per-request cost lands
where it belongs (inference only).

## Project context refresh

The project-wide pre-passes (`SyntheticMethodScanner`,
`ProjectPatchedScanner`, plugin `#prepare`, dependency-source
walker) are expensive (~hundreds of ms to seconds depending on
project size). They MUST NOT re-run on every keystroke.

The session holds a **context generation counter** + a derived
snapshot:

```ruby
class ProjectContext
  attr_reader :generation, :synthetic_method_index,
              :project_patched_methods, :plugin_registry,
              :environment
end
```

Invalidation rules:

| Event | Action |
|---|---|
| `workspace/didChangeWatchedFiles` for a project `.rb` file | invalidate the per-file synthetic-method / project-patched contribution; rebuild affected index slice |
| `workspace/didChangeWatchedFiles` for `.rigor.yml` / `Gemfile.lock` | bump generation; rebuild whole context |
| `workspace/didChangeConfiguration` | bump generation; rebuild |
| `didChange` for an open buffer | NO invalidation — buffer is virtual, not on disk; pre-passes already see virtual bytes via `BufferBinding` |

Buffer pre-passes always rerun against the virtual file table when
publishing diagnostics — they're cheap enough at single-file scope.
Project-wide rerun is gated behind `workspace/didChangeWatchedFiles`.

If the client doesn't support `workspace/didChangeWatchedFiles`
(e.g. minimal clients), the LSP falls back to "rebuild context on
every Nth request" with N=20 as a safety hatch. Coarse but
correct.

## Diagnostic streaming

LSP requires server-pushed `textDocument/publishDiagnostics`. The
server publishes:

- On `didOpen` — fresh diagnostics for the opened buffer.
- On `didChange` — debounced 200ms after the LAST keystroke.
  Each new `didChange` resets the timer. Prevents publish storms
  during fast typing.
- On `didClose` — empty diagnostic array for the URI (clears
  inline markers).

Per-buffer scope: only the changed buffer gets a fresh publish.
This matches editor mode v1's single-file scope. When a per-file
diagnostic cache lands (queued, see ROADMAP § "Editor / IDE
integration"), the LSP can promote to project-scope publishes
cheaply.

Severity profile + per-rule overrides apply as in `rigor check`.
LSP `DiagnosticSeverity` mapping:

| Rigor `Diagnostic#severity` | LSP `DiagnosticSeverity` |
|---|---|
| `:error` | `Error` (1) |
| `:warning` | `Warning` (2) |
| `:info` | `Information` (3) |
| `:hint` | `Hint` (4) |

`source` field on LSP `Diagnostic` is `"rigor"`. `code` is the
rule identifier (`"call.undefined-method"`, `"flow.always-raises"`,
…). `data` carries the plugin source family (`:builtin` /
`"plugin.activerecord"` / …) so client-side filters can be wired
later.

## Capabilities advertised in v1

```ruby
{
  textDocumentSync: {
    openClose: true,
    change: TextDocumentSyncKind::FULL  # incremental queued
  },
  diagnosticProvider: {
    interFileDependencies: false,        # single-file scope
    workspaceDiagnostics: false
  },
  hoverProvider: true,
  documentSymbolProvider: true,
  positionEncoding: "utf-16"             # LSP default; UTF-8 queued
}
```

`change: FULL` ships first because incremental change handling
requires line/column tracking against UTF-16 code units — non-trivial
correctness work. `FULL` resends the whole buffer on every keystroke;
network is local stdio so the bandwidth is irrelevant, and the cost
is in the runner, not in transport.

Incremental change handling is queued for slice 9+.

## Library choice

`language_server-protocol` (mtsmfm) ships:

- JSON-RPC framing over `stdio` / `socket`.
- The full LSP type set as Ruby Data-shaped value classes.
- A minimal `LanguageServer::Protocol::Transport::Stdio` reader/writer.

What it does NOT ship:

- A server lifecycle. We own `LanguageServer::Server` (state
  machine: uninitialized → initialized → shutdown → exit).
- A request dispatcher. We own a method-symbol → handler hash.
- A worker pool. We bind directly to Rigor's Ractor pool.

`ruby-lsp` (Shopify) ships all three but assumes a specific addon
lifecycle and an opinionated "extensions register here" surface
that's redundant for a single-tool LSP. Rigor doesn't need the
multi-extension scaffolding; we want the minimal protocol layer
with full control of the lifecycle. Hence the thin choice.

## Slicing

Each slice ships its own commit with specs. Same discipline as
editor mode v1's seven-slice cut.

1. **`rigor lsp` CLI subcommand stub.** Accepts `--transport=stdio`,
   prints capabilities skeleton, exits on `shutdown`+`exit`. No
   real analysis yet. Spec: dispatch a minimal `initialize` →
   `shutdown` → `exit` sequence through `LanguageServer::Server`
   and assert the response shape.
2. **`Rigor::LanguageServer::Server` lifecycle.** State machine,
   JSON-RPC dispatcher over stdio, capability negotiation.
   Re-uses `language_server-protocol` for framing.
3. **`BufferTable` + `didOpen` / `didChange` / `didClose`.**
   Maintains the virtual file table. No diagnostics yet.
4. **`publishDiagnostics` on `didChange` (debounced 200ms).**
   Materialise `BufferBinding`, run `Runner` with buffer mode,
   convert `Diagnostic`s to LSP shape, push. End-to-end the first
   user-visible payoff.
5. **`textDocument/hover`.** Wraps `rigor type-of`'s core (Scope
   index + `NodeLocator` + `Scope#type_of`). Returns a markdown
   hover body with type + RBS-erased form.
6. **`textDocument/documentSymbol`.** Walks Prism AST collecting
   `ClassNode` / `ModuleNode` / `DefNode` → LSP `DocumentSymbol[]`.
7. **`workspace/didChangeWatchedFiles` + ProjectContext invalidation.**
   File-system events drop the affected index slice; pre-passes
   rebuild incrementally.
8. **Ractor pool integration.** LSP boots a pool at
   `initialize`; per-request diagnostics dispatch into the pool.
   `hover` / `documentSymbol` stay main-Ractor.
9. **(deferred) `textDocument/definition`** — needs a
   `Reflection`-side symbol index keyed on FILE:LINE.
10. **(deferred) Incremental `didChange`** — UTF-16 offset
    bookkeeping + line/column conversion.

After slice 8 the v1 LSP is feature-complete for the
"keystroke-fast linting + hover-type" loop that the editor mode
v1 already targets but at 10× the responsiveness.

## Out of scope for v1

- `textDocument/completion` (substantial — needs a separate
  completion-engine design; not blocked by anything in this doc).
- `textDocument/codeAction` (refactorings — different problem).
- `textDocument/formatting` (RuboCop's job).
- `textDocument/rename` (needs a project-wide symbol index).
- `textDocument/semanticTokens` (cosmetic, optional).
- `textDocument/inlayHint` (cosmetic, optional).
- Multi-root workspaces (single-root only in v1).
- TCP / socket transports.
- Incremental sync (queued as slice 10).
- Cancellation finer than per-request (queued).

## Open questions

- **Windows path encoding.** LSP URIs decode `file:///C:/foo/bar.rb`
  on Windows; the project-relative path mapping needs to handle the
  drive-letter case + path-separator folding. v1 documents the
  expected shape but Windows CI for the LSP isn't planned for v1.
- **Logging policy.** Server-side log writes split: protocol log
  (LSP `window/logMessage` events sent to the client) vs operational
  log (file written under `--log=PATH`). Recommend mirror to both
  when `--log` is set; otherwise file-log goes to `stderr` and
  client sees only `:error`-level events via `showMessage`.
- **Configuration reload.** `workspace/didChangeConfiguration`
  payload format is client-specific. v1 ignores the payload and
  re-runs `Configuration.discover`. A `--workspace-config-format`
  flag may surface later if specific clients (Neovim's lspconfig,
  VSCode's Rigor extension) want bespoke shapes.
- **Hover content format.** LSP `Hover#contents` accepts
  `MarkupContent { kind, value }`. v1 ships `kind: "markdown"` with
  ```` ```ruby ```` code blocks for type + RBS-erased lines. Plain
  text fallback for clients that only support
  `MarkupKind::PlainText` is queued.
- **`initializationOptions` shape.** v1 reads `config_path:` and
  `cache_path:` if present, both optional. The exact JSON-Schema
  for this is finalized when slice 1 lands.
- **Single-buffer vs project-scope diagnostics.** The LSP inherits
  editor mode v1's "option A" (single-file scope). Once a per-file
  diagnostic cache lands (ROADMAP § "Editor / IDE integration"),
  the LSP can publish project-wide diagnostics on file save. The
  CLI shape is forward-compatible.

## Performance targets

These are aspirational steady-state targets after slice 8 against a
warm session on a current laptop (8-core, 32GB), 5K-file project:

| Operation | Target wall clock | Path |
|---|---|---|
| Cold start (`initialize` → first publish) | < 3s | Environment build + pre-passes |
| `didChange` → `publishDiagnostics` | < 250ms (p50), < 500ms (p95) | Debounce + single-file inference |
| `hover` | < 100ms (p95) | Scope index + type_of |
| `documentSymbol` | < 50ms (p95) | Prism walk |
| Memory steady-state | < 600 MB | RBS env + Ractor pool + N buffers |

The cold-start budget is dominated by RBS env build; cache-hit warm
start should be < 1.5s. The `didChange` budget assumes single-file
scope (option A). Option B (project scope + per-file diagnostic
cache) would tighten p95 substantially once available.
