# Inline refinement carriers: what the three inline-RBS readers see

Date: 2026-09-12, at `568138c2`; the Steep column and rows X, Y and the controls added the same day
at `ea5b0137`. rbs 4.2.0 and rbs-inline 0.14.0, the versions this repo's bundle resolves; Steep
2.0.0 over rbs 4.0.2, the pin in `tool/steep/`. Grounding for
[ADR-111](../adr/111-inline-refinement-carrier.md); the ruling itself is there, not here.

Status: **measurement note.** Answers the question issue
[#996](https://github.com/rigortype/rigor/issues/996) asks be measured rather than assumed — *what
does a non-Rigor inline-RBS reader do with each candidate spelling of a Rigor refinement in a `.rb`
file?* — for the three readers a project can run today: the `rbs-inline` gem (Rigor's reader,
[ADR-32](../adr/32-rbs-inline-comment-ingestion.md) WD11), rbs's built-in `RBS::InlineParser`
([ADR-94](../adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md)), and Steep in its inline mode.
The first version of this note had no Steep column — `tool/steep/` was not installed where it ran —
and ADR-111 recorded that gap as its open precondition. The column exists now; finding 5 is what it
says.

## Method

Each fixture is one class with one method. The two library readers run over the same source:

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

Steep runs over the same fixtures laid out as a throwaway project, one file per row under `lib/`,
with `tool/steep/`'s bundle (`make steep-install`; a bundle cloned from another Ruby store path
needs `bundle pristine` under that Gemfile first, because the native extensions were built against
the other path):

```ruby
# Steepfile
target :lib do
  check "lib", inline: true
end
```

`BUNDLE_GEMFILE=<repo>/tool/steep/Gemfile bundle exec steep check`, from the project directory,
inside the Flake. A second Steepfile without `inline: true` (`signature "sig"` over an empty `sig/`,
then `check "lib"`) is the scope control.

**A clean Steep cell is not absence of signal.** Three binding controls are the same fixtures with
the method body changed from `"x"` to `1` under a `String` return — `# @rbs %a{rigor:v1:return:
non-empty-string} () -> String` (A2), `#: %a{rigor:v1:return: non-empty-string} () -> String` (F),
and `# @extrbs return: non-empty-string` over `#: () -> String` (X). Each reports
`Cannot allow method body have type ::Integer because declared as type ::String`
(`Ruby::MethodBodyTypeMismatch`), so in every row marked *clean, binds* Steep read the plain
signature and ignored the annotation beside it. A plain `# @rbs g: Float` / `# @rbs return: String`
pair is clean too, as the harness control.

## Fixtures and results

The plain contract in every fixture is `() -> String` or a one-parameter method; the Rigor payload is
`non-empty-string` / `finite-float` / `Integer[1..10]`. A Steep cell in **bold** is an `[error]`
under Diagnostic ID `RBS::InlineDiagnostic`, on the annotation line, and `steep check` exits
non-zero on it.

