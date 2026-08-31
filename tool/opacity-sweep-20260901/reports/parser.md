# parser — opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/parser (NO .rigor config; explicit path `lib`)

## Numbers

| metric | value |
| --- | --- |
| files | 56 (0 parse errors) |
| expressions | 12,831 |
| precision | 51.69% (constant 4009, nominal 2089, shaped 430, refined 7, bot 97; opaque 6199) |
| protection | 29.18% (640/2193; lower_bound_typed 52) |
| cause_site_counts | inferred_return_untyped 832 (53.6%), none 588 (37.9%), unsupported_syntax 117 (7.5%), explicit_untyped 16 |
| tractability | engine_gap 949, add_rbs 16 |

Opaque split: local reads 2357 (def_param 1734 / block_param 147 / assigned_local 476), calls 2257, ivars 355.
Call receiver tiers: precise 180, dynamic 1516, implicit_self 561. Worst files: source/tree_rewriter/action.rb 35.9%, source/rewriter.rb 37.3%, builders/default.rb 41.0% (4641 exprs).

## Headline mechanism (new, verified): optional/keyword parameters defeat call-site binding

Controls (same-file, scratch):
- `def self.plain(str); str.to_s; end; C2.plain("hi")` → `"hi"` — plain fixed-arity positional binding works, constant-propagating.
- `def self.opt(str, extra = 1); str; end; C4.opt("b")` → Dynamic[top].
- `def self.req(str, bold:); str; end; C4.req("a", bold: true)` → Dynamic[top].
- `def self.kwpass(str, bold: false); str; end; C4.kwpass("c", bold: true)` → Dynamic[top].

One optional positional or any keyword parameter in the signature and the call answers Dynamic even when the body returns the plainly-bound positional arg. Parser is the worst-case client: the builder/diagnostic API is optional-trailing-param-heavy (`call_method(receiver, dot_t, selector_t, lparen_t=nil, args=[], rparen_t=nil)` builders/default.rb:1097; `diagnostic(type, reason, arguments, location, highlights=[])` builders/default.rb:2315). This sits inside ADR-67's parameter-inference territory, but it is a *specific arg-to-param matching bail*, not absence of inference — the plain-positional case already works.
Fix direction: extend the call-site arg binder to walk optional positionals (bind what is present, default types for the rest) and keywords by name; fall back per-parameter, not per-signature.

## Cases

1. **def_param local reads — 1734 sites — A** (plus block_param 147). ADR-67, counted only. parser passes untyped `token` tuples everywhere.
2. **Param-fed tuple helpers `loc`(155 implicit-self)/`value`(53)/`diagnostic`(29) — A/A+D.**
   `def loc(token); token[1] if token && token[0]; end` (builders/default.rb:2310), `def value(token); token[0]; end` (2298) — pure param-sourced. `diagnostic` additionally has `highlights=[]` so even ADR-67 call-site flow will hit the optional-param bail above.
3. **Refined-receiver operator dispatch — 13 sites — D (verified).**
   `non-empty-string#!=` at lib/parser/current.rb:16 (`RUBY_VERSION != current_version`). Control: `RUBY_VERSION != "1.0"` → Dynamic while RUBY_VERSION itself types `non-empty-string`. Dispatch on a Refined type misses operators its base String supports. Fix: dispatch Refined through its underlying nominal when the refinement carries no own methods.
4. **`Parser::Color.green/.yellow` — 4 sites — D.** Plain `def self.green(str, bold: false)` (color.rb:16-24): the kwarg-default binding bail (headline mechanism). Example: lib/parser/lexer/explanation.rb:24.
5. **Singleton class-attr readers — 8+ sites — A-family (ADR-58).** `class << self; attr_accessor :emit_lambda/...` ×9 blocks in builders/default.rb (`self.class.emit_kwargs` at 1100): class-level ivar through a singleton attr_accessor.
6. **HashShape conditionally-populated key — 11 sites — C.** `family[:fusible]` (source/tree_rewriter/action.rb:114): `analyse_hierarchy` returns a shape whose `:fusible` key only appears on some paths; a literal-key read of an absent key answers Dynamic. Fix (if wanted): absent-key literal read could type nil-or-join instead of Dynamic — FP-safe since the runtime read returns nil.
7. **Optional (nilable) receiver — 3+ sites — D (repeat).** `Array[Dynamic[top]]?#any?` lib/parser/static_environment.rb:90 — same nilable-receiver collapse verified on concurrent-ruby.
8. **Containers of Dynamic — C.** `[Dynamic,Dynamic]#max` (max_numparam_stack.rb:34), `Array[Dynamic]#last/pop` (current_arg_stack.rb), `Hash[Dynamic,Dynamic]?#[]=` (gauntlet).
9. **`bot#range` — 3 sites — G.** Receiver typed bot (unreachable branch), calls counted opaque. Metric artifact.
10. **`Proc#call` — 6 sites — C.** gauntlet_parser.rb:37; bare Proc without signature from untyped source.
11. **Ivar reads — 355 — known ADR-58 roadmap.**
12. **F unsupported_syntax — 117 (7.5%).** Named constructs sampled: `alias_method` re-exports (source/comment.rb:21, lexer/explanation.rb:9-10, source/range.rb:87,308), `instance_variable_get`/`send` reflection equality in source/map.rb:143-169. Diffuse; no single grammar construct dominates.
