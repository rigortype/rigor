# Rigor MCP Server — AI Agent Integration

`rigor mcp` is the Model Context Protocol (MCP) server bundled with the
`rigortype` gem. It exposes Rigor's analysis tools as JSON-RPC 2.0 tool
calls over a newline-delimited stdio stream, so AI coding assistants —
Claude Code, Cursor, Cline, VS Code Copilot Chat, and any other
MCP-aware agent — can call Rigor directly during a session.

## MCP vs LSP — choosing the right integration

Both `rigor lsp` and `rigor mcp` expose the same underlying engine.
The difference is the consumer.

| | `rigor lsp` | `rigor mcp` |
|---|---|---|
| Protocol | Language Server Protocol | Model Context Protocol |
| Consumer | Your editor | An AI coding agent |
| Interaction | Continuous (push diagnostics on every save) | On-demand (agent calls a tool when it decides to) |
| Transport | stdio (TCP queued) | stdio (HTTP queued) |
| When to use | Editor integration | AI-assisted development |

Use `rigor lsp` to get inline diagnostics and hover in Neovim, VS Code,
Helix, or Emacs. Use `rigor mcp` to let an AI agent check types before
suggesting a refactor, look up the type at a cursor position, or triage
a project's diagnostic set as context for a code-review session.

There is no conflict in running both simultaneously.

## Tools at a glance

| Tool | Underlying command | Returns |
|---|---|---|
| `rigor_check` | `rigor check --format json` | JSON diagnostic report |
| `rigor_type_of` | `rigor type-of --format json` | JSON type at `FILE:LINE:COL` |
| `rigor_triage` | `rigor triage --format json` | JSON distribution + hotspots + hints |
| `rigor_annotate` | `rigor annotate --no-color` | Annotated Ruby source |
| `rigor_sig_gen` | `rigor sig-gen --print --format json` | JSON RBS skeleton candidates |
| `rigor_explain` | `rigor explain --format json` | JSON rule catalog entries |
| `rigor_coverage` | `rigor coverage --format json` | JSON precision-tier breakdown |

All tools are read-only. Write-side operations (`rigor init`,
`rigor baseline generate`, `rigor sig-gen --write`) are intentionally
excluded — modifying project files is the developer's call, not an
agent's tool call.

## Prerequisites

The single prerequisite is **`rigor` on your `PATH`** — the same
executable `rigor check` and `rigor lsp` already use. Any install
channel in [Installing Rigor](01-installation.md) provides it; `mise`
is the recommended channel because its shims make `rigor` available to
processes (and AI agents) that do not inherit your shell environment.

