# ADR-57 Slice 1 — gate-open firing adjudication (2026-06-12)

Method: temporarily forced `ExpressionTyper#adoptable_self_call_result?`
to `return true` (gate fully open) on the post-ADR-55/56 engine and
diffed `rigor check --no-cache lib` + three corpora (Mastodon
`app/models`, haml `lib`, kramdown `lib`) against their gate-closed
runs. Every firing classified *genuine* (adopted type correct, diagnostic
earned) or *artifact* (adopted type wrong — an evaluator blind spot). The
gate-closed baseline is zero firings on all four targets, so the entire
gate-open set IS the delta.

## Self-check delta (`rigor check lib`) — 25 firings, pre-fix

| file:line | diagnostic | helper | adopted type | true behaviour | verdict | mechanism |
| --- | --- | --- | --- | --- | --- | --- |
| scope_indexer.rb:1783 | always-truthy | `record_class_or_module?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped (tail-only eval) |
| scope_indexer.rb:1785 | always-truthy | `record_meta_new_constant?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| method_dispatcher.rb:118 | always-falsey | `dispatch_precise_tiers` (via `precise`) | non-nil | `T?` | ARTIFACT | early `return` dropped |
| method_dispatcher.rb:967 | always-falsey | `class_new_lift` | non-nil | `T?` | ARTIFACT | early `return` dropped |
| constant_folding.rb:1151 | always-truthy | `safe?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| expression_typer.rb:923 | always-falsey | `Range` static-fold guard | non-nil | varies | ARTIFACT | early `return` dropped |
| sig_gen/generator.rb:161 | always-truthy | `descend_into_namespace?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| sig_gen/generator.rb:762 | always-falsey | `top_level_union?` | folded | `true \| false` | ARTIFACT | early `return` dropped (in block) |
| sig_gen/writer.rb:272 | always-falsey | `find_class_decl` (via `anchor_decl`) | folded | decl-or-nil | ARTIFACT | early `return decl` dropped |
| sig_gen/writer.rb:274 | always-falsey | `find_class_decl` (via `anchor_decl`) | folded | decl-or-nil | ARTIFACT | early `return` dropped |
| triage/catalogue.rb:291 | always-falsey | predicate (via `receiver`) | folded | `T?` | ARTIFACT | early `return nil` dropped |
| annotate_command.rb:92 | always-truthy | `parse_errors?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| trace_command.rb:44 | always-falsey | `file_exists?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return true` dropped |
| trace_command.rb:76 | always-truthy | `parse_errors?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| type_of_command.rb:72 | always-falsey | `file_exists?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return true` dropped |
| type_of_command.rb:77 | always-truthy | `parse_errors?` | `Constant[true]` | `true \| false` | ARTIFACT | early `return false` dropped |
| baseline_command.rb:246 | arg-type (`load`) | `parse_drift_options` Hash | `Hash[Symbol, "….yml"?]` | options Hash (String-bearing after parse) | GENUINE (RBS) | `Configuration.load` RBS is `?String`, body handles nil — RBS too strict |
| baseline_command.rb:320 | arg-type (`load`) | `parse_prune_options` Hash | nil-bearing | same | GENUINE (RBS) | same |
| plugins_command.rb:71 | arg-type (`load`) | `parse_options` Hash | `nil` | `String?` | GENUINE (RBS) | same |
| triage_command.rb:29 | arg-type (`load`) | `parse_options` Hash | `nil` | `String?` | GENUINE (RBS) | same |
| triage_command.rb:35 | always-falsey | `parse_options` Hash (`:format`) | `"text"` | `"text" \| <cli>` | ARTIFACT | block-captured Hash-element write (`options[:k]=v` in `opts.on{}`) invisible |
| diff_command.rb:48 | always-falsey | `parse_options` Hash (`:current_path`) | `nil` | `nil \| <cli>` | ARTIFACT | same (block-captured Hash-element write) |
| loader.rb:76 | possible-nil-recv | `topo_sort_plugins` → `kahn_collect` | `Plugin?` element | non-nil (in_degree invariant) | GENUINE-conservative | `Array#find` optionality (line 313); runtime invariant rules nil out, but `find` is soundly `Elem?` |
| method_catalog.rb:79 | return-type (`reset!`) | n/a (assignment-return) | `Hash` | `Hash` | GENUINE (RBS) | RBS `reset!: () -> nil` wrong — `@catalog = …` returns the Hash |
| constant_folding.rb:1176 | always-falsey | `string_unary_blow_up?` | `Constant[false]` | `false` (stub) | GENUINE | method really always returns `false` (stub); benign dead guard |

