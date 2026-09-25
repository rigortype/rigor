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
| `plugin.rbs-inline.source-rbs-annotation-not-honoured` | info | an annotation parsed successfully but contributed nothing — the file's other annotations still apply. Six causes: a member your `sig/` also declares (see [Precedence](#precedence)), the `# @rbs module-self: Foo` spelling (see below), a `#:` line whose type does not parse (see [Unparseable `#:` types](#unparseable--types)), a same-line `# @rbs %a{…}` whose method type does not parse (see [Same-line annotations](#same-line-annotations)), a `# @rbs name: T` parameter type that does not parse (see [Unparseable `# @rbs name:` types](#unparseable--rbs-name-types)), and an `@rbs`-prefixed tag the gem does not recognise (see [An unrecognised tag after `@rbs`](#an-unrecognised-tag-after-rbs)) |

## Precedence

When a method is declared **both** in `sig/` and by an inline
annotation, **the `.rbs` wins, per member.** The inline signature for
that one method is dropped; every other annotation in the file still
binds, and the class keeps its method surface.

```ruby
# lib/demo.rb                  # sig/demo.rbs
class Demo                     # class Demo
  # @rbs (Integer) -> String   #   def shared: (String) -> Integer  ← this one wins
  def shared(v) = v.to_s       #   def only_sig: () -> String
                               # end
  # @rbs (Integer) -> Integer
  def only_inline(v) = v + 1   # ← inline-only: still binds
end
```

Each dropped member is reported once as
`plugin.rbs-inline.source-rbs-annotation-not-honoured`, naming the
member and the `.rbs` that won. Delete one of the two declarations to
make the inline annotation take effect.