| # | Spelling (the comment lines above the `def`) | `rbs-inline` gem → RBS text | `RBS::InlineParser` (rbs 4.2.0) | Steep 2.0.0, `inline: true` |
| --- | --- | --- | --- | --- |
| A | `# @rbs %a{rigor:v1:return: non-empty-string}` then `# @rbs return: String` | `%a{rigor:v1:return: non-empty-string}` on `def name: () -> String` — **the annotation lands** | `() -> String`, annotations `[]`, **`AnnotationSyntaxError: expected a token pARROW`** — the plain return binds, the annotation is lost and reported | **`Syntax error: expected a token pARROW`** |
| A2 | `# @rbs %a{rigor:v1:return: non-empty-string} () -> String` (one line) | annotation lands, method type **dropped** → `def name: () -> untyped`, no diagnostic | `() -> String` with overload annotation `["rigor:v1:return: non-empty-string"]`, no diagnostic | clean, binds (control) |
| F | `#: %a{rigor:v1:return: non-empty-string} () -> String` | `SyntaxErrorAssertion` — whole line **dropped silently**, `def name: () -> untyped` | `() -> String` with the overload annotation, no diagnostic | clean, binds (control) |
| Q | `# @rbs %a{…}` then `#: () -> String` | annotation lands on `() -> String` | as A: `pARROW` error, annotation lost | **as A** |
| P | `# @rbs %a{pure}` then `# @rbs return: String` | as A | as A — the split is a property of own-line `%a{}`, not of the Rigor payload | **as A** |
| P2 | `#: %a{pure} () -> String` | as F: dropped silently | as F: annotation `["pure"]` | clean |
| B | `# @rbs-ext return: non-empty-string` then `# @rbs return: String` | paragraph read as plain comment (`CommentLines`), no diagnostic; the next `@rbs` line binds | `() -> String`, **`AnnotationSyntaxError: unexpected token for @rbs annotation`** | **`Syntax error: unexpected token for @rbs annotation`** |
| X | `# @extrbs return: non-empty-string` then `# @rbs return: String` (or `#: () -> String`) | plain comment; **copied through into the generated RBS as comment text** above `def name: () -> String`; the next line binds | `() -> String`, no diagnostic | clean, binds (control) |
| Y | `#: () -> String` then `# @extrbs return: non-empty-string` — the tag *after* the type line | binds `() -> String`, but the writer re-renders the comment block: `# : () -> String` / `#  @extrbs …` | `() -> String`, no diagnostic | clean |
| C | `# rigor: return non-empty-string` then `# @rbs return: String` | plain comment, no effect, next line binds | `() -> String`, **no diagnostic** | clean |
| G | `# @rigor return: non-empty-string` then `# @rbs return: String` | plain comment, no effect, next line binds | `() -> String`, no diagnostic | clean |
| D | `# @rbs g: finite-float` | `def probe: (finite g) -> untyped` — the reader stops at `-`, **emits `finite` as a type**, no diagnostic (the `NoTypeFoundError: Could not find finite` of #997) | `(?) -> untyped`, `AnnotationSyntaxError: expected a token pEOF` | **`Syntax error: expected a token pEOF`** |
| E | `#: (finite-float) -> String` | `SyntaxErrorAssertion`, dropped silently, `(untyped f) -> untyped` | `(?) -> untyped`, `AnnotationSyntaxError: unexpected token for function parameter name` | **`Syntax error: unexpected token for function parameter name`** |
| H | `# @rbs n: Integer[1..10]` | `VarType` with a nil type → `(untyped n)`, no diagnostic | `(?) -> untyped`, `AnnotationSyntaxError: comma delimited type list is expected` | **`Syntax error: comma delimited type list is expected`** |

Without `inline: true`, every fixture class is `Ruby::UnknownConstant` (`Cannot find the
declaration of class`) and no annotation is read at all — good or bad.

## Findings

1. **`%a{}` has no spelling both library readers accept today.** The own-line form (A, the form
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
   that does not begin with `@rbs` (C, G, X) is invisible to both, and the `@rbs` line beside it binds.
3. **The gem never diagnoses.** Every unparseable `@rbs` paragraph (B, D, H) and every unparseable
   `#:` line (E, F, P2) is dropped without a diagnostic, and D goes further — it emits a truncated
   type. That is the silence #997 is about, and it is the property that makes a refinement name in a
   type position the worst carrier: the reader that matters most says nothing, and the other one
   sees a broken signature.
4. **The naive spellings break every reader** (D, E, H): there is no plain contract left for anyone
   to read.
5. **Steep's inline mode is the built-in reader, surfaced as errors.** Every Steep cell repeats the
   built-in column's diagnostic token for token, at `[error]` severity under `RBS::InlineDiagnostic`,
   and `steep check` fails on it. So under Steep the own-line `%a{}` form (A, Q, P) is not lost, it
   is **red** — including `%a{pure}`, rbs core's own annotation — and the same-line forms (A2, F, P2)
   are clean *and bound*: the body-type controls show Steep reading the plain signature and ignoring
   the annotation, which is the "preserves or ignores" behaviour manual 16 claims of every other RBS
   tool. That claim is therefore true of the same-line form under every reader but Rigor's own, and
   false of the own-line form under two readers out of three. The scope is exactly `inline: true`:
   without it Steep reads no `.rb` annotation, so the population exposed is the one that opted into
   Steep's inline mode — the same population that would write these lines. The design note's
   "Steep tolerates unknown annotations" (`docs/design/20260816-effect-labels.md` § 6.5) is refuted
   for the own-line form it was written about, and holds for the same-line form.
6. **`@extrbs` is a tag name that works where `@rbs-ext` does not.** The maintainer's
   counter-proposal does not begin with `@rbs`, so it is outside finding 2's net: all three readers
   treat it as an ordinary comment, and the `@rbs` / `#:` beside it binds (X, and Steep's binding
   control). Two details are worth keeping rather than flattening. First, the gem copies the line
   into the generated RBS **as comment text** — so at the rbs-inline writer boundary the text
   survives but the meaning does not; in `.rbs` the carrier would still have to be `%a{}`. Second,
   placement: after a `#:` line (Y) the gem re-renders the comment block (`# : () -> String`, then
   `#  @extrbs …`) though the signature still binds; before the annotation block is the safe
   position. Rigor itself parses none of this today — X and Y measure only that the neighbouring
   plain line reaches the environment untouched.

What this note does not establish: whether a Steep other than 2.0.0, or an rbs other than 4.0.2 /
4.2.0, gives the built-in grammar a different shape — ADR-79 keeps Rigor on the project's own `rbs`,
so the built-in and Steep columns are version-dependent by construction; and anything about the
class-level directives (`conforms-to`, the HKT pair) inline, which no fixture carries.