Do **not** add `rigortype` to your project's `Gemfile`. Rigor is a
tool, not a library. See
[Installing Rigor § Recommended — a runtime version manager](01-installation.md#recommended--a-runtime-version-manager).

## CLI

```sh
rigor mcp [--transport=stdio] [--config=PATH]
```

- `--transport=stdio` — default; only value accepted in v1. HTTP
  transport is queued for v2.
- `--config=PATH` — session-level default config path. Individual tool
  calls may supply their own `config` argument, which takes precedence.
  Without either, `Configuration.discover` walks `.rigor.yml` /
  `.rigor.dist.yml` from the working directory.

Exit codes: 0 (clean shutdown — stdin EOF), 64 (unknown
`--transport`).

## Client wiring

### Claude Desktop

Add an entry to `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "rigor": {
      "command": "rigor",
      "args": ["mcp"]
    }
  }
}
```

Restart Claude Desktop. The `rigor_check`, `rigor_type_of`, and other
tools will appear in the model's tool palette. To pin the analysis to a
specific project config:

```json
{
  "mcpServers": {
    "rigor": {
      "command": "rigor",
      "args": ["mcp", "--config=/path/to/project/.rigor.yml"]
    }
  }
}
```

### Claude Code CLI

Claude Code reads MCP server definitions from its project-level
settings. Add to `.claude/settings.json` in your project root:

```json
{
  "mcpServers": {
    "rigor": {
      "command": "rigor",
      "args": ["mcp"]
    }
  }
}
```

Or register it globally in `~/.claude/settings.json` so it is
available in every project. Once registered, Claude Code can call
`rigor_check` on files it is about to edit, use `rigor_type_of` to
ground a suggestion, and run `rigor_triage` to understand a project's
diagnostic shape before proposing a cleanup plan.

### Cursor

Add to `.cursor/mcp.json` (project root) or `~/.cursor/mcp.json`
(user-level):

```json
{
  "mcpServers": {
    "rigor": {
      "command": "rigor",
      "args": ["mcp"]
    }
  }
}
```

Cursor's Composer will then offer Rigor tools alongside its built-in
capabilities. `rigor_check` is especially useful before a Composer
refactor — run it first so the agent knows the current diagnostic
baseline, then compare after.

### Cline (VS Code extension)

Open the Cline panel → MCP Servers → Add Server → Custom, and fill in:

| Field | Value |
|---|---|
| Name | `rigor` |
| Command | `rigor` |
| Args | `["mcp"]` |

Or add directly to Cline's `cline_mcp_settings.json`:

```json
{
  "mcpServers": {
    "rigor": {
      "command": "rigor",
      "args": ["mcp"]
    }
  }
}
```

### Generic / custom MCP client

`rigor mcp` speaks the [MCP stdio transport](https://spec.modelcontextprotocol.io/specification/basic/transports/#stdio):
one JSON-RPC 2.0 message per line, `\n`-terminated, no
`Content-Length` framing. Any client that follows this convention
works. The initialization sequence:

```
→  {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"my-agent","version":"1.0"}}}
←  {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"rigor","version":"0.1.9"}}}
→  {"jsonrpc":"2.0","method":"notifications/initialized"}
→  {"jsonrpc":"2.0","id":1,"method":"tools/list"}
←  {"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}
```

All messages except `notifications/*` require a response.
`notifications/*` carry no `id` and are silently consumed.

## Tool reference

### rigor_check

Analyze one or more Ruby files or directories for type errors,
undefined methods, arity mismatches, and nil-receiver risks.

**Input:**

| Argument | Type | Required | Default |
|---|---|---|---|
| `paths` | `string[]` | yes | — |
| `config` | `string` | no | session default |

**Returns:** JSON — the same structure as `rigor check --format json`.

```json
{
  "diagnostics": [
    {
      "path": "app/models/user.rb",
      "line": 42,
      "column": 5,
      "rule": "call.undefined-method",
      "severity": "error",
      "message": "undefined method `naem` for String"
    }
  ]
}
```

`isError` is `false` when the run completes normally, even if
diagnostics were found. `isError: true` signals a configuration or
runtime failure (bad path, unreadable config, etc.).

**Typical agent use:** call `rigor_check` on the files an agent is
about to edit, record the baseline, apply the edit, call again, diff
the two diagnostic arrays to see whether the change introduced or
resolved issues.

---

### rigor_type_of

Get the inferred type of the expression at a specific source location.

**Input:**

| Argument | Type | Required |
|---|---|---|
| `file` | `string` | yes |
| `line` | `integer` (1-based) | yes |
| `col` | `integer` (1-based) | yes |
| `config` | `string` | no |

**Returns:** JSON — the same as `rigor type-of --format json`.

```json
{
  "file": "lib/order.rb",
  "line": 17,
  "column": 10,
  "node": "LocalVariableReadNode",
  "type": "Integer | nil",
  "erased": "Integer?"
}
```

**Typical agent use:** ground a hover explanation ("what type is `x`
at this cursor position?") or validate a type assumption before
generating a signature.

---

### rigor_triage

Summarize a project's diagnostic stream: rule distribution,
per-file hotspots, and heuristic hints for the most common error
clusters.

**Input:**

| Argument | Type | Required | Default |
|---|---|---|---|
| `paths` | `string[]` | no | configured paths |
| `top` | `integer` | no | `10` |
| `config` | `string` | no | session default |

**Returns:** JSON — the same as `rigor triage --format json`.

```json
{
  "summary": { "total_diagnostics": 488, "files_with_diagnostics": 31 },
  "distribution": [
    { "rule": "call.possible-nil-receiver", "count": 212, "pct": 43.4 }
  ],
  "hotspots": [
    { "path": "app/models/account.rb", "count": 38 }
  ],
  "hints": [
    { "id": "H1", "message": "Likely missing ActiveSupport core_ext RBS ...", "action": "..." }
  ]
}
```

**Typical agent use:** run `rigor_triage` at the start of a code
review or cleanup session to understand the diagnostic landscape before
deciding which rules and files to focus on.

---

### rigor_annotate

Return the given Ruby source file with each line's last-expression
type appended as a `#=> dump_type:` comment. `def` header lines show
the method's inferred return type.

**Input:**

| Argument | Type | Required |
|---|---|---|
| `file` | `string` | yes |
| `config` | `string` | no |

**Returns:** Plain text (annotated Ruby source). Not JSON.

```ruby
module Rigor
  VERSION = "0.1.9"  #=> dump_type: "0.1.9"
end
```

**Typical agent use:** understand how Rigor infers types through a
specific file without having to call `rigor_type_of` line by line.

---

### rigor_sig_gen

Generate RBS skeleton signatures inferred from Ruby source files.

**Input:**

| Argument | Type | Required | Default |
|---|---|---|---|
| `paths` | `string[]` | no | configured paths |
| `params` | `"untyped"` \| `"observed"` | no | `"untyped"` |
| `config` | `string` | no | session default |

`params: "observed"` harvests call-site argument types from `spec/`
(or a directory named via `--observe=PATH` in the underlying CLI).

**Returns:** JSON — the same as `rigor sig-gen --print --format json`.

```json
{
  "candidates": [
    {
      "class_name": "Order",
      "method_name": "total",
      "kind": "instance",
      "classification": "new-method",
      "rbs": "def total: () -> Integer"
    }
  ]
}
```

Classifications: `new-file`, `new-method`, `tighter-return`,
`equivalent`, `skipped`.

**Typical agent use:** call `rigor_sig_gen` to see which methods have
precise enough returns to be worth writing into `sig/`, then generate
and insert the RBS. The agent should NOT write signatures
automatically — present the candidates for human review, then apply
confirmed entries via `rigor sig-gen --write`.

---

### rigor_explain

Look up the description of one or all Rigor diagnostic rules.

**Input:**

| Argument | Type | Required | Notes |
|---|---|---|---|
| `rule` | `string` | no | Omit to get the full catalog |

Accepted values: a canonical rule ID (`call.undefined-method`), a
legacy alias (`undefined-method`), or a family prefix (`call`, `flow`,
`assert`, `dump`, `def`).

**Returns:** JSON — an array of rule catalog entries.

```json
[
  {
    "id": "call.undefined-method",
    "summary": "Method not found on the inferred receiver type.",
    "severity_authored": "error",
    "since": "0.0.1",
    "fires_when": ["..."],
    "does_not_fire_when": ["..."],
    "suppression": "# rigor:disable call.undefined-method"
  }
]
```

**Typical agent use:** explain a diagnostic to the user, or look up
whether a rule fires in a specific situation before deciding whether a
finding is a real bug.

---

### rigor_coverage

Report type-precision coverage: the ratio of expressions Rigor types
as `Constant` / `Nominal` / shaped / refined (precise) versus
`Dynamic[Top]` or `top` (opaque).

**Input:**

| Argument | Type | Required |
|---|---|---|
| `paths` | `string[]` | yes |
| `config` | `string` | no |

**Returns:** JSON — the same as `rigor coverage --format json`.

```json
{
  "summary": {
    "files_processed": 12,
    "expressions_typed": 3841,
    "precision_ratio": 0.447
  },
  "tiers": {
    "constant": 312, "nominal": 903, "shaped": 46,
    "refined": 71, "bot": 381,
    "dynamic_specific": 512, "dynamic_top": 1498, "top": 118
  },
  "files": [
    {
      "path": "lib/order.rb",
      "expressions_typed": 214,
      "precision_ratio": 0.612
    }
  ]
}
```

**Typical agent use:** measure the impact of adding a fold rule or RBS
annotation — call `rigor_coverage` before and after, compare the
`precision_ratio` delta.

---

## Troubleshooting

**The MCP server starts but the client shows no tools.**

Run `rigor mcp` manually in a terminal and send the handshake:

```sh
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' | rigor mcp
```

You should get a JSON response. If you get nothing or a shell error,
`rigor` is not on your `PATH` — fix the install path first (see
[Installing Rigor](01-installation.md)).

**`rigor_check` / `rigor_triage` return an empty diagnostics array on a project that has errors.**

The tool uses `Configuration.discover` from the working directory the
MCP server was started in. If the client launches `rigor mcp` from a
home or temp directory, no `.rigor.yml` is found and the configured
paths default to the empty set. Mitigations:

- Pass `--config=/path/to/project/.rigor.yml` when launching:
  `"args": ["mcp", "--config=/path/to/project/.rigor.yml"]`
- Or pass an absolute `paths` argument in the tool call:
  `{ "name": "rigor_check", "arguments": { "paths": ["/path/to/project/lib"] } }`

**`rigor_type_of` reports `isError: true`.**

The file path must be the exact on-disk path readable from the server
process. Relative paths are resolved from the server's working
directory. Use absolute paths from AI agents to avoid ambiguity.

**Tool calls are slow on first call, fast afterward.**

The first call in a session cold-boots the Ruby `require` cache;
subsequent calls reuse it. Expected warm-path latency:

| Tool | Cold (first call) | Warm (subsequent calls) |
|---|---|---|
| `rigor_explain` | < 200 ms | < 5 ms |
| `rigor_type_of` | ~1.5 s | ~200 ms |
| `rigor_check` (small project) | ~2 s | ~500 ms |
| `rigor_triage` (small project) | ~2 s | ~700 ms |

Cold-start is dominated by RBS environment build. A `.rigor/cache`
warmed by a prior `rigor check` run reduces it significantly.

## Status and roadmap

`rigor mcp` ships in the v0.2.0 evaluation release with all seven
tools and stdio transport. Queued follow-ups are demand-driven:

- **HTTP transport** (slice 2) — `--transport=http` for CI / remote
  agent use; a minimal Rack endpoint.
- **Across-call environment caching** (slice 3) — hold a warm
  `Environment` + `Cache::Store` in the server between calls,
  invalidated by an `mtime`-based check; reduces warm-path latency
  to near-zero for repeated calls against the same project.
- **`rigor_check` buffer mode** — accept an in-memory source buffer
  instead of (or alongside) a file path; mirrors the `--tmp-file` /
  `--instead-of` editor-mode flags. Useful when an AI agent has
  edited a file's content in-memory and wants to check the modified
  version before writing it.
- **`rigor_baseline_generate` (write-side, gated)** — explicitly
  opt-in write tool for agents operating with confirmed write
  permissions. Deferred until there is a clear demand signal.

To request a queued feature or report an issue, open a GitHub issue
with: the MCP client + version, the Rigor version (`rigor version`),
and the JSON-RPC exchange that triggered the problem.