`rigor sig-gen --write` produces this overlap on purpose: by default it
copies each inline declaration into `sig/`, so the generated signature
is the complete contract a gem ships. The copy is reported like any
other overlap, and `rigor sig-gen --check` fails when an inline
annotation has changed since the copy was written, after which
`--write` brings it back in line. A project whose Steep reads the same
annotations sets `sig_gen.inline_declared: skip` instead
([handbook chapter 11](../../handbook/11-sig-gen.md#methods-declared-inline)).

`sig/` wins because it is the reviewed artefact — the one you diff in
review and the one `rigor sig-gen --diff` reasons about. There is no
upstream rule to defer to: rbs merges an inline `.rb` declaration and a
`.rbs` one into a single class entry and ranks neither, so Steep reports
the same overlap as a signature error and the class still fails to
build. Rigor keeps the reporting and drops the degradation
([ADR-32](../../adr/32-rbs-inline-comment-ingestion.md) WD13) — left to
collide, one duplicated method costs the class every other method, and
each call on it, real methods and typos alike, reads `Dynamic[top]`.

Two overlaps this does **not** cover: a `.rbs` that collides with
*bundled* RBS (Ruby core, stdlib, a gem's signatures) is quarantined
file-by-file instead, reported as `rbs.coverage.quarantined-signature`;
and two `.rbs` files declaring the same member still fail the class's
definition build and surface as `rbs.coverage.definition-build-failed` —
neither side of that pair is more reviewed than the other, so there is
nothing to prefer.

## Which inline-RBS dialect Rigor reads

There are two implementations of inline RBS: the
[`rbs-inline` gem](https://github.com/soutaro/rbs-inline), which this plugin
runs, and the `RBS::InlineParser` built into `rbs` 4.x. **Rigor reads the
gem's dialect** ([ADR-32](../../adr/32-rbs-inline-comment-ingestion.md) WD11).
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

## Same-line annotations

An `%a{…}` annotation can sit on the same line as a method type:

```ruby
class Reader
  # @rbs %a{rigor:v1:return: non-empty-string} () -> String
  def title = "x"

  #: %a{pure} () -> String
  def label = "x"
end
```

This is the spelling the built-in parser and Steep's inline mode accept. The
gem itself does not: it keeps the annotation and drops the method type in the
`@rbs` form, and drops the whole `#:` line. Rigor splits the line back into the
annotation and the method type before the gem's writer runs, so both apply, as
they do when the annotation has a line of its own
([ADR-32](../../adr/32-rbs-inline-comment-ingestion.md) WD11). The gem's own
`rbs-inline --output` is unchanged and still drops them.

When the method type after the annotations does not parse, nothing is split:
the method types as if no signature had been written, and Rigor reports it — a
`#:` line under [Unparseable `#:` types](#unparseable--types), and an `@rbs`
line as `plugin.rbs-inline.source-rbs-annotation-not-honoured` naming the line
and the text it could not read.

## Unparseable `#:` types

A `#:` line whose type does not parse as RBS is dropped — the signature never
applies, and the method types as if the line had never been written, not
merely as if its type were wrong:

```ruby
class BadRefProbe
  #: (finite-float) -> String
  def show(f)
    f.to_s
  end
end
```

`finite-float` is a [Rigor refinement](../16-rbs-extended-annotations.md)
name, not an RBS type, and does not belong in an ordinary type position.
Rigor reports the drop as
`plugin.rbs-inline.source-rbs-annotation-not-honoured`, naming the line and
the text that failed to parse, rather than leaving `show` silently `untyped`
with no diagnostic anywhere. The `# @rbs name: TYPE` tag form of the same
mistake is a different failure shape — see the next section.

## An unresolvable type name in `# @rbs`

Naming a Rigor refinement (or any other unresolvable name) where an RBS type
belongs in the `# @rbs name: TYPE` tag form does not drop silently the way
`#:` does — it takes the whole class down:

```ruby
class ProbeZZ
  # @rbs g: finite-float
  def probe(g)
    g.to_s
  end
end
```

Upstream's own type parser truncates `finite-float` to `finite` (a hyphen
cannot continue an RBS type name) before this ever reaches Rigor, so `finite`
is the only token that reaches `RBS::DefinitionBuilder` — and it names no
loaded type, so the build for the WHOLE class fails
(`RBS::NoTypeFoundError`). `probe`, and every other real method on `ProbeZZ`,
reads `Dynamic[top]`. This surfaces as
`rbs.coverage.definition-build-failed`, naming the token and, when it is the
truncated head of a registered refinement name, the `%a{rigor:v1:…}` spelling
that IS valid today (see
[RBS::Extended annotations](../16-rbs-extended-annotations.md)).

## Unparseable `# @rbs name:` types

A bounded or parameterised refinement — `Integer[1..10]`, `non-empty-array
[Integer]` — does not truncate at a hyphen the way `finite-float` does, so it
does not take the whole class down. In a `# @rbs name: TYPE` position it
leaves the parameter untyped instead, silently:

```ruby
class BoundedProbe
  # @rbs n: Integer[1..10]
  def probe(n)
    n
  end
end
```

The gem's grammar makes the colon-and-type optional on this annotation, so a
`TYPE` it cannot parse leaves the parameter's name recorded and its type
unset rather than raising — indistinguishable downstream from a parameter
nobody annotated at all. Rigor reports the drop as
`plugin.rbs-inline.source-rbs-annotation-not-honoured`, naming the line and
the text that failed to parse, and points at the `%a{rigor:v1:param:}`
spelling that carries a refinement like `Integer[1..10]` correctly (see
[RBS::Extended annotations](../16-rbs-extended-annotations.md)) — the same
advice the `%a{rigor:v1:…}` pointer above gives for the tag form.

## An unrecognised tag after `@rbs`

The gem recognises a comment as an `@rbs` annotation attempt as soon as it
sees the word boundary right after `@rbs` — which matches a hyphen, not only
whitespace or end-of-line:

```ruby
class TagProbe
  # @rbs-ext return: non-empty-string
  # @rbs return: String
  def name
    "x"
  end
end
```

`# @rbs-ext …` is inside that net, but nothing in the gem's grammar
recognises `-ext`, so the gem gives up on the whole paragraph and folds it
back into an ordinary comment — the neighbouring `# @rbs return: String`
line still binds, but the `@rbs-ext` line contributes nothing and, before
this, said nothing either. Rigor reports the drop as
`plugin.rbs-inline.source-rbs-annotation-not-honoured`, naming the line and
the comment text — without implying `@rbs-ext` is a recognised tag of any
kind. A comment that merely mentions `@rbs` in prose, or one that opens with
a tag not starting with `@rbs` (`# @extrbs …`), is outside the gem's
detector and stays silent.

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
