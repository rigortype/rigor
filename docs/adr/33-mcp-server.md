# ADR-33 — MCP Server packaging

**Status:** Accepted (2026-05-27); implemented in v0.1.10. The
`rigor mcp --transport stdio` subcommand ships a pure-Ruby JSON-RPC
2.0 MCP server exposing seven tools — `rigor_check`, `rigor_type_of`,
`rigor_triage`, `rigor_annotate`, `rigor_sig_gen`, `rigor_explain`,
`rigor_coverage`. HTTP transport and per-session environment caching
remain deferred.

## Context

Rigor already ships a Language Server (`rigor lsp`, ADR-19) that exposes its analysis
engine to editors over stdio using the LSP protocol.  A parallel adapter for the
**Model Context Protocol (MCP)** would let AI coding assistants (Claude Code, Cursor,
Cline, etc.) call Rigor tools directly — `rigor_check` before suggesting a refactor,
`rigor_type_of` to ground a hover-tooltip, `rigor_triage` to plan a project-wide cleanup.
LSP and MCP serve different consumers (editors vs. AI agents) and do not overlap.

MCP uses JSON-RPC 2.0 over a newline-delimited JSON stdio stream.  The protocol surface
is significantly simpler than LSP: there are no capabilities-negotiation round-trips, no
per-file buffer tables, and no async push notifications.  An MCP server is essentially a
function dispatcher: `tools/list` → list available tools; `tools/call` → call one.

## Decision

Ship a `rigor mcp` subcommand that starts a long-running MCP server over stdio.

## Working decisions

### WD1 — Pure-Ruby implementation; no MCP gem dependency

ADR-0's zero-runtime-dependency stance binds.  The MCP stdio transport is
newline-delimited JSON-RPC — simple enough to implement directly.  No new runtime
dependency is added to the gemspec.

### WD2 — stdio only for v1; HTTP transport deferred

Consistent with `rigor lsp` v1.  The only transport is `--transport stdio`.  HTTP
transport (e.g. for remote CI) is deferred to demand.  The flag is accepted and
validated so adding HTTP later does not change the CLI surface.

### WD3 — Long-running process, not subprocess-per-call

`rigor mcp` starts once and handles many `tools/call` requests in sequence, sharing
Ruby's `require` cache across calls.  The first call pays the full cold-boot cost; all
subsequent calls reuse the already-loaded engine code.  This mirrors `rigor lsp`.

### WD4 — In-process dispatch via CLI internals (StringIO capture)

Each tool call builds a synthetic `argv` and calls `CLI.new(argv, out:, err:).run`
with `StringIO` capturing stdout.  The tool result is the captured string.

Rationale: the existing CLI commands already know how to format their output as JSON
(`--format json`).  Reusing them keeps tools in sync with the CLI automatically —
any improvement to `rigor check --format json` is immediately visible via
`rigor_check`.  No separate tool-layer JSON serialisation is needed.

### WD5 — Seven read-only tools

| MCP tool | Underlying command |
|---|---|
| `rigor_check` | `rigor check --format json --no-stats [paths]` |
| `rigor_type_of` | `rigor type-of --format json FILE:LINE:COL` |
| `rigor_triage` | `rigor triage --format json [paths]` |
| `rigor_annotate` | `rigor annotate --no-color FILE` |
| `rigor_sig_gen` | `rigor sig-gen --print --format json [paths]` |
| `rigor_explain` | `rigor explain --format json [rule]` |
| `rigor_coverage` | `rigor coverage --format json paths` |

**Excluded:**

- `init`, `baseline`, `diff` — write-side or side-effecting commands.  MCP tools
  are advisory; modifying the project file tree is not appropriate for a tool call
  initiated by an AI agent.
- `lsp` — a different protocol, not a tool.

### WD6 — `isError` maps to EXIT_USAGE (64), not to "analysis found problems"

A `rigor check` run that finds diagnostics exits 1 — this is normal analysis output,
not an error.  `isError: true` is set only when the CLI exits with EXIT_USAGE (64),
meaning bad arguments or a runtime failure.  AI clients can read `isError: false`
JSON diagnostic arrays normally.

### WD7 — Session-level `--config` default

`rigor mcp --config=PATH` sets a session-level default config path used when the
individual tool call does not supply its own `config` argument.  Mirrors `rigor lsp
--config`.

### WD8 — `rigor mcp` subcommand (`HANDLERS["mcp"]`)

Parallel to `HANDLERS["lsp"]` in `CLI::HANDLERS`.  The entry point is
`lib/rigor/cli/mcp_command.rb`; the server logic lives under `lib/rigor/mcp/`.

## Rejected alternatives

**Subprocess-per-call wrapper shell script** — cold-boots the engine on every
`tools/call`, adding hundreds of milliseconds of latency.  Rejected.

**Expose MCP alongside LSP in a single process** — the protocols are different enough
that mixing them in one entry point adds complexity for minimal gain.  Separate
`rigor lsp` and `rigor mcp` processes are cleaner.

**Using an MCP Ruby gem** — the protocol is simple and adding a runtime dependency
violates ADR-0.  Rejected.

## Implementation slices

- **Slice 1 (this ADR):** `rigor mcp --transport stdio` with all seven tools.
  Pure-Ruby JSON-RPC loop + in-process CLI dispatch.  `MCP::Server` + `MCP::Loop`.
- **Slice 2 (demand-driven):** HTTP transport (Rack-based).
- **Slice 3 (demand-driven):** Environment caching across calls (warm `Environment`
  held in the server between `tools/call` requests, invalidated by a `mtime`-based
  check).

## Companion documents

- [ADR-19](19-language-server-packaging.md) — LSP packaging (same shape, parallel channel).
- [ADR-0](0-concept.md) — zero-runtime-dependency stance.
