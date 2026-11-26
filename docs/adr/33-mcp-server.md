# ADR-33 — MCP Server packaging

Status: **Accepted (2026-05-27); implemented in v0.1.10.**

The
`rigor mcp --transport stdio` subcommand ships a pure-Ruby JSON-RPC
2.0 MCP server exposing seven tools — `rigor_check`, `rigor_type_of`,
`rigor_triage`, `rigor_annotate`, `rigor_sig_gen`, `rigor_explain`,
`rigor_coverage`; `rigor_lens` joined them in v0.4.4. HTTP transport and
per-session environment caching remain deferred. What the server speaks
and serves is specified in
[`docs/internal-spec/mcp.md`](../internal-spec/mcp.md), which binds; this
ADR keeps the reasons.

## Context

Rigor already ships a Language Server (`rigor lsp`, ADR-19) that exposes its analysis
engine to editors over stdio using the LSP protocol.  A parallel adapter for the
**Model Context Protocol (MCP)** would let AI coding assistants (Claude Code, Cursor,
Cline, etc.) call Rigor tools directly — `rigor_check` before suggesting a refactor,
`rigor_type_of` to ground a hover-tooltip, `rigor_triage` to plan a project-wide cleanup.
LSP and MCP serve different consumers (editors vs. AI agents) and do not overlap.

MCP uses JSON-RPC 2.0 over a newline-delimited JSON stdio stream.  The protocol surface
is significantly simpler than LSP: there are no per-file buffer tables and no async push
notifications.  An MCP server is essentially a function dispatcher: `tools/list` → list
available tools; `tools/call` → call one.  The one negotiation step is the version and
capabilities exchange — a legacy `initialize` handshake, or, from revision 2026-07-28, the
`_meta` fields every request carries and the `server/discover` call (WD9).

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

The tools and the argv each one runs are listed in
[`mcp.md` § Tools](../internal-spec/mcp.md#tools); `rigor_lens` is the eighth,
added after this WD.

**Excluded:**

- `init`, `baseline`, `diff` — write-side or side-effecting commands.  MCP tools
  are advisory; modifying the project file tree is not appropriate for a tool call
  initiated by an AI agent.
- `lsp` — a different protocol, not a tool.

> **Status (2026-09-10): this partition is closed against a 2026-05-27 CLI.**
> `lib/rigor/cli.rb`'s `HANDLERS` has grown several read-only verbs since —
> `type-scan`, `effects`, `unused` ([ADR-102](102-unused-code-reachability-report.md)),
> `describe`, `docs`, `doctor` — none of which has an MCP tool or an entry in the
> "Excluded" list above, which still names only the four write-side commands this
> WD knew about. Re-adjudicate the seven-tool set against the current CLI verb
> surface before treating it as complete.

### WD6 — `isError` maps to EXIT_USAGE (64), not to "analysis found problems"

A `rigor check` run that finds diagnostics exits 1 — this is normal analysis output,
not an error.  `isError: true` is set only when the CLI exits with EXIT_USAGE (64),
meaning bad arguments or a runtime failure.  AI clients can read `isError: false`
JSON diagnostic arrays normally.

The rule as implemented is wider: exit 70 (internal error), and any
non-zero exit with nothing on stdout, are errors too, since no document
came back. The exact rule is
[`mcp.md` § Tool results](../internal-spec/mcp.md#tool-results).

### WD7 — Session-level `--config` default

`rigor mcp --config=PATH` sets a session-level default config path used when the
individual tool call does not supply its own `config` argument.  Mirrors `rigor lsp
--config`.

### WD8 — `rigor mcp` subcommand (`HANDLERS["mcp"]`)

Parallel to `HANDLERS["lsp"]` in `CLI::HANDLERS`.  The entry point is
`lib/rigor/cli/mcp_command.rb`; the server logic lives under `lib/rigor/mcp/`.

### WD9 — Dual-era protocol: 2026-07-28 per request, `initialize` for legacy clients

> Added 2026-11-26 ([#3402](https://github.com/rigortype/rigor/issues/3402), slice 1).

Revision [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
removes the `initialize` handshake: every request carries
`params._meta["io.modelcontextprotocol/protocolVersion"]` and
`["io.modelcontextprotocol/clientCapabilities"]`, a server must answer `server/discover`, and
every result carries `resultType`.  The MCP Skills extension (#3402's later slices) exists only
on this revision, and Claude Code asks stdio servers for this revision by default
([code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)).  Legacy clients still
open with `initialize`.

`rigor mcp` serves both eras, and picks one **per request, from that request alone**:

- `server/discover`, or any request other than `initialize` whose `_meta` names a protocol
  version, takes the 2026-07-28 rules, and its results carry the `resultType` and server info
  the revision asks of every result: the version checks, the error codes, the result
  envelope and the cache hints are in
  [`mcp.md` § Protocol eras](../internal-spec/mcp.md#protocol-eras).
- Everything else, `initialize` included, is the legacy protocol, byte-for-byte as before.

Rationale:

- **No era state.**  The spec says a dual-era server's `initialize` selects legacy semantics
  "scoped to the stdio process", without requiring a modern request after it to fail.  Reading
  the era off each request keeps the server as stateless as WD7 left it (the session `--config`
  default is still the only process state) and cannot misroute a request because of an earlier
  one.  No legacy revision sets `io.modelcontextprotocol/protocolVersion` in `_meta`, so
  the version field separates the eras without guessing.
- **The legacy reply stays `2024-11-05`.**  2025-11-25 is the newest legacy revision, and a
  client can still reach the legacy path asking for it (Claude Code does when its
  `server/discover` probe times out on a slow boot).  Nothing Rigor serves needs a later legacy
  revision: no tool uses `title`, `outputSchema`, `structuredContent` or annotations.  Bumping
  the answer would change what every legacy client sees for no capability gained.
- **`ping` is still answered** under 2026-07-28, which dropped it (ADR-5: a client that still
  pings stays connected).
- **No required client capability.**  Every tool is read-only (WD5), so nothing needs
  elicitation or sampling, and `-32021` is never sent.
- **`capabilities.extensions` is the seam for #3402.**  `Server::EXTENSIONS` is empty, and
  `server/discover` omits the key until a later slice adds `io.modelcontextprotocol/skills`.
  Tasks and elicitation stay out (#3402 § "Decided against, for now").

## Rejected alternatives

**Subprocess-per-call wrapper shell script** — cold-boots the engine on every
`tools/call`, adding hundreds of milliseconds of latency.  Rejected.

**Expose MCP alongside LSP in a single process** — the protocols are different enough
that mixing them in one entry point adds complexity for minimal gain.  Separate
`rigor lsp` and `rigor mcp` processes are cleaner.

**Using an MCP Ruby gem** — the protocol is simple and adding a runtime dependency
violates ADR-0.  Rejected.

**Locking the era per process at the first request** (WD9) — a process that saw
`initialize` would refuse 2026-07-28 requests, or the reverse.  The spec does not require it,
it adds the first piece of protocol state to the server, and the per-request rule already
answers every client correctly.  Rejected.

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
