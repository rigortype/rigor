# ADR-33 — MCP Server packaging

Status: **Accepted (2026-05-27); implemented in v0.1.10.** WD10 (serving `skills/`) is
**Proposed (2026-11-27)** and not yet decided.

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

### WD10 — Serve the gem's own `skills/` over the Skills extension

> **Proposed 2026-11-27, awaiting the maintainer's decision** ([#3402](https://github.com/rigortype/rigor/issues/3402), slices 2–4).
> Nothing below is implemented yet. Points (a)–(f) are the decisions asked for; each states the
> recommendation this WD adopts if it is approved as written.

`skills/` (ADR-73) reaches an agent through its own install path (`npx skills`, a copy in
`.claude/skills/`), so a project can run one gem version's `rigor` while its agent reads another
version's skills. `rigor-upgrade`, `rigor-next-steps` and each skill's "load the version-current
copy" step (`rigor skill --full`) exist to paper over that drift. The
[Skills extension](https://modelcontextprotocol.io/extensions/skills/overview)
(`io.modelcontextprotocol/skills`, beta) lets an MCP server serve skills itself. Claude Code
(v2.1.331+) offers a server's skills as `<server>:<skill>`, so a client connected to `rigor mcp`
would load `rigor:rigor-next-steps` from the binary it is already running, with nothing else to
install and nothing to drift.

`skills/` stays the single source. Non-Claude agents read it directly in Agent Skills form, and
the MCP surface is a view of it, never a second copy.

**The surface.** Specified in full in `mcp.md` § Extensions when this lands. It is offered only
under 2026-07-28 (WD9). The legacy `initialize` capabilities stay `{"tools": {"listChanged": false}}`,
and a legacy request for any method below gets `-32601`.

- `server/discover` declares `capabilities.resources: {}` and
  `capabilities.extensions["io.modelcontextprotocol/skills"]: {}`. The extension requires the
  `resources` capability. `directoryRead` is not declared: every entry carries a complete manifest,
  so the client never needs to list a directory.
- `skills/list` returns one entry per skill: `uri` (`skill://<name>/SKILL.md`), `frontmatter` (the
  SKILL.md YAML front matter, parsed and passed through unchanged), and `resources`, a complete
  manifest of every served file as `{uri, digest: "sha256:<hex>", size}`. The result carries
  `resultType`, `ttlMs` and `cacheScope: "public"`. Eighteen skills fit one page, so no
  `nextCursor` is ever sent, and a `cursor` the server never issued gets `-32602`.
- `skills/get` takes `{uri}`, answers `{skill: <entry>}` for every served skill, and answers
  `-32602` for any other URI.
- `resources/read` serves each manifest file as one `text` content with `mimeType: "text/markdown"`.
  An unknown URI gets `-32602` with `data.uri`, never an empty `contents`.
- `resources/list` is required once `resources` is declared; (f) says what it lists.

The digests and sizes are computed from the bytes the process serves, and the size is the UTF-8
byte length. The client verifies each file against the manifest and the front matter against the
SKILL.md it reads, so a manifest built from one read of a file and content served from a later read
would fail verification after an in-place edit. The server therefore reads the served set once per
process, at the first skills or resources request, and serves every later request from that frozen
snapshot. Discover and tool calls never read it. The served set is 39 files and 308,891 bytes today.

**Gates.** Three new specs:

- The digest and size of every manifest entry match the bytes `resources/read` returns for it, and
  every entry's `frontmatter` equals the front matter of its SKILL.md.
- Claude Code's client limits hold over the real `skills/` tree: at most 100 skills per server,
  100,000 bytes per file and 400,000 bytes per skill. These are tighter than the spec's 512 files /
  16 MiB, and a client drops a skill that breaks them; the page does not say whether it warns. The
  limits are read as decimal kilobytes, the stricter reading. Today the largest skill,
  `rigor-project-init`, is 74,792 bytes in 7 files, and the largest file is 21,646 bytes.
- Every directory name equals its front matter `name`, and every relative link in a served file
  resolves to another served file.

Claude Code's limits are a client's and may change. The gate pins them as named constants with the
page they came from, so a change to them edits one line.

**(a) Where the skills are served from: the gem's install directory.** The server reads
`<gem root>/skills/`, located from `__dir__` exactly as `rigor skill` already does
(`CLI::SkillCommand::SKILLS_ROOT`), and serves the gemspec's two globs, `skills/*/SKILL.md` and
`skills/*/references/*.md`. That keeps the served set in lockstep with the binary, which is the
point of #3402. The server applies the globs itself rather than serving the directory, so a source
checkout serves exactly what the gem would ship. The `evals/` and `scripts/` directories some skills
carry for authoring stay out, and no served file links to them. Both read paths share one constant
so they cannot disagree. A build-time snapshot is rejected (see below).

**(b) On by default; `rigor mcp --no-skills` turns it off.** Serving skills adds a capability.
It changes no tool and no legacy reply, and a client that does not implement the extension ignores
it. Behind a flag, the users who would benefit most, the ones who never installed the skills
locally, would never see them. A user who wants the server to be tools-only has
`--no-skills`, which also drops `capabilities.resources`. Claude Code users can also deny
`Skill(mcp__rigor__*)` client-side. This is still a default users see change, which is why it is
asked rather than decided.

**(c) Links out of a skill become GitHub URLs, and a gate stops new ones.**
`skills/rigor-plugin-review/SKILL.md` links three binding specs as `../../docs/internal-spec/*.md`.
The gem does not ship `docs/internal-spec/`, so the links already lead nowhere in an installed gem,
and over MCP they resolve against `skill://` to nothing. `rigor docs` serves only the manual and the
handbook (ADR-74), so it cannot stand in. The links become
`https://github.com/rigortype/rigor/blob/master/docs/internal-spec/<file>.md`, the form the skills
already use for their web fallbacks. The relative-link gate above keeps a fourth from landing. A
`master` link can describe a newer contract than the installed gem; the plugin contract is
versioned in the page itself, which is the reader's check.

**(d) Slow boots: no server change; document running `rigor` directly.** The fallback seen in
#3404's smoke test was measured, 2026-11-27, on this machine:

- a cold Ruby boot of `rigor mcp` answers `server/discover` in about 0.14 s, because `rigor/cli` and
  the engine load at the first `tools/call` (WD4). `require "rigor/cli"` alone takes 0.04 s;
- `nix develop --command true` took 53 s on its first evaluation in a fresh worktree and 0.76 s warm.

The delay is the Flake's evaluation, which only a contributor's checkout pays. Discover already
answers before the engine loads, so there is nothing to make faster in the server. The work that
remains is to keep it that way, and to tell users what is at stake:

- a spec pins that `server/discover`, `skills/list`, `skills/get` and `resources/read` load neither
  `rigor/cli` nor the engine;
- the manual and `rigor-mcp-setup` say to launch the installed `rigor` (the mise shim or the gem's
  bin stub), never through `bundle exec`, `nix develop` or `npx`. Claude Code's troubleshooting
  advice names 3 seconds as the start-up time to stay under. Its docs say that with
  `MCP_PROTOCOL_NEGOTIATION` unset it "can skip asking a stdio server for 7 days", for example
  after the server exits when asked. A legacy connection is never offered skills, so the docs also
  say how to check (the `/mcp` page's Protocol row) and how to re-probe
  (`MCP_PROTOCOL_NEGOTIATION=auto`, then Reconnect).

**(e) Duplicates: document, do not detect.** A user who installed `skills/` locally and also
connects `rigor mcp` sees each skill twice in Claude Code, as `rigor-next-steps` and
`rigor:rigor-next-steps`. Claude Code's docs say nothing about precedence between the two. The
server cannot see a client's local skills, and refusing to serve them would punish the user it is
meant for. The docs say:

- keep the MCP copy where Claude Code offers MCP skills, which is the terminal, JetBrains and local
  Desktop sessions, and remove the local copy there;
- keep the local install for every other agent, and for the Claude Code surfaces that do not offer
  MCP skills: cloud sessions, `claude -p`, `claude remote-control` server mode, GitHub Actions and
  the Agent SDK.

Each skill's "load the version-current copy" step stays. It is a no-op for an MCP-served copy and
still needed for a local one, and one source serves both.

**(f) `resources/list` lists the served files.** Declaring `resources` makes `resources/list`
mandatory, and the 2026-07-28 spec says the answer is the resources currently available. It
permits an empty list, but the skill files are available, and the Skills spec's guidance on their
`resources/list` metadata (`mimeType: text/markdown`, `name` and `description` from the front
matter) assumes they appear there. The cost is that a client which surfaces resources, such as
Claude Code's `@` menu, shows about 40 Markdown files under `rigor`. An empty list would avoid
that noise while still meeting the letter of the spec; this WD takes the honest list.

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

**A build-time snapshot of `skills/`** (WD10 a) — a generated file the release builds, holding
the skills or their manifest. It adds a release step and a second copy that can drift from
`skills/`, and buys nothing the gem directory does not already give: the installed gem's files do
not change under a running process. Rejected.

**Serving skills behind an opt-in flag** (WD10 b) — the users with no local install, the ones
the extension helps most, would never turn it on. Rejected for an opt-out.

**Detecting a local install and skipping duplicates** (WD10 e) — the server cannot see the
client's skill directories, and a guess from the working directory would hide the version-locked
copy from the user it exists for. Rejected.

**Answering discover from a separate launcher before Ruby loads** (WD10 d) — discover already
answers in about 0.14 s; the slow boots came from `nix develop`, which no launcher inside the gem
can skip. Rejected.

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
