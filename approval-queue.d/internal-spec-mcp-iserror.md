# `isError` is true for exit 64 or 70, or any non-zero exit with no stdout, as the code does, and ADR-33 WD6 now points at that rule instead of naming exit 64 alone

- **PR:** [#3414](https://github.com/rigortype/rigor/pull/3414)
- **Issue:** [#3402](https://github.com/rigortype/rigor/issues/3402)
- **Class:** open-choice
- **Precedent:** [ADR-33](../docs/adr/33-mcp-server.md)
- **Decided:** 2026-11-26

## Background

ADR-33 WD6 says `isError: true` is set "only when the CLI exits with EXIT_USAGE (64)". The code
(`Rigor::MCP::Server#tool_result`) also sets it for exit 70 and for any non-zero exit with nothing on
stdout; the empty-stdout case came with the `rigor_lens` hardening (7ccd331b2), and the
manual already describes the wider rule ("a usage or runtime failure"). Writing the binding page
meant choosing which one binds.

## Options and trade-offs

- **Bind WD6's text.** A `lens` crash (exit 70) or a command that printed only an error to stderr would
  read as a successful result whose text is an error message. Agents would have to sniff the text.
- **Bind the code's rule.** Every case where no document came back is an error, and every case with a
  document (exit 1 from `check` or `lens`) is not, which is WD6's own reason ("analysis found problems
  is not an error") applied to the commands added since.

## Decision

The code's rule binds, in `docs/internal-spec/mcp.md` § "Tool results". It keeps WD6's distinction and
extends it to exit statuses WD6 did not foresee, so it is a clarification of an Accepted WD, not a
reversal. WD6 gains a paragraph pointing at the page. No behaviour changes.

## To undo

Narrowing to exit 64 alone is a code change in `tool_result` and its specs in
`spec/rigor/mcp/server_spec.rb` ("reports an error a command printed only to stderr as an error"), plus
the page's rule and WD6's paragraph. Clients reading `isError` for a crashed `lens` would then see
`false`.
