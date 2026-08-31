# liquid — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 63 (0 parse errors) |
| expressions | 10701 |
| precision | 54.81% (precise 5865 / opaque 4836) |
| protection | 42.06% (866 protected / 1193 unprotected) |
| cause_site_counts | none 376, inferred_return_untyped 641, unsupported_syntax 166, explicit_untyped 10 |
| tractability | engine_gap 807, add_rbs 10 |

Opaque split: local reads 1818 (def_param 1109, block_param 202, assigned_local 507), calls 1667
(receiver already-Dynamic 1098, implicit_self 339, precise-receiver 230), ivar reads 236; the rest is
join/write mirroring (IfNode 180, LocalVariableWriteNode 240, EmbeddedStatementsNode 79, And/Or 93,
Parentheses 48).

## Headline engine finding (D, dominant)

`ExpressionTyper#user_method_param_shape_simple?` (rigor lib/rigor/inference/expression_typer.rb:2427)
disqualifies ANY method with an optional, rest, keyword, keyword-rest, or block parameter from
return-body inference — the caller always observes `Dynamic[top]`. Verified by matrix repro
(scratch typeof_probe5/6): `def with_opt(name, vars = {})` returning `"x-#{name}"` answers Dynamic on
every call arity, while the identical body under `def no_opt(name)` answers literal-string; kwargs,
`*rest`, `**kw`, and `&blk` all disqualify too. In liquid this covers `Expression.parse(markup, ss =
StringScanner.new(""), cache = nil)` (expression.rb:35), `Condition.parse_expression(..., safe: false)`
(condition.rb:51), `I18n#translate(name, vars = {})`, `Error#to_s(with_prefix = true)`, and a large
share of the 641 inferred_return_untyped sites. Fix direction: bind optionals to
`declared-default-type | call-site arg`, bind unpassed kwargs to their default's type, and give rest
params `Array[join(args)]` — the guard is a first-iteration restriction, not a soundness constraint.

## Case list (top pairs + aggregate buckets)

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| singleton(Liquid::Environment)#default | 16 | A(closed) | `@default \|\|= new` — singleton-class ivar memoization; cross-file class_ivars thread (closed). environment.rb:55, ex context.rb:21 |
| singleton(Liquid::Utils)#to_number | 12 | A | param-sourced case/when on `obj`; else-branch `obj.to_number` joins Dynamic into the return. utils.rb:51, ex standardfilters.rb:810 |
| singleton(Liquid::Utils)#to_liquid_value | 11 | A | returns the param (`obj` / `obj.to_liquid_value`). utils.rb:88, ex condition.rb:75 |
| {}#[]= | 9 | G | `offsets[@name] = from + segment.length` — []= mirrors its Dynamic RHS. for.rb:145 |
| Liquid::Error#message | 9 | D | inherited RBS-core method unresolved through a source-defined subclass: repro `class MyError < StandardError; MyError.new.message` → Dynamic while control `Integer('10')` folds to 10. Exception#message → String is in core RBS; ancestor resolution stops at the source class. ex condition.rb:194. Fix: continue MRO into RBS-declared ancestors for source classes. |
| singleton(Liquid::Utils)#to_integer | 7 | A | param-sourced: `return num if num.is_a?(Integer)` else `Integer(num.to_s)` where num is Dynamic; Kernel#Integer folds only constant args. utils.rb:41 |
| singleton(Liquid::Deprecations)#warn | 7 | D(unresolved) | 2 required positionals, body returns `nil \| Warning.warn(...)`; the SAME class single-file repro answers nil (typeof_probe3) but the corpus run answers Dynamic — a cross-file-environment-only failure (suspect: constant resolution of `::Warning` under `module Liquid` nesting, or the singleton `attr_accessor :warned` in the project discovery index). deprecations.rb:12, ex parser_switching.rb:55. Needs a project-env bisect. |
| Array#[] / Array[Dynamic]#last/#[] | 14 | C | bare/`Dynamic`-element arrays; element reads are honestly untyped. ex lexer.rb:114, block_body.rb:178 |
| Proc#call | 6 | C | value pulled from a Dynamic container narrowed by `is_a?(Proc)` — bare `Proc#call` is `(*untyped) -> untyped` in core RBS. context.rb:224 |
| singleton(Liquid::Expression)#parse | 6 | D | param-shape guard: optional params `ss = StringScanner.new("")`, `cache = nil` disqualify return inference (headline finding). expression.rb:35 |
| Liquid::StandardFilters::InputIterator#sort | 4 | D | methods from an included generic module unresolved: repro `class Iter; include Enumerable; def each; yield 1; end; end; Iter.new.sort` → Dynamic (typeof_probe_liquid.rb:20). Fix: resolve module-included methods, binding Enumerable's Elem from the class's `each` yield type (or `untyped` when unbound — still better shaped than Dynamic). standardfilters.rb:1049, ex :397 |
| Liquid::Registers#static | 4 | A | attr_reader over param-sourced `@static` (ADR-58/67 territory). registers.rb:5 |
| Hash[Dynamic,Dynamic]?#key? | 3 | D | optional-receiver dispatch: `@attributes` typed `Hash[..]?`; `.key?` answers Dynamic though the nil branch can only raise (bot) — join(bool, bot) = bool is sound. table_row.rb:85. Fix: dispatch `T?#m` as join over T and NilClass branches, bot for the branch lacking the selector. |
| i18n `t` (33 sites, unsupported_syntax) | 33 | D/F | `alias_method :t, :translate` is unmodeled: repro shows `Al.new.t` Dynamic while `Al.new.translate` folds (typeof_probe7.rb). The `alias` KEYWORD works (typeof_probe4). Fix: treat `alias_method` sends with two symbol literals as the alias keyword. i18n.rb:20 |
| dynamic-receiver calls | 1098 | C | propagation: `[]` 118, `[]=` 57, `==` 50, `<<` 30, `evaluate` 29 … on already-Dynamic receivers. |
| def/block param reads | 1311 | A | ADR-67 (closed; `parameter_inference: false` in this run's config default). |
| ivar reads | 236 | A/ADR-58 | `@attributes`, `@name`, etc. — param-sourced ivar fields. |

## unsupported_syntax (166 sites, 13.9% of unprotected — above the 5% bar)

Named constructs from the top three unsupported-origin methods (74/166): `t` 33 = `alias_method`
(named above, repro'd); `-` 21 and `freeze` 20 trace through StringScanner-driven scanning code
(`ss.pos - 1`, expression.rb:111; `token.length - 3`, block_body.rb:252) and `@body.freeze` after
`while parse_body(@body, tokens); end` (block.rb:13-16) — the empty-body `while` loop and
`StringScanner` accessor chain are the introduction sites; each mirrors an upstream Dynamic rather
than being independently unmodeled.

## Verdict

Dominant repeatable engine mechanisms: (1) the required-positionals-only guard on user-method return
inference, (2) unresolved inheritance into RBS-core ancestors from source-defined classes, (3)
unresolved include-module (Enumerable) methods, (4) optional-receiver (`T?`) dispatch refusal, (5)
`alias_method` unmodeled. Param-sourced (A) and container-propagation (C) account for most raw volume.
