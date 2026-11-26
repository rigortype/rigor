# `rigor_check` and `rigor_coverage` take `paths` as optional, defaulting to the configured paths

- **PR:** [#3430](https://github.com/rigortype/rigor/pull/3430)
- **Issue:** [#3412](https://github.com/rigortype/rigor/issues/3412)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-27

## Background

The MCP tools `rigor_check` and `rigor_coverage` declared `paths` in `inputSchema.required`, but the
server never enforced it: a call without `paths` ran `rigor check --` / `rigor coverage --` with no
operands, and the CLI fell back to the configured `paths:` (751 files on this repository). The other
two path-taking tools, `rigor_triage` and `rigor_sig_gen`, do not mark `paths` required and document
that fallback. #3412 asked for one answer so that schema and server agree, and left the direction
open. `docs/internal-spec/mcp.md` § Arguments recorded the case as unspecified.

## Options and trade-offs

- **Enforce `required: ["paths"]`** (`-32602` without it). Matches the schema as published; a
  client that followed the schema sees no change. It refuses calls the CLI accepts and that the server
  answered usefully until now, and keeps the four path-taking tools inconsistent with each other.
- **Drop `required` and document the fallback.** Matches the CLI, the other two tools and today's
  behaviour, so no working client breaks. A client that omits `paths` by mistake gets a whole-project
  run instead of an error; it is read-only (ADR-33 WD5), so the cost is time, not a wrong answer.

## Decision

Drop `required` for both tools; their `paths` descriptions now say "defaults to configured paths",
as `rigor_triage` and `rigor_sig_gen` do. The decision rests on its own grounds: it matches the CLI,
the two sibling tools (which have defaulted since ADR-33's first commit, 81fe708c8), and what the
server already did, and the call it keeps accepting is read-only (ADR-33 WD5). ADR-5 (lenient
inputs) and the false-positives-first rule point the same way only by analogy: one governs type
signatures and the other diagnostics, so neither is cited as the precedent. The binding page now says a tool's `required` lists exactly what the server refuses a call
without, and a spec in `spec/rigor/mcp/server_spec.rb` pins that for every tool.

## To undo

Restore `required: ["paths"]` on the two tools in `lib/rigor/mcp/server.rb`'s `TOOLS` and add a
`return nil unless` guard for `paths` in their `build_argv` branches. The per-tool spec then expects
the refusal without further change; drop the example that runs the two tools without `paths`, and
update `docs/internal-spec/mcp.md` § Tools and § Arguments, the two tables in
`docs/manual/10-mcp-server.md`, and the `rigor_check` row in
`skills/rigor-type-oracle/references/01-oracle-commands.md`. Nothing else depends on the decision.
