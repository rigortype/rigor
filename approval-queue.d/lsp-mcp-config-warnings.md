# The language server shows config warnings as window/showMessage, and MCP tools append them as a second content block

- **PR:** [#2456](https://github.com/rigortype/rigor/pull/2456)
- **Issue:** [#2231](https://github.com/rigortype/rigor/issues/2231)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-27

## Background

`ConfigAudit.warnings` reached only `rigor check` and `rigor doctor`, so an editor or agent user whose
`.rigor.yml` held an inert entry (`undefined-method: "off"` at the top level, a `disable:` token naming
no rule) got no hint why the rule still fired. The issue asked for the language server to publish the
warnings "as a `window/showMessage` or as a diagnostic on `.rigor.yml`" and for the MCP tools to include
them "in their result payload", leaving both shapes open.

## Options and trade-offs

Language server:

- **`window/showMessage` (taken).** Needs no source position, which `ConfigAudit::Warning` does not
  carry, and works for a warning about a file reached through `includes:` or a config passed with
  `--config`. A message cannot be retracted, so it has to be rate-limited: one per warning at
  `initialized`, and again only when a save round's reload changes the warning set.
- **A diagnostic on `.rigor.yml`.** Stays visible and clears itself when fixed, but every warning would
  sit on line 1 (there is no position to give), the config may not be `.rigor.yml` at all, and the
  server would own clearing a URI no buffer opened.
- One combined message versus one per warning: one per warning, worded as `rigor check` prints each on
  STDERR (`rigor: …`), since clients render multi-line messages inconsistently.

MCP:

- **A second `text` content block `{"config_warnings": [...]}` (taken).** Leaves every tool's own
  output byte-for-byte as its CLI printed it (annotate is plain text; the JSON tools differ in
  formatting), and uses check's key and entry shape. `rigor_check`, whose document already carries the
  key, gets no second copy.
- Merging the key into each tool's JSON document. Closer to check's shape, but means re-serialising
  each tool's document and has no answer for `rigor_annotate`'s plain text.

## Decision

`window/showMessage` with `MessageType.Warning`, one per warning, announced once per distinct warning
set; and the second MCP content block for every tool taking a `config` argument, omitted when there are
no warnings or the configuration does not load.

## To undo

Remove `ProjectContext#unannounced_config_warnings`, `DiagnosticPublisher#announce_config_warnings` and
its two call sites (`Server#handle_initialized`, the save round), and `MCP::Server#with_config_warnings`;
the specs `spec/rigor/language_server/config_warnings_spec.rb` and the `config_warnings` group in
`spec/rigor/mcp/server_spec.rb` pin the current shape. Agents may come to read the second block.
