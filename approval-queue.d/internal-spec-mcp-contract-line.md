# The binding MCP page makes the CLI-equivalence of a tool call, the fixed first content block and per-request era selection contract, and leaves message texts, `ttlMs`'s value, the tool surface's compatibility status and argument checking beyond three tools out of it

- **PR:** [#PRNUM](https://github.com/rigortype/rigor/pull/PRNUM)
- **Issue:** [#3402](https://github.com/rigortype/rigor/issues/3402)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-26

## Background

Until this PR no binding text described `rigor mcp`: ADR-33 and the manual carried it, and
`docs/internal-spec/config.md` covered only the tools' `config_warnings`. #3402's later slices add the
Skills extension, and need a page to extend. Writing `docs/internal-spec/mcp.md` from
`lib/rigor/mcp/` meant deciding, for each thing the code does, whether a client may rely on it. Nothing
earlier had drawn that line for this surface. `lens.md` and `diagnostic-shape.md` draw it for documents
(shape bound, type strings and firing sets not), which fits a tool's document but not the protocol
around it.

## Options and trade-offs

- **Bind everything the code does.** Easy to check, but it would pin error message texts, the order of
  argv options and the exact one-hour `ttlMs`, and turn the crashes found while writing (#3411) and the
  unenforced `required: ["paths"]` (#3412) into contract.
- **Bind only what MCP itself requires.** Leaves out what clients of this server actually lean on: that
  a tool's first content block is the CLI's output byte for byte, and that a legacy client is never
  read as a 2026-07-28 one.
- **Bind what a client needs to be correct, and mark the rest *implementation*.** Takes a decision per
  item, recorded below.

## Decision

The third. Made contract:

- a tool call answers what its CLI command, run with the listed argv from the server's working
  directory at that moment, would print; any cross-call caching (ADR-33's deferred slice 3) must be
  invisible;
- `content[0]` is the command's stdout (or stderr when stdout is empty), byte for byte; the extra
  blocks come after it in a fixed order, and clients must tolerate text blocks they do not recognise
  (ADR-5: a later block is not a break);
- the era is read from each request alone; notifications get no answer and have no effect;
- malformed messages must not stop the server, and SHOULD get `-32600` / `-32602` (today they crash
  it: #3411, recorded on the page as a deviation);
- `cacheScope: "public"`, `listChanged: false`, `server/discover` omitting an empty `extensions`, and
  the reserved `io.modelcontextprotocol/skills` identifier, specified by #3402's slice and not here;
- `-32602` for the three tools whose missing arguments the server checks today.

Left out: JSON-RPC error and server-written message texts, descriptions, `ttlMs`'s value, member and
option order, wrong-typed arguments, and a `rigor_check` / `rigor_coverage` call without `paths`
(unspecified until #3412 picks enforcing or documenting the fallback).

The page also says it does not make the tool catalogue a row of `docs/compatibility.md`. That would be
a new public-contract commitment, which is the maintainer's call; the page only notes that each tool's
document inherits its command's contract. ADR-5's robustness principle is the precedent for the
liberal reading side: accept and answer, never crash, and tolerate additions.

## To undo

Each item is one sentence of `docs/internal-spec/mcp.md`. To bind a left-out item, move its sentence out
of an *Implementation* note or § "What is not contract"; to unbind one, the reverse. Nothing in code
depends on the page yet; #3411 and #3412 cite it, and #3402's next slice will extend § Extensions.
