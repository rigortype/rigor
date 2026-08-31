# haml — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 51 (0 parse errors) |
| expressions | 8525 |
| precision | 57.45% (precise 4898 / opaque 3627) |
| protection | 43.84% (704 protected / 902 unprotected) |
| cause_site_counts | inferred_return_untyped 427, none 257, unsupported_syntax 163, external_gem_without_rbs 30, explicit_untyped 25 |
| tractability | engine_gap 590, add_rbs 55 |

Opaque split: local reads 1198 (def_param 713, block_param 146, assigned_local 339), calls 1438
(receiver already-Dynamic 1011, implicit_self 294, precise-receiver 133), ivar reads 108.

## Headline: `Struct.new(...) do ... end` defeats Struct modeling (D)

haml's parser AST is `Line = Struct.new(:whitespace, :text, :full, :index, :parser, :eod) do … end`
and `ParseNode = Struct.new(:type, :line, :value, :parent, :children) do … end` (parser.rb:207, :223).
Minimal repro (typeof_probe9): `Plain = Struct.new(:a, :b)` folds — `Plain.new(1, 2).a` → 1 (ADR-48)
— but adding a do-block (`Struct.new(:a, :b) do def t; a; end; end`) turns `.new`'s result, every
member accessor, AND the block-defined methods Dynamic. Every compiler pass walks ParseNodes, so
`text` 54, `value` 65, `tabs` 13, `ParseNode.new` 9, `Line.new` 2 all trace here, and the
unsupported_syntax cause bucket (163 sites, 18.1% of unprotected — e.g. attribute_compiler.rb:25
`node.value[:object_ref] != :nil`) is dominated by chains whose Dynamic was introduced at these two
constants. Fix direction: extend the ADR-48 Struct fold to block-carrying `Struct.new` — the members
are identical; the block only adds methods (which the ordinary discovery walk can index as a class
body).

## Case list

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| ParseNode/Line member reads (`text`/`value`/`tabs` on Dynamic receivers + precise-pair ParseNode.new 9, Line.new 2) | ~145 | D | Struct.new-with-block (headline). parser.rb:207/223, ex parser.rb:126 |
| {}#[]= | 12 | G | `hash[key] = …` mirrors Dynamic RHS. attribute_builder.rb:106 |
| Hash[Symbol,Dynamic]#[] / Hash[Dynamic,Dynamic]#[] | 19 | C | options/attribute hashes with Dynamic values. attribute_compiler.rb:25 |
| singleton(Haml::Util)#unescape_interpolation | 11 | D | `def unescape_interpolation(str, escape_html = nil)` (util.rb:205) — optional param disqualifies return inference (param-shape guard, rigor expression_typer.rb:2427) |
| singleton(Haml::Util)#contains_interpolation? | 9 | A | `def contains_interpolation?(str)` — param-sourced body (util.rb:201) |
| Temple/Tilt/Thor surface (`Temple::StaticAnalyzer.static?` 6, `.new` on Temple filters 7, tilt `render`, thor CLI) | 29 | B | external_gem_without_rbs — correctly labeled by the lens; temple/tilt/thor ship no RBS. attribute_compiler.rb:71, filters/tilt_base.rb:8 |
| non-empty-array[Dynamic]#last | 6 | C | refined non-empty array, Dynamic element. parser.rb:370 |
| String?#size / #[] / #include? | 6 | D | optional-receiver refusal on core-RBS String methods (nil branch = bot; join is sound). filters/text_base.rb:10, util.rb:178, parser.rb:175 |
| Haml::Parser::ParserOptions#escape_html | 3 | A | options-object accessor over param-sourced ivars (ADR-58). parser.rb:335 |
| Haml::Engine#call | 2 | B/E | Temple::Engine pipeline (`< Temple::Engine`, DSL-built) — no RBS + framework DSL. cli.rb:91 |
| Haml::Error#line | 2 | D+A | source subclass of StandardError; custom attr — inherited-ancestor + ivar-field. parser.rb:164 |
| implicit-self push/options/register/use/plain | 76 | D/E/A | `push` (script_compiler), `register`/`use` are Temple DSL registration (E); `options` attr_reader over param-sourced ivars (A); several have optional params (D guard). |
| Ripper.lex token chains (`strip` 11, `shift` 17 in attribute_parser.rb) | ~28 | B/C | `Ripper.lex(exp)[1..-2]` token arrays — ripper signatures not loaded; everything downstream unbags Dynamic tuples. attribute_parser.rb:24 |
| dynamic-receiver calls | 1011 | C | propagation ([] 184, == 89, value 65, text 54 …) — mostly ParseNode fields. |
| def/block param reads | 859 | A | ADR-67 (closed). |
| ivar reads | 108 | A | ADR-58. |

## Verdict

One engine fix — Struct.new-with-block folding — would collapse haml's biggest bucket AND most of its
unsupported_syntax cause lane. The recurring D set from liquid/kramdown reappears: param-shape guard
(unescape_interpolation), optional-receiver refusal (String?), inherited-ancestor gap (Haml::Error).
Temple/Tilt/Thor is the first genuine B/E (no-RBS gem + DSL) slice in the family.
