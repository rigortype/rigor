# rigor-rbs-inline

Bundled Rigor plugin that ingests
[rbs-inline](https://github.com/soutaro/rbs-inline)-shaped comments in
Ruby source files and contributes the synthesised RBS to the analysis
environment — closing the "the `# @rbs` comment in my `.rb` looks like
it should just work" gap. An annotation Rigor previously ignored becomes
an enforced contract that flows through the same `MethodParameterBinder`
+ `argument-type-mismatch` pipeline as a hand-written `.rbs` file.

> **Using this plugin?** The user guide — supported annotation forms,
> the magic-comment opt-in, configuration, the top-level-`def` caveat,
> and the parse-failure diagnostic — lives in the manual at
> [docs/manual/plugins/rigor-rbs-inline.md](../../docs/manual/plugins/rigor-rbs-inline.md),
> with the worked walkthrough in handbook chapter 7 § "Inline RBS in
> Ruby source". This README covers the plugin's internals.

ADR-32 records the design — including the working decisions this README
references (WD2, WD5, WD6, WD9, WD10).

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... source_rbs_synthesizer:)` (ADR-32) | A callable receiving a source path and returning RBS source, `nil`, or `[:error, message]` for fail-soft. |
| `manifest(... config_schema:)` | The `require_magic_comment` boolean (ADR-40 default `true`). |
| Per-instance `#manifest` override | Returns an instance-specific manifest with the synthesizer bound after `initialize`. |
| Fail-soft `Synthesizer` | Wraps upstream parser exceptions into `[:error, …]` tuples → the `source-rbs-synthesis-failed` `:info` diagnostic. |

## Caching

The synthesised RBS is cached per file. The cache key composes the
source file's content SHA, the plugin's id + version, and the plugin's
config hash (so flipping `require_magic_comment:` invalidates). A second
`rigor check` against unchanged sources skips the rbs-inline parse and
Writer render. See ADR-32 WD5 + ADR-6 for the cache backend.

## Dependencies

This plugin gem declares `rbs-inline` as a runtime dependency. The core
`rigortype` analyzer stays zero-runtime-dep per ADR-0 — only projects
that opt into this plugin pay the cost.

## License

[MPL-2.0](../../LICENSE), same as the parent project.
