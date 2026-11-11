# Reflective call spellings in `lib/`: inventory and frequency survey

Date: 2026-11-12, against master `4f227e24d`. Grounding for
[ADR-132](../adr/132-reflective-call-view.md). Line numbers are from that commit and will drift; the symbol
names are the stable anchors.

Three passes produced this note: a site-by-site inventory of `lib/` (sections A–C below), and two
independent design consults that re-read the rows they relied on and ran probes on Ruby 4.0.5. The
consults' corrections are folded into § "Corrections" rather than edited into the rows.

## Frequency survey

All 49 checkouts under `~/repo/ruby/rigor-survey/` (the survey corpus described in
[`docs/agents/measurement.md`](../agents/measurement.md); 72,127 files, none skipped for a parse error, 7,651,449 call nodes, `vendor/` and
`node_modules/` skipped), counted with the Prism walks in § "Survey scripts". To reproduce:
`ruby survey.rb ~/repo/ruby/rigor-survey/*/` and `ruby handles.rb ~/repo/ruby/rigor-survey/*/`.

| spelling | sites | share of calls |
|---|---|---|
| `send` family, all | 9,947 | 0.130% |
| literal name | 6,355 | 0.083% |
| ... naming an ordinary method (the private-call idiom) | 6,095 | |
| ... naming a metaprogramming selector | 260 | 0.003% |
| ... written as a `StringNode` | 6 | |
| ... through `public_send` | 20 | |
| interpolated name | 919 | |
| computed name (anything else, splats included) | 2,673 | |
| `&:sym` | 17,601 | 0.230% |

The 260 metaprogramming sends are `remove_const` 107, `include` 47, `define_method` 27, `alias_method` 19,
`remove_method` 12, `instance_variable_set` 10, `const_set` 9, `undef_method` 9, and 20 more across ten
selectors. `handles.rb` counted literal handle chains over the same checkouts (`r.method(:m)` /
`instance_method(:m)` read by `call`, `yield`, `===`, `[]` or `bind_call`, through any `bind`, `unbind`,
`to_proc` or `curry` wrapper): 92, of which 16 are
`bind_call`; and 25 block-passes of a handle (`&r.method(:m)`).

So the corpus exercises few of the 36 sites, and 36% of sends have no literal name. A byte-identical
corpus diff is weak evidence that a move preserved behaviour, which is why ADR-132 pins a synthetic
spelling matrix, one column per site, before anything moves.

An earlier pass over a 14-checkout subset (22,867 files) gave the same picture: `send` family 0.167%,
metaprogramming sends 0.010%, 45% without a literal name.

## Corrections

- `:"\xff"` does not parse (`invalid symbol`), so the SymbolNode-only sites (rows 4 and 8) cannot raise in
  `to_sym`. The unguarded `to_sym` on a `StringNode` in `CalleeWriteCensus` (row 12) is real by reading;
  one probe did not reach it.
- Prism `Node#copy` has three callers, not two: `StatementEvaluator` also passes a copy to `type_of`
  (statement_evaluator.rb ~2083), which can never hit the identity-keyed memo.
