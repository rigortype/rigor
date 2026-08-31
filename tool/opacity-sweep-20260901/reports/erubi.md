# erubi — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 3 (no .rigor config; explicit `lib` arg) |
| expressions | 866 |
| precision | 47.23% (precise 409 / opaque 457) |
| protection | 27.66% (39 protected / 102 unprotected) |
| cause_site_counts | inferred_return_untyped 61, none 27, unsupported_syntax 14 |
| tractability | engine_gap 75, add_rbs 0 |

Opaque split: local reads 153 (def_param 70, block_param 28, assigned_local 55), calls 148 (receiver
already-Dynamic 96, implicit_self 33, precise-receiver 19), ivar reads 27.

## Case list (small target, all pairs classified)

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| non-empty-string#>= / #> (`RUBY_VERSION >= '1.9'`) | 7 | D | methods reached through an RBS `include` on a core class do not resolve: repro (typeof_probe10) `RUBY_VERSION.length` → positive-int but `RUBY_VERSION >= "1.9"` → Dynamic — `String#>=` exists only via `include Comparable` in core RBS; literal `"abc" >= "b"` folds by VALUE, masking the dispatch gap. erubi.rb:7. Fix: resolve RBS-module-included methods (Comparable, Enumerable) during dispatch. This single gap cascades: `MATCH_METHOD` (:15), `SKIP_DEFINED_FOR_INSTANCE_VARIABLE` (:16), `FREEZE_TEMPLATE_LITERALS` (:17) all guard on RUBY_VERSION comparisons and go Dynamic. |
| /regex/#send(MATCH_METHOD, s) | 3 | D/E | reflection `send` with a constant Symbol — unfoldable today because MATCH_METHOD is itself Dynamic (downstream of the Comparable gap); with a folded :match?, folding `send(:sym, ...)` to the named method would be a small dispatch extension. erubi.rb:153, capture_block.rb:87 |
| Hash#fetch / #[]= (bare Hash) | 5 | C | `properties.fetch(...)` — the `properties = {}` optional param is Dynamic. capture_end.rb:21 |
| Object#escapeHTML | 1 | F/E | JRuby workaround reassigns the constant: `CGI = Object.new; CGI.extend(...)` (erubi.rb:27) — the constant legitimately types Object; runtime environment probing is statically unknowable. erubi.rb:33 |
| MatchData?#begin / #end | 2 | D | optional-receiver refusal on `Regexp.last_match` results. erubi.rb:136/138 |
| singleton(Erubi)#h | 1 | F/E | `h` is defined three different ways behind require-rescue chains (`define_method(:h, ERB::Escape.instance_method(:html_escape))` / CGI / gsub table) — conditional method definition. erubi.rb:20-40 |
| implicit-self add_text / with_buffer / terminate_expression | 20 | A | bodies append to `@src` (ivar sourced from `Engine#initialize(input, properties = {})` — whose optional params ALSO put initialize outside the param-shape guard). ADR-58/67. |
| dynamic-receiver calls (`<<` 38 on @src, `[]` 23 on input slices) | 96 | C | propagation from `@src`/`input`/`properties`. |
| def/block param reads | 98 | A | ADR-67 (closed). |
| ivar reads | 27 | A | ADR-58 (@src, @bufvar…). |

## Verdict

Half of erubi's file-top constant layer collapses from ONE dispatch gap (Comparable-via-RBS-include on
String), which then poisons MATCH_METHOD/send chains. The rest is the family's usual A/C mass plus
deliberate runtime feature-probing (`CGI = Object.new`, triple `h` definitions) that no static reading
should chase — erubi is a worst-case-friendly target and 47% precision is close to its static ceiling
without ADR-67/58.
