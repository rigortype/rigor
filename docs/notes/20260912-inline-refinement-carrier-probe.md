# Inline refinement carriers: what the two inline-RBS readers see

Date: 2026-09-12, at `568138c2`. rbs 4.2.0 and rbs-inline 0.14.0, the versions this repo's bundle
resolves. Grounding for [ADR-111](../adr/111-inline-refinement-carrier.md); the ruling itself is
there, not here.

Status: **measurement note.** Answers the question issue
[#996](https://github.com/rigortype/rigor/issues/996) asks be measured rather than assumed — *what
does a non-Rigor inline-RBS reader do with each candidate spelling of a Rigor refinement in a `.rb`
file?* — for the two readers that exist as libraries: the `rbs-inline` gem (Rigor's reader,
[ADR-32](../adr/32-rbs-inline-comment-ingestion.md) WD11) and rbs's built-in `RBS::InlineParser`
([ADR-94](../adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md)). **Steep is not measured here.**
`tool/steep/` pins Steep 2.0.0 over rbs 4.0.2, was not installed in the worktree this ran in, and
whether Steep surfaces an `RBS::InlineParser` diagnostic to the user — or reads inline `.rb` files
through that parser at all — is the open precondition ADR-111 records.

## Method

Each fixture is one class with one method. Both readers run over the same source:

- gem: `RBS::Inline::Parser.parse(prism, opt_in: false)` → `RBS::Inline::Writer.write` → the RBS
  text Rigor's plugin contributes to the environment.
- built-in: `RBS::InlineParser.parse(buffer, prism)` → `Result#declarations` (member overloads with
  their annotations) + `Result#diagnostics`.

```ruby
require "prism"
require "rbs"
require "rbs/inline"

src = File.read(ARGV[0])
prism = Prism.parse(src)
uses, decls, rbs_decls = RBS::Inline::Parser.parse(prism, opt_in: false)
puts RBS::Inline::Writer.write(uses, decls, rbs_decls)

result = RBS::InlineParser.parse(RBS::Buffer.new(name: Pathname("x.rb"), content: src), prism)
result.declarations.each do |decl|
  decl.members.each do |m|
    puts [m.name, m.overloads.map { |o| [o.method_type.to_s, o.annotations.map(&:string)] }].inspect
  end
end
result.diagnostics.each { |d| puts "#{d.class.name.split('::').last}: #{d.message}" }
```

Run inside the Flake: `nix … develop --command bundle exec ruby probe.rb FIXTURE.rb`.

## Fixtures and results

The plain contract in every fixture is `() -> String` or a one-parameter method; the Rigor payload is
`non-empty-string` / `finite-float` / `Integer[1..10]`.

| # | Spelling (the comment lines above the `def`) | `rbs-inline` gem → RBS text | `RBS::InlineParser` (rbs 4.2.0) |
| --- | --- | --- | --- |
| A | `# @rbs %a{rigor:v1:return: non-empty-string}` then `# @rbs return: String` | `%a{rigor:v1:return: non-empty-string}` on `def name: () -> String` — **the annotation lands** | `() -> String`, annotations `[]`, **`AnnotationSyntaxError: expected a token pARROW`** — the plain return binds, the annotation is lost and reported |
| A2 | `# @rbs %a{rigor:v1:return: non-empty-string} () -> String` (one line) | annotation lands, method type **dropped** → `def name: () -> untyped`, no diagnostic | `() -> String` with overload annotation `["rigor:v1:return: non-empty-string"]`, no diagnostic |
| F | `#: %a{rigor:v1:return: non-empty-string} () -> String` | `SyntaxErrorAssertion` — whole line **dropped silently**, `def name: () -> untyped` | `() -> String` with the overload annotation, no diagnostic |
| Q | `# @rbs %a{…}` then `#: () -> String` | annotation lands on `() -> String` | as A: `pARROW` error, annotation lost |
| P | `# @rbs %a{pure}` then `# @rbs return: String` | as A | as A — the split is a property of own-line `%a{}`, not of the Rigor payload |
| P2 | `#: %a{pure} () -> String` | as F: dropped silently | as F: annotation `["pure"]` |
| B | `# @rbs-ext return: non-empty-string` then `# @rbs return: String` | paragraph read as plain comment (`CommentLines`), no diagnostic; the next `@rbs` line binds | `() -> String`, **`AnnotationSyntaxError: unexpected token for @rbs annotation`** |
| C | `# rigor: return non-empty-string` then `# @rbs return: String` | plain comment, no effect, next line binds | `() -> String`, **no diagnostic** |
| G | `# @rigor return: non-empty-string` then `# @rbs return: String` | plain comment, no effect, next line binds | `() -> String`, no diagnostic |
| D | `# @rbs g: finite-float` | `def probe: (finite g) -> untyped` — the reader stops at `-`, **emits `finite` as a type**, no diagnostic (the `NoTypeFoundError: Could not find finite` of #997) | `(?) -> untyped`, `AnnotationSyntaxError: expected a token pEOF` |
| E | `#: (finite-float) -> String` | `SyntaxErrorAssertion`, dropped silently, `(untyped f) -> untyped` | `(?) -> untyped`, `AnnotationSyntaxError: unexpected token for function parameter name` |
| H | `# @rbs n: Integer[1..10]` | `VarType` with a nil type → `(untyped n)`, no diagnostic | `(?) -> untyped`, `AnnotationSyntaxError: comma delimited type list is expected` |

## Findings

1. **`%a{}` has no spelling both readers accept today.** The own-line form (A, the form
   `docs/manual/16-rbs-extended-annotations.md` documents) is gem-only: the built-in reader reports
   it as a syntax error and drops the annotation, keeping the plain type. The same-line forms (A2,
   F) are built-in-only: the gem keeps the annotation but throws away the method type (A2) or the
   whole line (F), silently. `%a{pure}` (P, P2) splits identically, so this is a gem-vs-built-in
   grammar divergence of the kind `docs/notes/20260730-inline-rbs-parser-grammar-diff.md` catalogued,
   not anything the `rigor:v1:` payload does.
2. **A tag that begins with `@rbs` is inside both readers' nets.** rbs-inline detects an annotation
   comment with `/\A#(\s*)@rbs(\b|!)/` (`annotation_parser.rb`, `annotation_comment?`) and the
   tokenizer scans `@rbs\b`; `\b` matches between `s` and `-`, so `# @rbs-ext` (B) is an `@rbs`
   annotation with an unknown body — swallowed by the gem, diagnosed by the built-in reader. A tag
   that does not begin with `@rbs` (C, G) is invisible to both, and the `@rbs` line beside it binds.
3. **The gem never diagnoses.** Every unparseable `@rbs` paragraph (B, D, H) and every unparseable
   `#:` line (E, F, P2) is dropped without a diagnostic, and D goes further — it emits a truncated
   type. That is the silence #997 is about, and it is the property that makes a refinement name in a
   type position the worst carrier: the reader that matters most says nothing, and the other one
   sees a broken signature.
4. **The naive spellings break every reader** (D, E, H): there is no plain contract left for anyone
   to read.

What this note does not establish: Steep's behaviour on any row (see Status), and whether an rbs
version other than 4.2.0 gives the built-in reader a different grammar — ADR-79 keeps Rigor on the
project's own `rbs`, so the built-in column is version-dependent by construction.