- A line grep finds 39 constants that hold a sender name: 27 `%i[]` and 12 `Set[...]`. A Prism walk finds
  26 constants exactly equal to `{send, __send__, public_send}` (the inventory's 23 missed three), and about
  116 sender-name SymbolNodes in all.
- Thirteen sites drop the selector argument by hand, not eleven (the coverage table lists thirteen rows).
- Only three `public_send` exclusions are deliberate: `ModuleFunctionState::Spellings` and
  `toplevel_include_owner` (the target is private), and `RubyDeprecations::SEND_NAMES` (`ruby2_keywords`
  is private). The `private_class_method` half of `VISIBILITY_SEND_CALLS` is accidental:
  `Module#private_class_method` is public, so `public_send(:private_class_method, :x)` works.
- `#1872` produces a wrong type, not only a lost one: `Integer("1", exception: false)` types `Integer?`,
  while `send(:Integer, "1", exception: false)` types `Integer`.
- `ExpressionTyper#try_literal_send` assumes every `send` is `Kernel#send`. A class that defines its own
  `send(message, flags)` gets a false positive today:
  `Mailer.new.send(:hello, 0).even?` reports `call.undefined-method` for `"0"`, and Ruby prints `false`.
  Only the typer's SymbolNode-only extraction keeps the socket idiom `sock.send("payload", 0)` out of the
  same trap.
- The same assumption gives a wrong type outside the typer. `ReturnBarrier.block_call?` reads
  `send(:lambda) { return nil }` as a lambda barrier on any receiver. In a class whose own `send(_name)`
  yields, `rigor type-of` types the method `Integer` where Ruby returns `nil`. Over-approximating a call is
  not the safe direction for a consumer whose answer narrows a type or emits a diagnostic.
- `&:m` and `&r.method(:m)` differ: for `&:m` the first yielded value is `self` and the rest are arguments;
  for `&r.method(:m)` the receiver is `r` and every yielded value is an argument (Ruby 4.0.5).
- Of the 27 issues the inventory maps, the view closes three outright (#1872, #2167, #2704). About eleven
  lose one item. About twelve are receiver resolution, closure, or eval-semantics problems the view does not
  touch.

## Inventory

Scope: every place under `lib/` that recognises a reflective spelling on a Prism `CallNode` itself. Plugins under
`plugins/` (4 files mention `send`) are out of scope. Line numbers are from the checkout at the time of the survey.
`S` = `send`, `P` = `public_send`, `_` = `__send__`. "lit" = the target name is a literal. Target extraction legend:
**SY** = first arg `SymbolNode` only; **SS** = `SymbolNode`/`StringNode` via `.unescaped`; **SS/str** = same but compared as a
String (so an invalid-encoding literal does not raise on `to_sym`); **SS/sym** = same, converted with `valid_encoding?` guard;
**INT** = also reads interpolated names (only ScopeIndexer's `literal_send_name`).

None of the sites shares an implementation. 36 distinct sites recognise the `send` family (rows 1-36), 2 sites that should
(rows 37-38) do not, and rows 39+ are the non-`send` reflective spellings.

### A. `send` / `public_send` / `__send__` sites

| # | file:line | constant / method | purpose | spellings | name extraction | receiver / args / block | visibility semantics | misses (that a sibling handles) |
|---|---|---|---|---|---|---|---|---|
| 1 | analysis/check_rules/rebinding_block_callees.rb:39,262 | `SEND_CALLS`, `send_target` | check rule `rebinding-block-callees` (does a rebinding block reach a def) | S P _ | SS/sym (`literal_name`, :259-266) | any receiver; name -> table lookup; no arg shift (name only) | none; P treated as S | `&:sym` handled elsewhere in same file (:153,:224 are proc locals, not sym); no interpolation |
| 2 | analysis/check_rules/rebinding_block_callees/dispatch.rb:16,31,60 | `METHOD_OBJECT_CALLS = call yield === [] bind_call`, `method_reader`, `dispatch` | same rule; method-object callee | `m.method(:x).call/.()/[]/yield/===/bind_call`; wrappers `bind unbind to_proc curry`; readers `METHOD_READERS`/`BOUND_METHOD_READERS` | SS/sym on reader arg 0 | strips wrappers by walking `receiver`; `instance_method` chain gives receiver nil | n/a | only site that models `Method`/`UnboundMethod` chains; `bind(x).call` partly (wrapper) |
| 3 | analysis/reachability/scan.rb:603,613,630 | `SENDS`, `record_mixin`, `mixin_arguments` | reachability: mixin ancestry edges | S P _ , target in `include prepend extend` | SS/str (`unescaped`) | arg shift (`args.drop(1)`); any receiver in `mixin_target`; receiverless-only shortcut excludes sends (:613) | none; P allowed (valid: `include` public) | `send(:const_get)`/`send(:class_eval)`; only mixin names |
| 4 | analysis/check_rules/ruby_deprecations.rb:53,110,197 | `SEND_NAMES`, `send_target` | check rule `ruby-deprecations` | S _ only | **SY** `unescaped.to_sym` (:112) | name replaces call name; receiver kept; `via_send` flag passed on | P excluded (private-only targets, matches Ruby) | StringNode name (`send("ruby2_keywords")`), P (intentional) |
| 5 | sig_gen/generator.rb:2735,2746 | `SEND_NAMES`, `attr_writer_names` | sig-gen: writer names from `attr_*` | S P _ ; target `attr_writer attr_accessor` | `Source::Literals.symbol_arg(node,0)` (SS) | self/implicit receiver only; `names.drop(1)` | none | - |
| 6 | inference/last_status.rb:37,94 | `SENDS`, `clears?` | `$?` clear/wait detection | S P _ | SS (`unescaped` string compare) | any receiver; name only | none | non-literal => `false` (others say "unknown" => taint) |
| 7 | inference/census_foreign_block.rb:32,332 | `SEND_CALLS`, `define_method_call?` | ivar census: `define_method` blocks | S P _ ; target `define_method` | SS (`first.unescaped == "define_method"`) | requires `self_node?(receiver)` and literal `BlockNode` | none | `define_singleton_method`; lambda/proc arg (#2169) |
| 8 | inference/return_barrier.rb:22,35 | `SEND_CALLS`, `block_call?` | `return` barrier for blocks (define_method/lambda/proc) | S P _ | **SY** `to_sym` | any receiver; name replaces; no arg handling | none | StringNode |
| 9 | inference/repeated_or_writes.rb:85-88,284-291 | `Forms::DYNAMIC_SEND`, `METHOD_HANDLES`, `dynamic_store?` | repeated `\|\|=` store detection | S P _ (any send is a store); `method`/`public_method` with SY store name | send: unconditional true; handle: **SY** | no shift | none | `instance_method`, StringNode handle, literal-name check for send |
| 10 | inference/global_write_census.rb:63,251-262 | `SEND_CALLS`, `visit_call` | global/constant/alias write census | S P _ (+ `VISITED_CALLS`) | SS/sym (`literal_name`); non-literal => `any_entry` | **arg shift** (`arguments.drop(1)`), "read as the call written directly" | none; `send(:include)` at top level read as mixin | `send(:private)`-style naming |
| 11 | inference/receiver_writer_call.rb:14,45-68 | `ReceiverWriterCall.called`, `literal_name` | ivar census: `E.send(:attr_accessor, :y)`, `E.send(:define_method)` | S P _ | SS/sym (own copy of `literal_name`) | explicit non-self receiver only; shifts args; returns `[name, args]` view | none | the one site that already returns a normalised `[name, args]` pair |
| 12 | inference/callee_write_census.rb:104,114,529,688 | `OPAQUE`, `SENDS`, `opaque_argument_call?`, `literal_send?` (:141) | callee mutation floor (opaque sinks) | S P _ ; also `instance_eval instance_exec instance_variable_set method public_method`, `call instance_exec class_exec module_exec` | `literal_send?` = Symbol or String (no encoding check) | non-literal send => args opaque; literal => treated as a normal call (statement_evaluator resolves callee) | none | send on constant receiver not followed (#2632); StringNode `instance_variable_set` ok |
| 13 | inference/refine_census.rb:46,103,112 | `SEND_CALLS`, `string_literal_call?`, `literal_target` | `refine` text census | S P _ | none (name unused; counts as a string-carrying call) | `:self` vs `:receiver` target | none | - |
| 14 | inference/ivar_writer_census.rb:40,248-290,300 | `SEND_CALLS`, `OPEN_WORLD_SENDS`, `open_world_send?`, `visit_foreign` | ivar census open-world writers | S P _ ; sent name in `instance_variable_set instance_eval instance_exec extend define_singleton_method` | SS/sym | shift for `instance_variable_set`; open-world if non-literal | none | `send(:define_method)` w/ block on self (#2167) |
| 15 | inference/alias_mutation_floor.rb:74,243-254 | `SEND_NAMES`, `literal_send_target` | mutation widening of `a.send(:push, x)` | S P _ , no block | SS/sym | **synthesises a new `CallNode`** via `call_node.copy(name:, arguments: arguments.copy(...))` | none (send crosses private; P identical) | interpolated name (#2704) |
| 16 | inference/alias_mutation_floor/site_collector.rb:17-19 | `KEEPING_CALLS` | alias floor site collection | S P _ listed with `instance_variable_set instance_exec instance_eval class_exec module_exec define_method define_singleton_method` | none | membership only | none | - |
| 17 | inference/last_line.rb:54,70,135,192 | `SENDS`, `patched_readers`, `call_may_set?` | `$_` / line readers | S P _ | SS via `definer_name?`, `sent_reader?` | `arguments[1]` for definer shift | none | - |
| 18 | inference/last_line/self_evidence.rb:62,80,238,270 | `SENDS`, `NAMING_CALLS`, `sent_mixin?`, `sent_rebinder?` | `$_` frame evidence | S P _ (+ `respond_to? method public_method` as NAMING) | SS (`unescaped`); `SplatNode` => true; else arity>1 | `visit_arguments` skips literal arg 0 of NAMING_CALLS | none | - |
| 19 | inference/match_rebinding/calls.rb:37,121,138 | `SENDS`, `sent?`, `named?` | `$~` rebinding | S P _ | SS via `NAMES_BY_STRING[unescaped]`; else computed => "sent a known Regexp" | **recursion**: `named?(name, receiver, rest, ...)` with shifted args | none | - |
| 20 | inference/match_rebinding/self_calls.rb:31,43-70 | `SENDS`, `named_match?`, `sent_name_matches?`, `sends_binding?` | `$~` frame calls | S P _ | SS (`unescaped` string set) | none | none | - |
| 21 | inference/global_writer_reach.rb:149,214 | `Search::SEND_CALLS` (= S P _ `method public_method instance_method`) | global-writer reachability BFS | S P _ + 3 handle-takers; `&:sym` via `scan_block_argument` (:202,:233) | SS/sym (`literal_name`); non-literal => `reached!` | name enqueued; no shift | none | `.call` on the handle |
| 22 | inference/module_function_state/spellings.rb:20-31 | `SEND_CALLS` | `module_function` rows | **S _ only** | `Source::Literals.symbol_or_string` | implicit/self receiver only; `drop(1)` | **P excluded explicitly** (private method raises) | constant receiver (#2246) |
| 23 | inference/synthetic_method_scanner.rb:381,386-397 | `CONCERN_SEND_CALLS`, `concern_extend_arguments` | concern detection | S P _ ; target `extend` | SS (`unescaped == "extend"`) | self/implicit receiver only; `drop(1)` | none | - |
| 24 | effects/unit_scan.rb:62,100,832,866-885 | `REFLECTIVE_SEND`, `DEFERRED_SELECTORS`(= S P _ `call`), `visit_reflective_send`, `literal_selector` | effects: edge per send; `dynamic-send` taint | S P _ ; `call` deferred | SS (string selector); non-literal => `taint("dynamic-send")` | `push_edge(record, selector, node.receiver.nil?, ...)` | none | no shift needed (selector only) |
| 25 | inference/method_dispatcher/constant_folding.rb:248,270 | `REFLECTIVE_SEND_METHODS` | folding: ADR-78 over-fold guard | S P _ (as method names on **types**, not nodes) | `args.first` must be `Type::Constant[Symbol]` | operates on `context.args`, not on a node | none | Constant[String] |
| 26 | inference/expression_typer.rb:2737-2765 | `LITERAL_SEND_SELECTORS`, `try_literal_send` | typing: `x.send(:m, a)` as `x.m(a)` | S _ P | **SY only** | `args[1..]`, rejects splat/forwarding/block; dispatches with the **outer** `call_node: node` (#1872) | send == public_send; documents the optimism | StringNode (siblings accept) |
| 27 | inference/expression_typer.rb:2269-2300 | `REFINED_NAMING_CALLS` (S _ P `respond_to? method public_method`), `literal_method_name_argument`, `symbol_block_argument` | refinements (ADR-121 WD4) | S _ P `respond_to?` `method` `public_method` + `&:sym` | SS `to_sym`; `&:sym` SymbolNode | name only | none | - |
| 28 | inference/statement_evaluator.rb:1058,1105 | `DISPATCHING_CALLS` (S P _ `singleton_class`) | local-forms taint | membership | none | receiver must be local read | none | - |
| 29 | inference/statement_evaluator.rb:606,6739-6742 | `SEND_HAND_OFFS` (S P _), `send_hand_off?`, `opaque_sink_call?` | callee-floor hand-offs | S P _ | `CalleeWriteCensus.literal_send?` (SS) | resolves callee by literal name | none | const receiver (#2632) |
| 30 | inference/guard_rebinding.rb:44,272 | `CODE_RUNNING_NAMES` (S _ P eval require load const_set remove_const ivar_set) | guard rebinding: foreign code | membership; any send => foreign | none | none | none | - |
| 31 | inference/remover_holder_scan.rb:38 | `REFLECTIVE_CALLS` (S P _ `instance_eval instance_exec tap then yield_self itself method define_singleton_method`) | remover holder | membership | none | none | none | - |
| 32 | inference/scope_indexer.rb:5217,5198-5214,5322 | `HOOK_SEND_CALLS` | hook param reshape; singleton definers | S _ P | `send_extend?` = **SY** `== "extend"`; `literal_method_name` (SS) for definer | shifts: `arguments[1]` | none | StringNode for `send("extend")` |
| 33 | inference/scope_indexer.rb:6179,6188-6200 | `DEFINER_SEND_CALLS` | definer-name rows (#2184) | S _ P ; target `define_method define_singleton_method alias_method` | SS via `literal_method_name` | `arguments.drop(1)`; row = range over the name literal | none | - |
| 34 | inference/scope_indexer.rb:8172,8216,8407,8586 | `SEND_CALL_NAMES`, `mixin_call_view`, `computed_send_name`, `toplevel_include_owner` | mixin accumulator | S P _ | SS/str via `MIXIN_KINDS` string compare; `literal_send_name` additionally reads **interpolated** parts (:8384-8392); `local_send_names` resolves `m = :attr_reader; send(m, ...)` | returns `[kind, args, via_send]`; `drop(1)` | **`toplevel_include_owner` excludes P** (main's `include` is private) :8586; others include P | - |
| 35 | inference/scope_indexer.rb:9604,9618,9934,10091 | `VISIBILITY_SEND_CALLS` (S _) | visibility toggles / `private_class_method` | S _ ; **plus P** only in `constant_public_class_method_names` (:9934) | `Source::Literals.symbol_or_string` | self/implicit receiver (constant receiver for `public_class_method`); `drop(1)` | **encodes the Ruby rule**: P excluded for private targets, included for `public_class_method` | P in `class_method_visibility_parts` (`private_class_method` is public) |
| 36 | inference/scope_indexer.rb:10280,4602,7162,10443-10455,10861-10887 | `SURFACE_SEND_CALLS`, `surface_rewriting_call?`, `dynamic_surface_call?`, `attr_macro`, `each_attr_macro_name`, `singleton_naming_call_names`, `record_self_definer_call` | envelope / surface evidence, attr macros | S _ P | SS via `literal_method_name`; `arguments.drop(1)` | mixes: any send is `:all` in `singleton_naming_call_names` | none | - |

#### Sites that SHOULD see `send` and do not

| # | file:line | what | consequence |
|---|---|---|---|
| 37 | inference/define_method_block_self.rb:41-54 | matches only literal `define_method` on lexical self (#2167) | block `self` not narrowed through `send(:define_method)`; the census (row 7) does count it, so they disagree |
| 38 | lens/file_reader.rb:225-262 (`visibility_call?`) and analysis/check_rules/lexical_method_sites.rb:62-175 (`opened_method_name`, EVAL_CALLS) | visibility walk and singleton-opening reader know only direct `private`/`define_singleton_method`/`instance_eval` | `send(:private, :x)` handled by ScopeIndexer (row 35) is invisible to Lens; `x.send(:define_singleton_method, ...)` / `x.send(:extend, M)` invisible to `lexical_method_sites` (#2087, #2984) |

### B. Other reflective spellings

| # | file:line | site | purpose | spellings | extraction | notes / misses |
|---|---|---|---|---|---|---|
| 39 | inference/callee_write_census.rb:693,711 | `note_symbol_block` | callee floor | `&:sym` (SymbolNode) naming a mutator | `unescaped.to_sym` in `@mutators` | marks receiver elements |
| 40 | inference/deep_erasure.rb:148 | `symbol_proc_mutation?` | mutation widening | `&:sym` in `SHAPE_MUTATORS` | `unescaped.to_sym` | no `&method(:x)` |
| 41 | inference/remover_narrowing.rb:157 | `symbol_nil_narrowed` | narrowing | `&:nil?` | `unescaped == "nil?"` | only `nil?` |
| 42 | inference/expression_typer.rb:5105,5728,6636,2299 | `symbol_block_return_type`, `per_element_symbol_results`, `apply_hash_block`, `symbol_block_argument` | typing `&:sym` | `&:sym` | `unescaped.to_sym` | passes the **BlockArgumentNode as `call_node:`** to `MethodDispatcher.dispatch` (:6642) |
| 43 | inference/method_dispatcher/interface_shape.rb:87 ; hash_transform_keys_folding.rb:156 | block-pass classification | dispatch | `&:sym` (never nil), `&nil` | node class tests | - |
| 44 | inference/match_rebinding.rb:207,254 ; last_line.rb:179,217 ; guard_rebinding.rb:116,272 ; block_run_count.rb:70 ; project_yielder.rb:93 ; effects/unit_scan.rb:949 ; effects/local_ownership.rb:122 ; sig_gen/observation_collector.rb:466 ; protection/mutator.rb:98 ; parameter_inference_collector.rb:307 ; check_rules.rb:2449,3031 ; lens/file_reader.rb:495 | `BlockArgumentNode` classification | various | `&:sym` as "safe/known method name", `&local`, `&` forward | `last_line.rb:208` treats `&:gets`/`&:readline` as setters (SETTER_NAMES) | per-site ad hoc; 13+ separate classifications of the same node |
| 45 | inference/method_dispatcher/method_folding.rb:39-60 ; types `BoundMethod` | `x.method(:n)` forward fold, `.call/.curry` backward | typing | `method(:x)`, `.call`, `.curry` | `symbol_name_of(arg)` on **types** | `public_method`/`instance_method` not folded |
| 46 | inference/repeated_or_writes.rb:288 ; callee_write_census.rb:104 ; global_writer_reach.rb:149 ; last_line/self_evidence.rb:76-80 ; remover_holder_scan.rb:38 | `method`/`public_method`/`instance_method`/`singleton_method`/`public_instance_method` handle takers | various | different subsets in each | SY (repeated_or_writes), SS/sym (global_writer_reach), SS (self_evidence) | no site handles `.call/.()/[]/bind_call` on a handle except row 2 and `unit_scan` `opaque_callable?` (:960, `call` only) |
| 47 | inference/scope_indexer.rb:4580,4630,5324-5347,5678,5923,8852,8986,9228,9239,10166,10795 ; effects/unit_scan.rb:145 ; effects/scanner.rb:282 ; inference/refine_census.rb:191 ; refine_self.rb:51 ; error_info.rb:33 ; fresh_frame_blocks.rb:34 ; stored_block_call.rb:22 ; lens/parameters.rb:52 ; scope.rb:647 | `define_method` / `define_singleton_method` matched by name | definers | literal `define_method`; some require implicit/self receiver, some any | SS via `literal_method_name` or `.unescaped` | at least 6 separate `DEFINERS = [define_method define_singleton_method]` constants (error_info, fresh_frame_blocks, stored_block_call, last_line, refine_self, scope_indexer) |
| 48 | source/alias_names.rb:28 ; global_write_census.rb:219 ; refine_census.rb:193 ; scope_indexer.rb:10635 ; effects/ancestry_recorder.rb:113 ; lens/file_reader.rb:235 | `alias_method` | alias tables | receiverless only (alias_names, ancestry_recorder, indexer) | SS | `send(:alias_method)` handled only by scope_indexer rows 33/36 |
| 49 | inference/reflective_ivar_write.rb:35-65 ; callee_write_census.rb:302,690,711 ; ivar_writer_census.rb:258-282 ; sig_gen/generator.rb:2776 | `instance_variable_set` / `instance_variable_get` | ivar flow | receiverless/`self` only (reflective_ivar_write), `send(:instance_variable_set)` explicitly **not** counted (:22) but ivar_writer_census does count it (:278) | `IVAR_NAME` regex (reflective_ivar_write) vs `unescaped.to_sym` w/o regex (callee_write_census) | divergence (see C) |
| 50 | inference/scope_indexer.rb:5195-5214 (HOOK_EVAL_CALLS), 10280 (SURFACE_EVAL_CALLS), inference/last_line.rb:56, match_rebinding/calls.rb:35, self_calls.rb:28-29, refine_census.rb:47, ivar_writer_census.rb:42-46, guard_rebinding.rb:48-52, global_writer_reach.rb:150, check_rules/lexical_method_sites.rb:62, refine_self.rb:52 | `class_eval module_eval class_exec module_exec instance_eval instance_exec eval` | eval-family handling | each file defines its own set; membership differs (e.g. `last_line.EVALS = eval instance_eval class_eval module_eval`, `self_calls.EVALS = eval`, `lexical_method_sites.EVAL_CALLS = instance_eval instance_exec`) | string vs block distinguished ad hoc | 10+ distinct eval-family sets, none equal |
| 51 | analysis/reachability/scan.rb:335-450 ; check_rules.rb:1186 ; dependency_source_inference/walker.rb:243 ; scope_indexer.rb:3793 ; last_line/self_evidence.rb:70 | `const_get` / `const_set` | reachability, constant census | `const_get` on self/receiver with interpolation-aware anchors; `const_set` SS | reachability handles interpolated args; others SS only | `send(:const_get)` / `send(:const_set)` seen by none of these (#2386) |

### C. Summary

#### 1. Union of spellings and per-spelling coverage (N = 36 `send`-family sites, rows 1-36)

| spelling | sites handling it |
|---|---|
| `send` | 36 / 36 |
| `__send__` | 35 / 36 (row 26 lists `__send__`; every site has it: effectively 36) |
| `public_send` | 33 / 36. Excluded deliberately in 4 (22 `ModuleFunctionState`, 4 `RubyDeprecations`, 34's `toplevel_include_owner`, the `class_method_visibility_parts` half of 35); the other exclusions are accidental (`VISIBILITY_SEND_CALLS` for `private_class_method`) |
| target name, SymbolNode | 36 (all that extract a name) |
| target name, StringNode | about 28; SY-only sites: 4, 8, 9 (`method` arm), 26, 32 (`send_extend?`) |
| encoding guard (`valid_encoding?` or String compare) | about 14 (rows 1,3,6,7,10,11,14,15,17-21,23,34); others call `to_sym` directly and can raise on `send("\xff")` (rows 4, 8, 12 `note_ivar_set`, 24) |
| interpolated name | 1 (row 34 `literal_send_name`, plus `local_send_names` local resolution); row 15 documents #2704 |
| arg shift (`drop(1)`) | 11 (3,5,10,11,19,22,23,26,32,33,34,35,36) |
| builds a normalised view `[name, args]` | 4 (11 `ReceiverWriterCall.called`, 34 `mixin_call_view`, 35 `visibility_call_parts`, 2 `Dispatch.dispatch`) |
| `&:sym` | 8+ independent classifications (rows 39-44, 21, 27) |
| `method(:x).call` family | 1 (row 2), `.call` only in unit_scan (:960) |
| `bind_call`/`bind(x).call` | 1 (row 2); `Cache::ValueDigest`/`CheckCommand` use `bind_call` as runtime code, not recognition |
| `instance_variable_set` via send | 1 (row 14) and 12 (opaque only) |
| `instance_exec/eval/class_eval` | 10+ different sets (row 50) |
| `define_method`/`alias_method`/`const_get` through send | rows 7, 11, 33, 36 (define_method); 33, 36 (alias_method); 0 (const_get) |

#### 2. Concrete divergences (same question, different answer for the same spelling)

1. **`send("string_name", ...)`** is a call to the named method for rows 1,3,5,6,7,10,11,14,15,17-24,29,32-36, but not for rows 4 (`RubyDeprecations.send_target`, expression `first.is_a?(Prism::SymbolNode)` at ruby_deprecations.rb:112), 8 (`ReturnBarrier` return_barrier.rb:36 `return false unless sent.is_a?(Prism::SymbolNode)`), 26 (`try_literal_send` expression_typer.rb:2745 `args.first.is_a?(Prism::SymbolNode)`), 9 (`METHOD_HANDLES` arm :291). So `a.send("push", x)` is mutation-widened (alias_mutation_floor.rb:248) and a callee-floor hand-off (callee_write_census.rb:141) but typed as an unknown `send` (not as `a.push`) by the typer.
2. **`public_send` and private targets.** scope_indexer.rb:8586 excludes P for `main.include` (correct); module_function_state/spellings.rb:21 excludes P (correct); expression_typer.rb:2733 says P "is treated identically" (optimistic by design); alias_mutation_floor.rb:76 treats P as S; #2697 asks for private `send(:padd)` to be followed. No site models that P of a private method raises as a typing outcome.
3. **`send(:instance_variable_set, ...)`.** reflective_ivar_write.rb:22 states it "does not count"; ivar_writer_census.rb:278-283 does count it; callee_write_census.rb:104 treats any send as opaque. The three census-like sites disagree on a write.
4. **`send(:define_method) { }`.** CensusForeignBlock (7), ReceiverWriterCall (11), scope_indexer `record_sent_define_method` (4630) count it; `DefineMethodBlockSelf` (37, define_method_block_self.rb:54) and `Scope#block_self` (scope.rb:647, `call_node.name == :define_method`) do not (#2167). The comment on row 7 claims the census counts exactly the blocks whose `self` is narrowed; with row 37 that is false.
5. **`send(:private, ...)`.** scope_indexer.rb:9604-9622 reads it; lens/file_reader.rb:225 (`visibility_call?`) does not; lexical_method_sites.rb does not read `send(:define_singleton_method)`/`send(:extend)` while scope_indexer.rb:5322 does for hooks.
6. **Constant receiver.** `Helper.send(:fill, x)` is a floor hand-off for self/implicit receivers only (#2632, statement_evaluator.rb:6739 + resolve_self_callees); `Es.send(:module_function)` is not read (#2246, spellings.rb:27 requires self/implicit); scope_indexer.rb:9934 reads `K.send(:public_class_method, ...)`; reachability/scan.rb mixin_target reads constant receivers.
7. **Non-literal first argument.** unit_scan (24) => `dynamic-send` taint; global_writer_reach (21) => `reached!`; global_write_census (10) => `any_entry`; ivar_writer_census (14) => open world; last_status (6) => "does not clear" (unsound direction); rebinding_block_callees (1) => `nil` name; ruby_deprecations (4) => nil name => silent.
8. **Interpolation.** Only row 34 reads `"#{...}"` partially (scope_indexer.rb:8384-8392); every other site treats `send("#{m}")` as non-literal; row 15 keeps the false positive (#2704).
9. **Encoding.** `send("\xFF")` raises `ArgumentError` in `to_sym` at rows 4, 8, and callee_write_census.rb:711 (`unescaped.to_sym` without `valid_encoding?`); rows 1,3,10,11,14,15,21 guard it. The comment at reachability/scan.rb:633 states the hazard; no helper owns it.
10. **`&:sym` as a call spelling.** deep_erasure.rb:148 and callee_write_census.rb:711 read `&:clear` as a mutator; `Mutator`/`MutationWidening` (the direct call path) are never asked about the `&:sym` form from `statement_evaluator`; global_writer_reach.rb:233 enqueues it; effects/unit_scan.rb:949 returns early on any `SymbolNode` (no edge, so `[x].each(&:save)` records no effect edge); `last_line.rb:208` treats `&:gets` as a setter.
11. **Eval family.** `last_line.EVALS = {eval instance_eval class_eval module_eval}` vs `match_rebinding/self_calls.EVALS = {eval}` + `STRING_EVALS = {instance_eval class_eval module_eval}` vs `guard_rebinding.BLOCK_OR_CODE_NAMES = {instance_eval instance_exec class_eval class_exec module_eval module_exec}` (the `*_exec` variants are absent from the first two even though `instance_exec` takes a block with args).
12. **`define_singleton_method`.** In `DEFINERS` of 6 files and absent from `CensusForeignBlock.define_method_call?` (:331 only `define_method`), `ReceiverWriterCall` (:16 `WRITER_MACROS + define_method`).

#### 3. Node identity downstream

The sites are **keyed by `Prism::CallNode` object identity** in the load-bearing places; positions are used for rows and diagnostics.

- `Rigor::TypeOfMemo` (type_of_memo.rb:63, :150): `table.entries[scope][node]` with `compare_by_identity` at both levels: result memo for `type_of`.
- `Scope` side tables (scope.rb:397-402): `dynamic_origins`, `void_origins`, `plugin_typed_calls` (`@plugin_typed_calls[node] = true`, :366), `optimistic_origins`, all `compare_by_identity`, keyed by the call node.
- `scope_index` (ScopeIndexer.index; ScopeIndexer builds `{}.compare_by_identity` tables at scope_indexer.rb:212, 1720, 5152, 13104); read as `scope_index[call]` at 54 sites (e.g. ruby_deprecations.rb:192, rebinding_block_callees `scope_index&.[](receiver)`, dispatch.rb:56).
- Per-rule memo sets: `Plugin::NodeRuleWalk::State#@match_cache` (node_rule_walk.rb:131), `SigGen::BotProposalGuard#@calls` keyed by def node (bot_proposal_guard.rb:285), `Lens::FileReader#@visited_visibility_calls` keyed by call node (file_reader.rb:227), `Reachability::Scan` `@eval_frames`, `@definer_blocks`, `@rebinding_blocks`, `@body_statements` (scan.rb:685-729, `@body_statements.include?(node)` is read in the same expression as `SENDS` at :613), `SigGen::Generator` `@hook_blocks`, `@certain_definers` (generator.rb:1025-1028), `RebindingBlockCallees` `@scopes_reading_locals` (:115), and `ObservationCollector` (observation_collector.rb:390). 152 `compare_by_identity` uses in `lib/` in all.
- Positions: `DiscoveryIndex` ranges are `[start_offset, end_offset, name, kind, owner]` arrays (scope.rb:65, discovery_index.rb:473, scope_indexer.rb:6209 builds them from the **name literal's** location, not the call's); `ModuleFunctionState::Spellings` builds `call_span` from `node.location` (spellings.rb:46); `LexicalMethodSites` uses `call_node.location.start_offset` (lexical_method_sites.rb:55); `InEffectRefinements` uses `node.location.start_offset` (in_effect_refinements.rb:165); `AnonymousMetaClass` keys by `[path, line, column]` (anonymous_meta_class.rb:69). Diagnostics use `node.location`.
- **Precedent for synthesised nodes:** exactly two places call `Prism::Node#copy`: `AliasMutationFloor.literal_send_target` (alias_mutation_floor.rb:252, a new CallNode and ArgumentsNode, location preserved, receiver and argument nodes shared) and `Narrowing` (narrowing.rb:1250, `node.copy(receiver: ReceiverAlias.read_of(write))`). The synthesised send node is only passed to `MutationWidening`, `ElementReadWidening`, `AliasMutationFloor.candidate?` and `OutBufferMutation` (statement_evaluator.rb:2003-2018); none of those looks the node up in an identity table (`rewritten_element(call_node, scope)` and `mutator_arg_types` call `type_of` on the shared argument nodes only). It works because the copy is never a key.
- `try_literal_send` (expression_typer.rb:2745) dispatches with the **outer** original node as `call_node:` and inner `arg_types`, which is #1872's off-by-one: a view that reorders arguments but is passed to dispatch as `call_node` would break that, unless the view carries the original node plus the inner args/name.
- The `&:sym` path passes a `BlockArgumentNode` as `call_node:` to `MethodDispatcher.dispatch` (expression_typer.rb:6642); `constant_folding.rb:238` notes "internal per-element dispatches hand a non-CallNode (e.g. the `&:sym` BlockArgumentNode) as `call_node`". So consumers of `context.call_node` already accept a non-CallNode.

Conclusion: a normalising view **must wrap, never replace**, the original node. It must expose the original `CallNode` (for `equal?`/identity-table lookups, `location`, `scope_index[...]`, `type_of`) next to the normalised `(selector, argument nodes, via)`. Argument nodes in the view must be the original argument nodes (shared with the tree), because `type_of(arg)` memoises on identity. Synthesising a `CallNode` is only safe where the result never becomes a key, as in row 15.

#### 4. Existing partial abstractions (seed candidates)

- **`Source::Literals`** (source/literals.rb:28-90): the one place that owns "is this node a literal `:sym`/`"str"` and what does it name"; `symbol_or_string`, `symbol_arg(call, i)`, `symbol_arguments`. Used by rows 5, 22, 33, 35 and many plugins. Does not guard `valid_encoding?` (see divergence 9) and has no notion of `send`.
- **`ReceiverWriterCall.called(node)`** (receiver_writer_call.rb:55-62): already returns `[name, arguments]` "seen through a `send`", the closest existing normalising view; limited to non-self receivers and S P _ .
- **`ScopeIndexer#mixin_call_view` / `#visibility_call_parts`** (scope_indexer.rb:8404, 9615): same shape, local to the indexer; the only ones that encode the `public_send` rule.
- **`Rebinding BlockCallees::Dispatch.dispatch(call)`** (dispatch.rb:28-35): returns `[name, receiver]` across `send` and `method(:x).call/bind_call` chains, the only one that models Method objects.
- **`CalleeWriteCensus.literal_send?`** (callee_write_census.rb:141): shared by statement_evaluator (rows 12, 29).
- **`AliasMutationFloor.literal_send_target`**: the only one producing a node-shaped view (via `copy`).
- Constants named `SEND_CALLS`/`SENDS`/`SEND_NAMES`/`SEND_HAND_OFFS`/`LITERAL_SEND_SELECTORS`/`DYNAMIC_SEND`/`REFLECTIVE_SEND(_METHODS)`/`HOOK_SEND_CALLS`/`SURFACE_SEND_CALLS`/`CONCERN_SEND_CALLS`/`DEFINER_SEND_CALLS`/`SEND_CALL_NAMES`/`VISIBILITY_SEND_CALLS`: 23 constants equal to `%i[send __send__ public_send]` (two are `send __send__` only: `VISIBILITY_SEND_CALLS`, `Spellings::SEND_CALLS`, `SEND_NAMES` of ruby_deprecations). No `ReflectiveCall` module exists.
- No shared `ReflectiveCall`/`Spelling` helper exists: `grep -rn "ReflectiveCall" lib` returns nothing.

Best seed: a `Rigor::Source::ReflectiveCall` view built from `ReceiverWriterCall.called` + `mixin_call_view` + `Dispatch.dispatch` + `Source::Literals`, holding `node` (original), `selector` (Symbol or `:dynamic`), `args` (original nodes after the shift), `via` (`:direct | :send | :public_send | :__send__ | :method_call`), `visibility` (`:private_ok | :public_only`), `receiver` (node or `:implicit`).

#### 5. Issue to site map

| issue | gist | fixed at |
|---|---|---|
| #2167 | `send(:define_method) {}` not narrowed / not counted | row 37 (`DefineMethodBlockSelf`, `Scope#block_self` scope.rb:647); keep row 7/11/14 in step |
| #2169 | `define_method` with lambda/proc arg | row 7 (`CensusForeignBlock`), row 11, row 47 |
| #2425 | `tap`/`send` store missed by mutation widening | row 15 (extend to `tap`), row 26 (`try_literal_send`), row 12 |
| #2913 | `Constant[Set]` not widened by closure, `&:sym`, `method(:x).call`, `instance_eval` | rows 39-40 (`&:sym`), row 46 (method handles), row 12 `OPAQUE`, row 31 |
| #1417 | match method reached via `Method#call`, `bind_call`, `super`, Symbol proc | row 2 (the only `bind_call` modelling), rows 19, 20 (`$~`), row 44 (`last_line.rb:179`/`match_rebinding.rb:207`) |
| #1872 | `try_literal_send` passes the outer call node, mis-corresponds arguments | row 26 (expression_typer.rb:2745-2760) |
| #2087 | `call.undefined-method` on locals gaining singleton methods via alias, `singleton_class.define_method`, `extend_object` | row 38 (`lexical_method_sites.rb` `opened_method_name`, :160-166) |
| #2984 | more definer spellings, `send(:define_singleton_method)`, `Module.class_eval` | rows 32-33 (`hook_definer_name_node`, `record_definer_name_row`), 36, 47 |
| #2983 | ivar census: `module_eval` on included module, string `class_eval` | row 14 (`IvarWriterCensus`, `STRING_EVALS`), row 50 |
| #2246 | `Es.send(:module_function)` constant receiver; visibility follow-ups | row 22 (`Spellings.arguments`), row 35 |
| #3057 | `ConstructionEscape` frame-call scan misses `send(:eval)`, `local_variable_get`, `TOPLEVEL_BINDING` | row 31 (`RemoverHolderScan.FRAME_CALLS` :48-50) and `ConstructionEscape` (not in this inventory: separate frame-call scan); `send` form would route through the shared view |
| #2475 | proven ivar writer does not clear a mark; `attr_writer` / `send(:x=)` nil writes never report | rows 14, 49 (`IvarWriterCensus`, `ReflectiveIvarWrite`); `send(:x=)` is an attribute-writer spelling no site resolves |
| #2376 | callee floor misses `send(:[]=)`, lambda the callee calls | rows 12, 29 (`CalleeWriteCensus`, `statement_evaluator` hand-off) |
| #2704 | alias floor: interpolated `send` name | row 15 (`literal_send_target`) ; row 34 has the only interpolation reader |
| #2612 | callee floor: post params, `bind_call`, `Proc#call` not followed | rows 2, 12 (`OPAQUE_ARGUMENTS`), 46 |
| #2632 | `send` via constant receiver not followed | rows 12, 29 (`send_hand_off?`, `opaque_sink_call?`, `resolve_self_callees`) |
| #2697 | alias floor: lambda bodies, private `send`, `each_value` | rows 15, 16 |
| #2673 | callee floor: `define_method` with computed name | row 33 (`record_definer_name_row`), row 12 |
| #2386 | ivar/constant census misses `send(:const_set)` and in-place mutation | row 51 (`const_set` sites: scope_indexer.rb:3793, walker.rb:243), row 10 |
| #1377 | block scan misses `[]=` Regexp index, unary `~`, matching `send`, String `eval` | rows 19-20 (`MatchRebinding::Calls`/`SelfCalls`) vs the block scan in `match_rebinding.rb` |
| #2401 | callee floor in caller blocks: walk foreign `class_eval`/`define_method` blocks | rows 7, 12, 50 (`InterveningIvarReset.foreign_self_block?`, `CensusForeignBlock`) |
| #2160 | private call from `class_eval` / later reopening leaves method public | rows 35, 38 (`Lens::FileReader`) |
| #2100 | `--incremental` stale after hook via `define_singleton_method`, extended module, string `module_eval` | rows 32, 36, 50 |
| #1969 | `module_function` singleton side, `send/prepend` copies | row 22 |
| #1920 | rigor-rspec `define_method(:==)` | plugin (out of scope), row 47 |
| #2356 | `instance_eval { def name }` or `singleton_class.include` silences sibling classes | rows 36 (`singleton_naming_call_names`), 50 |
| #2048 | singleton rewrites: method-body rewrites, `class << self attr_writer` | rows 36, 47 (`singleton_naming_call_names`, scope_indexer.rb:7155-7170) |

## Survey scripts

`survey.rb`:

```ruby
# frozen_string_literal: true
require "prism"
SENDS = %i[send __send__ public_send].freeze
META = %w[include extend prepend private public protected module_function define_method define_singleton_method
          alias_method attr_reader attr_writer attr_accessor instance_variable_set instance_variable_get const_get
          const_set class_eval module_eval instance_eval instance_exec class_exec module_exec eval remove_method
          undef_method private_class_method public_class_method private_constant remove_const binding
          method instance_method respond_to? send __send__ public_send].freeze
class V < Prism::Visitor
  attr_reader :inner, :tot
  def initialize = (super; @inner = Hash.new(0); @tot = Hash.new(0))
  def visit_call_node(node)
    @tot[:calls] += 1
    if SENDS.include?(node.name)
      @tot[:send_family] += 1
      f = node.arguments&.arguments&.first
      if f.is_a?(Prism::SymbolNode) || f.is_a?(Prism::StringNode)
        @tot[:literal] += 1
        @tot[:literal_string] += 1 if f.is_a?(Prism::StringNode)
        @tot[:literal_public_send] += 1 if node.name == :public_send
        n = f.unescaped
        if META.include?(n)
          @inner[n] += 1; @tot[:literal_meta] += 1
        else
          @tot[:literal_plain] += 1
          @tot[:literal_plain_setter] += 1 if n.end_with?("=")
        end
      elsif f.is_a?(Prism::InterpolatedStringNode) || f.is_a?(Prism::InterpolatedSymbolNode)
        @tot[:interpolated] += 1
      else
        @tot[:computed] += 1
      end
    end
    b = node.block
    @tot[:amp_sym] += 1 if b.is_a?(Prism::BlockArgumentNode) && b.expression.is_a?(Prism::SymbolNode)
    super
  end
end
v = V.new
n = 0
skipped = 0
ARGV.each do |dir|
  Dir.glob(File.join(dir, "**/*.rb")).each do |f|
    next if f.include?("/vendor/") || f.include?("/node_modules/")
    n += 1
    begin
      Prism.parse_file(f).value.accept(v)
    rescue StandardError
      skipped += 1
    end
  end
end
puts "files=#{n} skipped=#{skipped}"
v.tot.sort_by { |k, _| k.to_s }.each { |k, c| puts format("  %-22s %8d %8.4f%%", k, c, 100.0 * c / v.tot[:calls]) }
puts "inner meta selectors sent by literal name:"
v.inner.sort_by { |_, c| -c }.each { |k, c| puts "  #{k}: #{c}" }
```

`handles.rb`:

```ruby
# frozen_string_literal: true

# Read-only census of reflective call spellings over Ruby trees. Usage: ruby handles.rb DIR...
require 'prism'

SENDS = %i[send __send__ public_send].freeze
READERS = %i[method public_method singleton_method instance_method public_instance_method].freeze
HANDLE_CALLS = %i[call yield === [] bind_call].freeze
WRAPPERS = %i[bind unbind to_proc curry].freeze

class Census < Prism::Visitor
  attr_reader :c

  def initialize
    super
    @c = Hash.new(0)
  end

  def visit_call_node(node)
    @c[:calls] += 1
    if SENDS.include?(node.name)
      @c[:send_family] += 1
      @c[:"via_#{node.name}"] += 1
      first = node.arguments&.arguments&.first
      case first
      when Prism::SymbolNode then @c[:send_symbol] += 1
      when Prism::StringNode then @c[:send_string] += 1
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then @c[:send_interpolated] += 1
      when nil then @c[:send_noargs] += 1
      when Prism::SplatNode then @c[:send_splat_first] += 1
      else @c[:send_computed] += 1
      end
      if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        rest = node.arguments.arguments.drop(1)
        @c[:send_lit_with_block] += 1 if node.block
        @c[:send_lit_with_splat_rest] += 1 if rest.any?(Prism::SplatNode)
        @c[:send_lit_with_kwargs] += 1 if rest.last.is_a?(Prism::KeywordHashNode)
        @c[:send_lit_recv_implicit_or_self] += 1 if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
        if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
          @c[:send_lit_recv_constant] += 1
        end
        begin
          @c[:send_lit_nested_send] += 1 if SENDS.include?(first.unescaped.to_sym)
        rescue StandardError
          nil
        end
      end
    end
    @c[:method_reader] += 1 if READERS.include?(node.name) && node.arguments
    if HANDLE_CALLS.include?(node.name)
      r = node.receiver
      r = r.receiver while r.is_a?(Prism::CallNode) && WRAPPERS.include?(r.name)
      if r.is_a?(Prism::CallNode) && READERS.include?(r.name)
        @c[:handle_chain_call] += 1
        @c[:handle_chain_bind_call] += 1 if node.name == :bind_call
      end
    end
    blk = node.block
    if blk.is_a?(Prism::BlockArgumentNode)
      @c[:block_pass] += 1
      e = blk.expression
      if e.is_a?(Prism::SymbolNode)
        @c[:block_pass_symbol] += 1
      elsif e.is_a?(Prism::CallNode) && READERS.include?(e.name)
        @c[:block_pass_method_reader] += 1
      end
    end
    super
  end
end

census = Census.new
files = ARGV.flat_map { |dir| Dir.glob(File.join(dir, '**/*.rb')) }
            .reject { |f| f.include?('/vendor/') || f.include?('/node_modules/') }
skipped = 0
files.each do |f|
  Prism.parse_file(f).value.accept(census)
rescue StandardError
  skipped += 1
end
c = census.c
puts "files=#{files.size} skipped=#{skipped}"
c.sort_by { |k, _| k.to_s }.each do |k, v|
  puts format('  %-34s %8d  %7.3f%% of calls', k, v, 100.0 * v / c[:calls])
end
```