### Mechanism grouping

1. **Explicit early-`return` value dropped by the tail-only body
   evaluator (15 firings).** The dominant artifact class. Fixed.
2. **Block-captured Hash-element write (`options[k]=v` inside an
   `OptionParser#on` block) not written back (3 firings: triage:35,
   diff:48, sig_gen_command:59 — the last surfaced only after fix-1
   exposed `options.nil?`).** ADR-56 captured-mutation family, Hash-
   element variant. NOT fixed this slice.
3. **`Configuration.load` RBS `?String` too strict (5 firings incl.
   sig_gen_command:50 post-fix-1).** Self-authored RBS bug — `load`'s
   body is `path || discover` and nil-checks; RBS should be `?String?`.
   GENUINE-via-RBS; a one-line sig widen, not an engine artifact.
4. **`reset!` RBS `() -> nil` wrong (1).** GENUINE-via-RBS.
5. **`Array#find` optionality (loader.rb:76, 1).** Sound conservatism;
   runtime invariant (Kahn `in_degree.zero?`) rules out the nil. FP-risky
   if shipped; needs flow-narrowing, not a return-inference fix.
6. **Stub always-false guard (constant_folding:1176, 1).** GENUINE,
   benign.

## Corpus delta (gate-open, post-fix-1)

| target | firing | helper | adopted | true | verdict | mechanism |
| --- | --- | --- | --- | --- | --- | --- |
| haml parser.rb:469 | possible-nil-recv (`-`) | `parse_tag` → `parse_old/new_attributes` 3rd tuple elt | `Integer?` | `Integer` (`\|\| @line.index+1` strips) | ARTIFACT | multi-value `return a, b, c` not collected as a Tuple → over-optional destructure |
| haml parser.rb:470 | possible-nil-recv (`-`) | same | same | same | ARTIFACT | same (multi-value-return gap) |
| kramdown html.rb:193 | always-falsey | `inner` (via `res`) | `Constant[""]` | non-empty String | ARTIFACT | block-captured String `<<` mutation invisible (`result << …` in `each`) |
| kramdown html.rb:225 | always-falsey | `inner` (via `res`) | `Constant[""]` | non-empty String | ARTIFACT | same |
| kramdown html.rb:227 | always-falsey | `inner` (via `res`) | `Constant[""]` | non-empty String | ARTIFACT | same |

Mastodon `app/models`: zero gate-open delta.

### Additional mechanism groups (corpus-only)

7. **Multi-value `return a, b, c` not contributing a Tuple to method
   return (haml, 2).** Extension of mechanism 1; the slice-1 collector
   handles single-value and bare returns only. NOT fixed this slice.
8. **Block-captured String append (`s << x` in a block) invisible
   (kramdown, 3).** Same family as mechanism 2 (ADR-56), String-mutation
   variant. NOT fixed this slice.

## Slice-1 outcome

Fixed mechanism 1 (explicit-return contribution incl. block-internal,
nested-def barrier, reachability-respecting). Gate-open self-check delta
dropped 25 → 10. Residual is: 5 GENUINE-via-RBS `Configuration.load` +
1 GENUINE-via-RBS `reset!` (both are real self-authored RBS bugs worth a
separate sig fix), 1 stub always-falsey (GENUINE benign), 1 `find`-
conservatism (loader.rb:76, FP-risky), and 2 block-captured-Hash
artifacts (mechanism 2). Corpus residual is 5 firings across mechanisms
7 and 8.

The residual is NOT all-genuine, so per ADR-57 WD2 the gate stays closed.
Recommendation below.
