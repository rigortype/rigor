# rigor-rbs-inline

Bundled Rigor plugin that ingests
[rbs-inline](https://github.com/soutaro/rbs-inline)-shaped comments
in Ruby source files and contributes the synthesised RBS to the
analysis environment.

The plugin closes the "the `# @rbs` comment in my `.rb` looks like
it should just work" UX gap: an annotation Rigor previously ignored
becomes an enforced contract that flows through the same
`MethodParameterBinder` + `argument-type-mismatch` pipeline as a
hand-written `.rbs` file.

ADR-32 records the design — including the working decisions this
README references in passing (WD2, WD5, WD6, WD9, WD10).

## What it does

Given a Ruby file carrying the upstream
`# rbs_inline: enabled` magic comment plus rbs-inline annotations:

```rb
# rbs_inline: enabled

class AscDesc
  # @rbs asc_or_desc: :asc | :desc
  def ascdesc(asc_or_desc)
    asc_or_desc
  end
end

AscDesc.new.ascdesc(:bad)
```

Rigor analyses the call site against the synthesised parameter
contract and emits the same diagnostic it would for an equivalent
hand-written `.rbs` file:

```
demo.rb:9:21: error: argument type mismatch at parameter
    'asc_or_desc' of 'ascdesc' on AscDesc: expected :asc | :desc,
    got :bad
```

`# @rbs` parameter annotations, `#: () -> T` method-type comments,
`# @rbs return: T`, attribute `#:` casts, instance-variable
annotations, generics, `# @rbs override`, `# @rbs!` raw RBS
embedding — anything upstream rbs-inline accepts flows through.

## How to enable it

Add the plugin gem to your project and list it in `.rigor.yml`:

```yaml
# .rigor.yml
plugins:
  - rigor-rbs-inline
```

Then, per file, opt-in with the upstream magic comment:

```rb
# rbs_inline: enabled

class MyClass
  # @rbs name: String
  def initialize(name)
    @name = name
  end
end
```

Files without `# rbs_inline: enabled` are unchanged — the plugin
adds zero overhead beyond a top-of-file scan.

## Configuration

| Key | Type | Default | Purpose |
| --- | --- | --- | --- |
| `require_magic_comment` | Boolean | `true` | When `true`, only files carrying `# rbs_inline: enabled` are processed (WD2). When `false`, every file the synthesizer sees is treated as if it carried the magic comment (WD10, host-context override). |

The `require_magic_comment: false` host-context override is the
setting the [ADR-29](../../docs/adr/29-browser-playground.md) browser
playground uses by default so a pasted snippet with `# @rbs`-shaped
comments is analysed without the user typing the magic line:

```yaml
# .rigor.yml
plugins:
  - id: rigor-rbs-inline
    config:
      require_magic_comment: false
```

Setting this in an ordinary multi-file project is unusual — the
magic comment is a deliberate per-file marker that lets you mix
inline-RBS files with plain Ruby files. Flip it off only when you
own the entire analysis scope (single-file ad-hoc CI, a hosted
playground, …).

## Top-level `def` caveat

Upstream rbs-inline documents method annotations on `def` inside
`class` / `module` bodies. A bare top-level `def` produces no RBS
output (verified against rbs-inline 0.14.0):

```rb
# rbs_inline: enabled

# @rbs x: Integer
def f(x)   # ← upstream rbs-inline emits nothing for this
  x
end
```

Wrap the method in a class (or rely on the rbs-inline upstream
adding top-level-def support) when you need the annotation to
take effect:

```rb
# rbs_inline: enabled

class F
  # @rbs x: Integer
  def call(x)
    x
  end
end
```

This is an inherited behaviour, not a Rigor-side limitation. See
ADR-32 WD9 for the design rationale.

## Diagnostics this plugin can produce

| Rule | Severity | When |
| --- | --- | --- |
| `source-rbs-synthesis-failed` | `:info` | rbs-inline couldn't parse a file. The file's analysis falls back to no inline-RBS contribution; the diagnostic carries the upstream error message so you can fix the annotation grammar. |

Severity is `:info` by design — a parse failure does not block
analysis; the file is processed as if it carried no inline-RBS
annotations. Re-stamp via `severity_profile:` in `.rigor.yml` to
escalate.

## Caching

The plugin's synthesised RBS is cached per file. The cache key
composes:

- the source file's content SHA;
- the plugin's id + version;
- the plugin's config hash (so flipping `require_magic_comment:`
  invalidates).

A second `rigor check` against unchanged sources skips the
rbs-inline parse and Writer render. See ADR-32 WD5 + ADR-6 for the
cache backend.

## Dependencies

This plugin gem declares `rbs-inline` as a runtime dependency. The
core `rigortype` analyzer stays zero-runtime-dep per ADR-0 — only
projects that opt into this plugin pay the cost.

## License

[MPL-2.0](../../LICENSE), same as the parent project.
