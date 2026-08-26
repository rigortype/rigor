# rigor-rbs-inline

Ingests [rbs-inline](https://github.com/soutaro/rbs-inline)-shaped
comments (`# @rbs name: T`, `#: () -> T`, `# @rbs return: T`, attribute
`#:` casts, `# @rbs!` raw RBS, …) in your Ruby source and feeds the
synthesised RBS into the analysis environment — so a `# @rbs`
annotation Rigor would otherwise ignore becomes an enforced contract
that fires the same `argument-type-mismatch` diagnostics as a
hand-written `.rbs` file. The design is recorded in
[ADR-32](https://github.com/rigortype/rigor/blob/master/docs/adr/32-rbs-inline-comment-ingestion.md).

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
| `plugin.rbs-inline.source-rbs-annotation-not-honoured` | info | an annotation parsed successfully but contributed nothing — the file's other annotations still apply. Today this means the `# @rbs module-self: Foo` spelling; see below |

## Which inline-RBS dialect Rigor reads

There are two implementations of inline RBS: the
[`rbs-inline` gem](https://github.com/soutaro/rbs-inline), which this plugin
runs, and the `RBS::InlineParser` built into `rbs` 4.x. **Rigor reads the
gem's dialect** ([ADR-32](https://github.com/rigortype/rigor/blob/master/docs/adr/32-rbs-inline-comment-ingestion.md) WD11).
They overlap almost entirely — `#:`, `@rbs` method types, `def self.`,
instance-variable annotations, `@rbs skip` all behave identically — but they
are not the same grammar, and one difference bites in practice:

| you write | Rigor honours it |
| --- | --- |
| `# @rbs module-self Comparable` | yes |
| `# @rbs module-self: Comparable` | **no** — this is the spelling in rbs's own `docs/inline.md` |

Rigor reports the second form as
`plugin.rbs-inline.source-rbs-annotation-not-honoured` rather than dropping it
in silence. Constructs the gem supports and the built-in parser does not —
`@rbs generic T`, `@rbs!` embedded RBS blocks, `@rbs inherits`, method
visibility — all work here.

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
  [browser playground](https://github.com/rigortype/rigor/blob/master/docs/adr/29-browser-playground.md), which sets
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
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-rbs-inline/README.md). To write
a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
