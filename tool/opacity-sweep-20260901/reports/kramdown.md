# kramdown — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 55 (0 parse errors) |
| expressions | 21329 |
| precision | 62.76% (precise 13386 / opaque 7943) |
| protection | 36.51% (1455 protected / 2530 unprotected) |
| cause_site_counts | inferred_return_untyped 1493, none 679, unsupported_syntax 195, explicit_untyped 163 |
| tractability | engine_gap 1688, add_rbs 163 |

Opaque split: local reads 2041 (def_param 895, block_param 395, assigned_local 751), calls 3362
(receiver already-Dynamic 2488, implicit_self 464, precise-receiver 410), ivar reads 514. Join/write
mirroring: IfNode 293, EmbeddedStatementsNode 343, LocalVariableWriteNode 276, And/Or 309.

## The shape of kramdown's opacity

One class dominates: `Kramdown::Element` (element.rb:496) — `initialize(type, value = nil, attr =
nil, options = nil)` plus `attr_accessor :type, :value, :attr, :options, :children`. Every AST walk in
every converter reads these accessors: the dynamic-receiver method top is `children` 165, `options`
125, `type` 121, `value` 117, plus `[]` 479 / `==` 188 / `<<` 162 downstream of them. Receivers ARE
often precisely `Kramdown::Element`; the accessor read answers Dynamic because the ivar field types
are unknown (param-sourced writes in initialize) — ADR-58 ivar-field typing is exactly this hole, and
its optional params also put `Element.new`'s initialize outside return/param binding
(`user_method_param_shape_simple?`, rigor expression_typer.rb:2427). Typing Element's five fields
would cascade through nearly the whole converter layer.

## Case list

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| Kramdown::Element#value / #type / #children / #options / #attr (precise-receiver portion) | 48 + tail | A | attr_accessor over ivars written only from optional init params; ADR-58 territory. element.rb:496, ex converter/hash_ast.rb:24 |
| Hash[Symbol,Dynamic]#[] / Hash[String,Dynamic]#[] / Hash#[] / Hash#[]= | 39+34+17+13 | C | `@options[...]`, attr hashes — Dynamic-valued containers; reads honestly untyped. ex converter/base.rb:104, html.rb:127 |
| Array[Dynamic]#last / #[] | 30 | C | `@stack.last`, children arrays. ex html.rb:208 |
| Proc#call | 19 | C/E | syntax-highlighter / math-engine registry: `Converter.syntax_highlighter(...)` returns a stored callable; `.call` untyped. base.rb:197, parser/html.rb:489 |
| singleton(Kramdown::Utils::Entities)#entity | 19 | C | `ENTITY_MAP[point_or_name]` where ENTITY_MAP is `Hash.new { block }` filled imperatively from ENTITY_TABLE (entities.rb:973) — container of Dynamic. Control: post-hoc `module_function :entity` dispatch itself WORKS (typeof_probe8 folds to a constant), so this is not a module_function gap. |
| Kramdown::Utils::StringScanner?#scan / #[] / #check / #current_line_number | 22 | D | two stacked mechanisms: (1) source class `< ::StringScanner` — inherited RBS-stdlib methods unresolved through a source-defined subclass (same repro'd mechanism as liquid's `MyError < StandardError; .message` → Dynamic; strscan IS in DEFAULT_LIBRARIES, so not B); (2) optional receiver `T?` refused outright. string_scanner.rb:17, ex parser/kramdown/list.rb:68. Fix: MRO into RBS ancestors + `T?` dispatch as join over T/NilClass. |
| Kramdown::Utils::StringScanner#scan (non-optional) | 4 | D | isolates mechanism (1) above: precise non-optional receiver, inherited strscan method, still Dynamic. parser/html.rb:302 |
| Kramdown::Element?#value | 5 | D+A | optional-receiver refusal stacked on the ivar-field hole. parser/kramdown/list.rb:91 |
| String?#length | 3 | D | pure optional-receiver case — `String#length -> Integer` is core RBS; nil branch is bot. parser/kramdown/list.rb:38 |
| singleton(Kramdown::Options)#merge | 3 | A | body folds over the option-definition registry; param-sourced hash. converter/base.rb:102 |
| implicit-self add_text | 36 | D | `def add_text(text, tree = @tree, type = @text_type)` (parser/base.rb:109) — optional params disqualify return inference (param-shape guard), and the defaults read ivars (ADR-58). |
| implicit-self warning | 34 | A | `def warning(text); @warnings << text; end` — ivar-sourced. parser/base.rb:90 |
| implicit-self macro/define_parser/define | 94 | D | converter/parser registration + LaTeX `macro` helpers with optional/block params — param-shape guard again. ex parser/kramdown.rb (define_parser), options.rb (define with &block) |
| dynamic-receiver calls | 2488 | C | propagation ([] 479, == 188, children 165, << 162 …) — overwhelmingly downstream of Element accessors and @options hashes. |
| def/block param reads | 1290 | A | ADR-67 (closed). |
| ivar reads | 514 | A | @stack, @tree, @options … — ADR-58. |

## unsupported_syntax (195 sites, 7.7% — above the 5% bar)

Top: `>` 16 (html.rb:155 `attr['id'].to_s.length > 0`), `size` 16 (converter/kramdown.rb:153
`el.children.size`), `call` 11 (base.rb:197 registry callables), `chomp!` 4, `hex`/`method`/`start_re`
2 each (parser registry Struct handles, parser/kramdown.rb:148-149). These are propagation chains
whose Dynamic was INTRODUCED at registry/metaprogramming constructs: `Struct.new(:name, ...) do` value
classes, `Hash.new { |h,k| ... }` default-proc hashes, `method(:parse_x)` handles stored in `@parsers`
— not independently unmodeled expressions at the flagged sites.

## explicit_untyped (163 sites — the add_rbs lane)

`to_s` 26, `sub!` 13, `inspect` 4 … — authored `untyped` in loaded RBS signatures (e.g.
`Object#to_s`-adjacent overloads and bang-method returns on untyped-receiver chains). This is the
only tractable-by-RBS lane the lens reports for kramdown; everything else routes to the engine.

## Verdict

kramdown is the ivar-field-typing (ADR-58) poster child: one 5-field value class's accessors plus
`@options` hashes explain the bulk of the 2488 dynamic-receiver propagation sites. The repeating D
mechanisms from liquid recur: the param-shape guard (add_text, define_parser, Element#initialize) and
inherited-RBS-ancestor resolution (StringScanner subclass), plus optional-receiver refusal.
