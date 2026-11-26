# `rigor mcp`: the MCP server

Status: **Draft, binding on the implementation.** This page is what `rigor mcp` speaks and serves.
[ADR-33](../adr/33-mcp-server.md) records why; the user-facing guide is
[manual ch. 10](../manual/10-mcp-server.md). When this page and either of them disagree, this page binds
and the other is amended. A change to the behaviour below updates this page in the same pull request.

[`docs/compatibility.md`](../compatibility.md) lists `rigor mcp` and its flags under the CLI row; the
tool catalogue (§ Tools) is not an enumerated row there, and this page does not make it one. What a
tool returns is its CLI command's output, so the command's own contract covers the document a tool
carries (`lens/v0` stays experimental, [`lens.md`](lens.md)).

The keywords MUST, MUST NOT, SHOULD and MAY are used as in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).
"The server" is a `rigor mcp` process. Text marked *implementation* describes today's code and may change
without a change to this page.

## What is not contract

Clients MUST NOT depend on:

- the `message` text of any JSON-RPC error, or the text of a tool result the server writes itself
  (`Internal error: …`, `Command exited …`);
- tool and property `description` strings in `tools/list`;
- the value of `ttlMs` (only that it is a positive integer of milliseconds);
- the order of members inside any JSON object, or the order of options in the argv a tool runs;
- the version string in the server info, beyond its being the running `Rigor::VERSION`;
- how a request that breaks this page's MUSTs for clients is answered, except where a section says.

## Process and invocation

```text
rigor mcp [--transport=stdio] [--config=PATH]
```

- `--transport` accepts only `stdio`, its default. Any other value writes an error to stderr and exits
  64 before reading input. The flag exists so that another transport does not change the CLI
  ([ADR-33](../adr/33-mcp-server.md) WD2); none is specified.
- `--config=PATH` sets the session default configuration (§ Configuration). A path that names no file
  is refused at boot: the error goes to stderr and the process exits 64 before reading input. Whether
  the file loads is not checked until a tool call reads it.
- The process runs until its input reaches end of file, then exits 0.
- One process serves many requests ([ADR-33](../adr/33-mcp-server.md) WD3). The session `--config` is
  its only per-session setting. Ruby code the process has loaded (Rigor, plugin gems, the bundle) is
  kept across calls and not reloaded (§ Tools). *Implementation:* YJIT is enabled at boot.

## Transport

The transport is MCP's stdio transport: newline-delimited JSON-RPC 2.0 on the process's stdin and
stdout, with no `Content-Length` framing.

- **Input.** Each line is one JSON-RPC message. An empty line is skipped. A line that is not valid JSON
  MUST be answered with error `-32700` and `"id": null`, and the server MUST go on reading.
