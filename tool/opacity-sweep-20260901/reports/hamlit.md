# hamlit — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 61 (0 parse errors) |
| expressions | 10000 |
| precision | 54.67% (precise 5467 / opaque 4533) |
| protection | 31.91% (589 protected / 1257 unprotected) |
| cause_site_counts | inferred_return_untyped 688, none 341, unsupported_syntax 199, external_gem_without_rbs 24, explicit_untyped 5 |
| tractability | engine_gap 887, add_rbs 29 |

Opaque split: local reads 1488 (def_param 891, block_param 204, assigned_local 393), calls 1846
(receiver already-Dynamic 1236, implicit_self 434, precise-receiver 176), ivar reads 147.

## Structure

hamlit is haml's twin (vendored haml-5 parser under `Hamlit::HamlParser` + a Temple compiler), and
its attribution replicates haml's mechanisms nearly 1:1 — same Struct.new-with-block ParseNode/Line
(haml_parser.rb:111/116; dynamic-receiver `value` 75, `text` 55), same Ripper.lex token chains
(attribute_parser.rb:18; `strip` 12), same Temple/Tilt boundary (external_gem_without_rbs 24:
`Temple::StaticAnalyzer.static?` 6, tilt render/registered?, rails `register_template_handler`).

## Case list

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| singleton(Hamlit::HamlError)#message | 26 | D | `def self.message(key, *args)` (haml_error.rb:40) — the REST param disqualifies return inference (param-shape guard, rigor expression_typer.rb:2427), though the body (`MESSAGES[key] % args`.rstrip) would infer String. Top pair of the whole target. ex haml_helpers.rb:510 |
| ParseNode/Line Struct.new-with-block members (`value` 75, `text` 55 dyn-receiver; ParseNode.new 9, Line.new 2 precise pairs) | ~140 | D | same repro'd mechanism as haml (typeof_probe9): do-block Struct.new loses fold, accessors and .new go Dynamic. haml_parser.rb:111/116 |
| {}#[]= | 13 | G | mirrors Dynamic RHS. attribute_builder.rb:114 |
| singleton(Hamlit::HamlUtil)#html_safe | 10 | B/E | wraps ActiveSupport `String#html_safe` (rails monkey-patch surface, no RBS loaded). xss_mods.rb:27 |
| Hamlit::HamlError#backtrace | 5 | D | inherited RBS-core method (Exception#backtrace) unresolved through source subclass (`HamlError < StandardError`, haml_error.rb:5) — same mechanism as liquid's Error#message repro. haml_helpers.rb:29 |
| MatchData?#[] | 5 | D | optional-receiver refusal on core MatchData#[]. haml_buffer.rb:170 |
| singleton(Hamlit::HamlAttributeBuilder)#merge_attributes! | 5 | A | 2 required positionals; returns the `to` param — param-sourced. haml_attribute_builder.rb:80 |
| singleton(Hamlit::HamlUtil)#unescape_interpolation / contains_interpolation? | 10 | D/A | optional param (D, guard) / param-sourced (A) — identical to haml's Util pair. filters/escaped.rb:14-15 |
| singleton(Hamlit::HamlOptions)#defaults / #buffer_defaults | 5 | A | class-level ivar/hash constants of Dynamic values (class-ivar closed thread). parser.rb:27 |
| Hash[Dynamic,Dynamic]#[] / Hash[:new\|:old,…]#[] | 11 | C | attr hashes with Dynamic values. attribute_builder.rb:25 |
| non-empty-array[Dynamic]#last | 6 | C | Dynamic elements. haml_parser.rb:349 |
| String?#size | 2 | D | optional-receiver refusal. filters/text_base.rb:10 |
| implicit-self haml_buffer/options/push/capture_haml/plain | ~100 | A/E | buffer/options accessors over param-sourced ivars (A) + Temple registration DSL `use`/`register`/`filter` (E). |
| dynamic-receiver calls | 1236 | C | propagation ([] 211, == 101, value 75, text 55 …). |
| def/block param reads | 1095 | A | ADR-67 (closed). |
| ivar reads | 147 | A | ADR-58. |

## unsupported_syntax (199 sites, 15.8%)

Same composition as haml: `!` 32 / `+` 21 / `-` 12 in compiler passes walking Struct-with-block
ParseNodes (children_compiler.rb:72), `strip` 12 / `lex` 2 in Ripper token chains
(attribute_parser.rb:18-31), `options` 8 through the vendored xss/helpers module chain. Introductions
are the Struct.new-do-block and Ripper surfaces, not the flagged expressions themselves.

## Verdict

Adds the strongest single instance of the param-shape guard in the family (`HamlError.message(key,
*args)`, 26 sites — a String return lost to a `*args`), plus repeats: Struct.new-with-block,
inherited-RBS-ancestor (backtrace), optional-receiver refusal (MatchData?/String?), Temple/Tilt B/E
boundary.
