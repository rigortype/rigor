# rigor-rbs-inline

Ingests [rbs-inline](https://github.com/soutaro/rbs-inline)-shaped
comments (`# @rbs name: T`, `#: () -> T`, `# @rbs return: T`, attribute
`#:` casts, `# @rbs!` raw RBS, …) in your Ruby source and feeds the
synthesised RBS into the analysis environment — so a `# @rbs`
annotation Rigor would otherwise ignore becomes an enforced contract
that fires the same `argument-type-mismatch` diagnostics as a
hand-written `.rbs` file. The design is recorded in
[ADR-32](../../adr/32-rbs-inline-comment-ingestion.md).

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-rbs-inline
```

> **Full guide.** The worked walkthrough — every supported annotation
> form, the magic-comment opt-in, the top-level-`def` caveat, and parse-
> failure handling — is
> [handbook chapter 7 — RBS and Extended](../../handbook/07-rbs-and-extended.md),
> § "Inline RBS in Ruby source". This page is the operational quick
> reference.

## What it does

Per file, opt in with the upstream magic comment:

```ruby
# rbs_inline: enabled

class AscDesc
  # @rbs asc_or_desc: :asc | :desc
  def ascdesc(asc_or_desc) = asc_or_desc
end

AscDesc.new.ascdesc(:bad)   # error: argument type mismatch — expected :asc | :desc, got :bad
```

Files without `# rbs_inline: enabled` are untouched (a top-of-file scan
only). The synthesised RBS is cached per file (keyed on content SHA +
plugin id/version + config), so an unchanged second run skips the parse.

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.rbs-inline.source-rbs-synthesis-failed` | info | rbs-inline could not parse a file; analysis falls back to no inline-RBS contribution and the diagnostic carries the upstream error |

## Configuration

```yaml
plugins:
  - gem: rigor-rbs-inline
    config:
      require_magic_comment: true   # default
```

- **`require_magic_comment`** (default `true`) — when `true`, only files
  carrying `# rbs_inline: enabled` are processed. Set `false` to treat
  every file as if it carried the magic comment — useful only when you
  own the whole analysis scope (a single-file CI run or the hosted
  [browser playground](../../adr/29-browser-playground.md), which sets
  it so pasted snippets analyse without the magic line).

## Limitations

- **Top-level `def` produces no RBS.** Upstream rbs-inline emits nothing
  for a bare top-level `def` (verified against rbs-inline 0.14.0) —
  wrap the method in a `class` / `module`. This is an inherited upstream
  behaviour, not a Rigor limitation.
- **Parse failures fail soft.** A file rbs-inline can't parse is
  analysed as if it had no inline RBS (the `:info` diagnostic above
  records it); re-stamp the severity via `severity_profile:` to escalate.
- **Runtime dependency.** The plugin pulls in the `rbs-inline` gem; core
  `rigortype` stays zero-runtime-dep, so only projects that opt in pay it.

## Plugin internals

The synthesizer, the `source_rbs_synthesizer:` manifest hook, and the
caching wiring are in the
[plugin's README](../../../plugins/rigor-rbs-inline/README.md). To write
a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
