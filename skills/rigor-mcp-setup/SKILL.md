---
name: rigor-mcp-setup
description: |
  Wire Rigor's bundled MCP server (`rigor mcp`) into an AI coding agent (Claude Code, Claude Desktop, Cursor, Cline) so the agent can call Rigor's read-only analysis tools — rigor_check, rigor_type_of, rigor_triage, rigor_coverage, and more — during a session. The per-client config lives in the manual; this skill identifies the client, applies the right one, and verifies the handshake. Triggers: "set up rigor mcp", "give my AI agent Rigor tools", "wire Rigor into Claude Code / Cursor / Cline", "rigor MCP server". NOT for editor LSP integration (use rigor-editor-setup) or CI (use rigor-ci-setup).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor MCP Setup

`rigor mcp` is the Model Context Protocol server bundled with the
`rigortype` gem. It exposes Rigor's analysis as JSON-RPC tool calls over
stdio, so an AI coding agent can call Rigor directly during a session —
check types before a refactor, look up the type at a cursor, or triage a
project's diagnostics as review context. All tools are **read-only**
(write-side commands like `rigor init` / `sig-gen --write` are
deliberately excluded — modifying files stays the developer's call).

The authoritative, per-client configuration lives in the manual —
**[Rigor MCP Server — AI Agent Integration](https://github.com/rigortype/rigor/blob/master/docs/manual/10-mcp-server.md)**
— and is kept current there. This skill is the *workflow* around it
(identify the client → apply the manual's snippet → verify the
handshake), so it does not duplicate (and cannot stale-out) the config
details.

## When to use

- A developer wants their AI agent to call Rigor's tools mid-session.
- A project commits a shared MCP config (`.mcp.json`, `.cursor/mcp.json`)
  and you want to add Rigor to it for the whole team.

## When NOT to use

- Editor (human) integration — that is `rigor-editor-setup` (`rigor lsp`).
- The project has no Rigor config yet — run `rigor-project-init` first
  (the MCP tools use the same `.rigor.yml` discovery as `rigor check`).

## The tools you are wiring in

`rigor_check`, `rigor_type_of`, `rigor_triage`, `rigor_annotate`,
`rigor_sig_gen`, `rigor_explain`, `rigor_coverage` — each the JSON form
of the matching `rigor` CLI command. See the manual's **Tool reference**
for inputs and outputs.

## The one stable fact

Every client config simply launches **`rigor mcp`** (stdio) and needs
**`rigor` on the agent's `PATH`** — the same executable `rigor check`
uses. For agents that do not inherit your shell, the `mise` shim path is
the most reliable channel (see
[Installing Rigor](https://github.com/rigortype/rigor/blob/master/docs/install.md)).
Do **not** add `rigortype` to the project's `Gemfile` — it is a tool,
not a library.

## Procedure

### Phase 1 — confirm the analyzer works from the CLI first

```sh
rigor check <a-file-or-dir>
```

The MCP tools share `rigor check`'s config discovery. If `check` works
from the project root, the tools will too.

### Phase 2 — identify the client and apply the config

Ask the developer which agent they use, or detect a committed config
(`.mcp.json`, `.cursor/mcp.json`, `.claude/settings.json`). Apply the
matching snippet from the manual's **Client wiring** section verbatim —
it covers Claude Desktop, Claude Code CLI, Cursor, Cline, and a generic
stdio client:

<https://github.com/rigortype/rigor/blob/master/docs/manual/10-mcp-server.md>

Each snippet is the same shape — `{"command": "rigor", "args": ["mcp"]}`.
If the project commits a shared MCP config, add the Rigor entry there and
commit it so every contributor gets it.

**Working-directory gotcha (from the manual's Troubleshooting):** the
server discovers config from the directory it is launched in. If the
client starts `rigor mcp` from `$HOME` or a temp dir, no `.rigor.yml` is
found and tools return an empty set. Pin it with
`"args": ["mcp", "--config=/abs/path/.rigor.yml"]`, or pass absolute
`paths` in the tool call.

### Phase 3 — verify the handshake

Confirm `rigor mcp` answers the MCP `initialize` request:

```sh
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' | rigor mcp
```

A JSON `result` with `serverInfo.name: "rigor"` means it works; nothing
or a shell error means `rigor` is not on the PATH the client uses. Then
restart the client and confirm the `rigor_*` tools appear in its tool
palette.

## Next step

Re-run `rigor skill describe` for the next move — with the agent able to
call Rigor's tools, raising protection (`rigor-protection-uplift`) or
reducing a baseline (`rigor-baseline-reduce`) is a tighter loop.