- **Output.** The server MUST write nothing to stdout but JSON-RPC responses, each one JSON object on
  one line, followed by `\n` and flushed. This holds while a tool runs: output a command writes past
  its own captured stream (an option parser's `--help`, a stray `puts`) MUST NOT reach stdout.
- **Stderr** is the server's log. *Implementation:* only an internal error during a tool call
  (§ Tool results) is logged there; a tool's own stderr is captured, not forwarded.
- **One response per request.** Every request (a message with a non-null `id`) MUST get exactly one
  response, carrying its `id`. *Implementation:* requests are handled one at a time, in arrival order,
  and each response is written before the next line is read. Clients match responses by `id`.
- **Notifications.** A request object with no `id`, or a null `id`, MUST NOT be answered, and MUST NOT change
  how any later request is answered. *Implementation:* it is dropped without reading its `method`, so
  `notifications/initialized`, `notifications/cancelled` and the rest have no effect.
- **Malformed messages.** A line that parses but is not a request object (a JSON array, such as a
  JSON-RPC batch, a number, a string, `true`, `false` or `null`), and a `tools/call` whose `params` is
  not an object, MUST NOT stop the server. The server MUST answer `-32600` with `"id": null` for the
  first, a batch as one message, and `-32602` with the request's `id` for the second
  ([#3411](https://github.com/rigortype/rigor/issues/3411)). A `tools/call` with no `params` is read as
  one with empty `params`. Other methods ignore their `params` other than `_meta`. The `jsonrpc`
  member is not checked; clients MUST send `"jsonrpc": "2.0"`.

## Protocol eras

The server speaks two eras of MCP and MUST choose one **for each request, from that request alone**
([ADR-33](../adr/33-mcp-server.md) WD9). No request changes how a later one is answered: there is no
handshake state, a legacy request needs no `initialize` before it, and a 2026-07-28 request after an
`initialize` is still answered by the 2026-07-28 rules.

A request is a **2026-07-28 request** when its `method` is not `initialize` and either

- its `method` is `server/discover`, or
- `params` is an object whose `_meta` is an object holding the key
  `io.modelcontextprotocol/protocolVersion`, whatever its value.

Every other request, `initialize` always included, is a **legacy request**. No legacy revision puts that
key in `_meta`, so a legacy client is never read as a 2026-07-28 one; a legacy `_meta` holding only a
`progressToken` stays legacy.

### 2026-07-28 requests

Before the method is looked up, a 2026-07-28 request MUST pass these checks, in this order:

1. `_meta["io.modelcontextprotocol/protocolVersion"]` is a string, or the answer is `-32602`;
2. that string is one of `SUPPORTED_VERSIONS` (today `["2026-07-28"]`), or the answer is `-32022` with
   `data: {"supported": SUPPORTED_VERSIONS, "requested": <the string>}`;
3. `_meta["io.modelcontextprotocol/clientCapabilities"]` is an object, or the answer is `-32602`.

So `server/discover` with no `_meta` gets `-32602`, and an unknown method under an unsupported version
gets `-32022`, not `-32601`. The server requires no client capability: every tool is read-only
([ADR-33](../adr/33-mcp-server.md) WD5), so `-32021` (missing required client capability) is never
sent. A tool or extension that needs a client capability changes this sentence.

Every successful 2026-07-28 result is an object that MUST carry:

- `resultType: "complete"`. The server never answers with a partial or deferred result.
- `_meta["io.modelcontextprotocol/serverInfo"]`: `{"name": "rigor", "version": <Rigor::VERSION>}`. When
  the result already has a `_meta`, its keys are kept beside this one, and a key both name keeps the
  result's value.

An error response carries neither: the envelope is for results. The server-info key is the server's:
no result the server builds MAY put another value under it.

### Legacy requests

`initialize` MUST be answered, whatever `protocolVersion` the client asked for, with:

```json
{"protocolVersion": "2024-11-05",
 "capabilities": {"tools": {"listChanged": false}},
 "serverInfo": {"name": "rigor", "version": "<Rigor::VERSION>"}}
```

The answered revision is fixed at `2024-11-05` ([ADR-33](../adr/33-mcp-server.md) WD9 says why). Legacy
results carry no `resultType` and no server-info `_meta`.

## Methods

| Method | Legacy | 2026-07-28 | Result |
| --- | --- | --- | --- |
| `initialize` | yes | — (always legacy) | § Legacy requests |
| `server/discover` | — (always 2026-07-28) | yes | § `server/discover` |
| `ping` | yes | yes | `{}`, plus the envelope under 2026-07-28 |
| `tools/list` | yes | yes | `{"tools": [...]}`, plus the envelope and § Caching under 2026-07-28 |
| `tools/call` | yes | yes | § Tool calls, plus the envelope under 2026-07-28 |

Revision 2026-07-28 dropped `ping`; the server still answers it (ADR-5: a client that keeps pinging stays
connected). Any other method MUST get `-32601`, in either era. *Implementation:* a request object with
no `method` also gets `-32601`; JSON-RPC's `-32600` would fit it as well, and clients MUST NOT depend on
which.

### `server/discover`

```json
{"resultType": "complete",
 "supportedVersions": ["2026-07-28"],
 "capabilities": {"tools": {"listChanged": false}},
 "ttlMs": 3600000, "cacheScope": "public",
 "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "rigor", "version": "<Rigor::VERSION>"}}}
```

`supportedVersions` MUST equal `SUPPORTED_VERSIONS`, the list § 2026-07-28 requests checks against.

`capabilities.tools.listChanged` is `false` in both eras: the tool list MUST NOT change while the process
runs, and the server sends no `notifications/tools/list_changed`.

### Caching

`server/discover` and 2026-07-28 `tools/list` results MUST carry `ttlMs` and `cacheScope: "public"`.
Neither result varies within a process or between users, so the only staleness a cache can see is a
`rigor` upgrade under a running client; `ttlMs` bounds that. `tools/call` results carry neither.

### Extensions (reserved)

`capabilities.extensions` is the seam for MCP extensions. While the server serves none, `server/discover`
MUST omit the key rather than send an empty object. The identifier `io.modelcontextprotocol/skills` is
reserved for serving the gem-bundled `skills/` ([#3402](https://github.com/rigortype/rigor/issues/3402)):
this page does not specify it, and the change that serves it adds its methods, its settings object and
its errors here. An extension is advertised and served only to 2026-07-28 requests; the legacy
`initialize` capabilities stay `{"tools": {"listChanged": false}}`.

## Errors

| Code | Sent for |
| --- | --- |
| `-32700` | A line that is not valid JSON (`"id": null`). |
| `-32600` | A line that parses but is not a request object, a JSON-RPC batch included (`"id": null`). |
| `-32601` | A method neither era serves. |
| `-32602` | A 2026-07-28 request with a missing or non-string protocol version, or without `clientCapabilities`; a `tools/call` whose `params` is not an object; a `tools/call` naming no tool this server has, or missing an argument § Arguments says is checked. |
| `-32022` | A 2026-07-28 request naming a version not in `SUPPORTED_VERSIONS`, with `data.supported` and `data.requested`. |
| `-32021` | Never sent (§ 2026-07-28 requests). |

A failure of the analysis a tool runs is not a JSON-RPC error: it is a tool result with `isError: true`
(§ Tool results). A JSON-RPC error means the request itself could not be served.

## Tools

`tools/list` MUST list the same tools in both eras, each with `name`, `description` and an `inputSchema`
of `"type": "object"`. No tool declares `title`, `outputSchema` or annotations, and no result carries
`structuredContent`.

A tool is its CLI command run in the server process ([ADR-33](../adr/33-mcp-server.md) WD4): the server
builds the command's argv from the arguments and runs it with stdout and stderr captured. **A tool call
MUST answer what its command, run with that argv from the server's working directory at that moment,
would print, given the Ruby code already loaded into the process.** The project's sources, signatures
and configuration are read as they are on disk when the call runs: a cache the server holds across
calls (ADR-33's deferred environment caching included) MUST be invalidated by a change to any file the
answer read. Ruby code is the exception: a plugin gem or the bundle changed under a running server
takes effect when the server restarts.

Each tool runs exactly one command, with a fixed prefix, the options its arguments set, then `--` and
the operands. The `--` MUST be written whenever there is an operand, so an operand shaped like a flag
(`--version`, `-`, `--`) is read as a path, a position or a rule; `rigor_explain` without `rule` has
neither.

| Tool | Command prefix | Option properties | Operand properties | `required` |
| --- | --- | --- | --- | --- |
| `rigor_check` | `check --format=json --no-stats` | `config` | `paths` (each) | `paths` |
| `rigor_type_of` | `type-of --format=json` | `config` | `file`, `line`, `col` as one `FILE:LINE:COL` | `file`, `line`, `col` |
| `rigor_triage` | `triage --format=json` | `config`, `top` → `--top=N` | `paths` (each) | — |
| `rigor_lens` | `lens --format=json` | `config` | `files` (each) | `files` |
| `rigor_annotate` | `annotate --no-color` | `config` | `file` | `file` |
| `rigor_sig_gen` | `sig-gen --print --format=json` | `config`, `params` → `--params=V` | `paths` (each) | — |
| `rigor_explain` | `explain --format=json` | — | `rule`, when given | — |
| `rigor_coverage` | `coverage --format=json` | `config` | `paths` (each) | `paths` |

`config` becomes `--config=PATH` by § Configuration. `rigor_explain` reads no configuration and takes no
`config`. An operand property left out adds no operand, and the command then does what it does with
none: `rigor_triage` and `rigor_sig_gen` read the configured `paths:`, and `rigor_explain` lists every
rule.

Every write-side or side-effecting command is excluded ([ADR-33](../adr/33-mcp-server.md) WD5). A tool
MUST NOT write to the project tree; a command's own writes to its configured cache directory are not
project writes.

### Arguments

- Every input property MUST become either a flag the mapped command accepts, with an argument exactly
  when the flag takes one, or an operand. `spec/rigor/cli/catalogue_spec.rb` gates this against the
  command catalogue ([#2511](https://github.com/rigortype/rigor/issues/2511)), and lists the operand
  properties so a new one is a deliberate addition. An `enum` property (`rigor_sig_gen`'s `params`)
  MUST advertise only values the flag accepts; that is not gated yet
  ([#2553](https://github.com/rigortype/rigor/issues/2553)).
- The server MUST answer `-32602` for a `rigor_type_of` call without all of `file`, `line` and `col`, a
  `rigor_lens` call whose `files` is not a non-empty array of strings, and a `rigor_annotate` call
  without `file`.
- What a `rigor_check` or `rigor_coverage` call without `paths` does is unspecified: the schemas mark
  it required, and the server today runs the command over the configured `paths:`
  ([#3412](https://github.com/rigortype/rigor/issues/3412)). Clients MUST send it.
- Clients MUST send arguments their schema allows, in an `arguments` object. How anything else is
  answered is unspecified ([#3412](https://github.com/rigortype/rigor/issues/3412),
  [#3413](https://github.com/rigortype/rigor/issues/3413)).

### Configuration

The configuration a tool call reads is, first match wins ([ADR-33](../adr/33-mcp-server.md) WD7):

1. the call's `config` argument, when it is a string that is not blank;
2. the session default `rigor mcp --config=PATH`;
3. neither: no `--config` is passed, and the command discovers `.rigor.yml` / `.rigor.dist.yml` from
   the server's working directory, as the CLI does.

A blank `config` (empty or whitespace only) names no file, so the session default applies; it MUST NOT
reach the CLI as `--config=`. A `config` naming no file is the command's usage error, so the call is
`isError: true`, with the command's error as `content[0]` (*today a `config` that is a directory, is
unreadable or is not a string is reported as an internal error instead:*
[#3413](https://github.com/rigortype/rigor/issues/3413)). Relative paths, in `config` and in operands alike, resolve against the server's
working directory.

## Tool results

A `tools/call` that names a tool and passes § Arguments MUST be answered with a result (never a
JSON-RPC error), of the form `{"content": [<text block>, ...], "isError": <boolean>}`.

- `content[0]` is a `text` block holding the command's whole stdout, byte for byte, when stdout is not
  empty, and the command's whole stderr otherwise.
- `isError` is `true` exactly when the command exits `64` (usage) or `70` (internal error), or exits
  non-zero with nothing on stdout. Otherwise it is `false`. So `rigor check` finding diagnostics (exit
  1, a document on stdout) is `false`, and so is a `lens` run whose every target failed (exit 1, with a
  document). This widens ADR-33 WD6, which named exit 64 alone; WD6 explains the line, this rule draws it.
- When the command raises instead of returning a status, the server MUST stay up and answer
  `isError: true`, with one text block saying so. A `SystemExit` is reported with its status; any other
  `StandardError` is logged to the server's stderr with its backtrace.

### Additional content blocks

After `content[0]`, a result carries zero or more further `text` blocks, each present only under its
condition, in this order:

1. **Configuration warnings** (#2231). For every tool that takes `config`, when the configuration
   § Configuration selects loads and has [config-audit warnings](config.md#the-three-validation-tiers): a
   block whose text is the JSON object `{"config_warnings": [...]}`, each entry the shape
   `rigor check --format=json` gives its `config_warnings` entries. It is omitted when `content[0]` is
   already a JSON object with a `config_warnings` key (`rigor_check`'s document), when there are no
   warnings, and when the configuration fails to load (the command reports that). It does not depend
   on `isError`.
2. **Shape notice** ([ADR-126](../adr/126-cli-grammar-and-catalogue.md) WD4). For `rigor_type_of` and
   `rigor_explain`, when stdout is not empty and the command's stderr holds the one-line notice that
   their JSON's top-level shape changes in the next minor: a block holding that line. It is
   transitional, and goes when the shape changes.
3. **Coverage stderr** ([#2206](https://github.com/rigortype/rigor/issues/2206)). For `rigor_coverage`,
   when stdout is not empty and stderr is not blank: a block holding the command's whole stderr,
   unfiltered, so the paths it skipped beside the measured ones reach the client.

Every block leaves `content[0]` as the command wrote it. Clients MUST tolerate `text` blocks after
`content[0]` that they do not recognise: a later change may add one under a new condition, and only
the position of `content[0]` is fixed.

## Gates

`spec/rigor/mcp/server_spec.rb` and `spec/rigor/mcp/loop_spec.rb` pin this page's behaviour: the exact
argv of `rigor_check`, `rigor_type_of`, `rigor_triage` and `rigor_sig_gen`, and the `--` before the
operands of every tool. `spec/rigor/cli/catalogue_spec.rb` ties every tool to a catalogued command
(ADR-126 WD3) and every input property to that command's flags (#2511).
