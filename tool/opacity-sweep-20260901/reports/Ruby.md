# Ruby (TheAlgorithms/Ruby) — opacity attribution (2026-09-01)

Archetype: beginner plain-Ruby corpus; no config, flat dirs of scripts + minitest test files. Scanned with explicit path `.`.

## Numbers

| metric | value |
| --- | --- |
| files | 188 (+4 parse-error files: searches/{binary,fibonacci,linear,ternary}_search.rb) |
| expressions | 17755 |
| precision | 62.95% (11176 precise / 6579 opaque) |
| tiers | constant 7261, nominal 2572, shaped 1098, refined 5, bot 240, dynamic_top 6566, top 13 |
| protection | 38.71% (1294 / 2049 unprotected) |
| cause_site_counts | inferred_return_untyped 1055, none 749, unsupported_syntax 200, explicit_untyped 44, analyzer_budget_cutoff 1 |
| tractability | engine_gap 1256, add_rbs 44 |

Opaque split: calls 3007 (receiver: dynamic 1994, implicit_self 592, precise 421), local reads 2353 (def_param 1351, assigned_local 657, block_param 345), ivars 82.

def_param is the single biggest bucket — beginner code is toplevel `def f(arr)` functions, so the corpus is A-dominated (ADR-67, closed), with `inferred_return_untyped` (1055) as the top protection cause: resolved user methods whose returns read those params/ivars.

## Classified cases

1. **`Array#[]` on bare nominal Array — 35 — D (verified by bisect).** `Array.new(n, 1)` with a Dynamic size arg falls back to unparameterized `Array`, discarding the fill/block element type; with a LITERAL size it folds all the way to a tuple (`Array.new(5, 1)` → `[1,1,1,1,1]`). Bisect: $SCRATCH/bisect_array_new.rb — `b = Array.new(n, 1); b[0]` → Dynamic[top] while `a = Array.new(5, 1); a[0]` → `1`. Corpus site: /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/arrays/get_products_of_all_other_elements.rb:26. Fix: when size is Dynamic, degrade to `Array[type(fill)]` / `Array[type(block-result)]` instead of bare Array.
2. **Rest-parameter methods never fold their return — `singleton(AverageMedian)#average_median` 7, and a share of the toplevel-function calls — D (verified by bisect).** Any user method with a `*rest` parameter answers Dynamic at every call site even when every branch returns a constant (`puts` → nil): $SCRATCH/bisect_avg_median.rb — `def self.f(n, *array); puts "a"; end; M5.f(2)` → Dynamic[top], while the identical method WITHOUT the splat (even with def-level `rescue` + bare `raise`) folds to `nil`. Receiver-side is precise (`singleton(AverageMedian)`); corpus site /Users/megurine/repo/ruby/rigor-survey/Ruby/maths/average_median.rb:32. Fix: bind the rest param as `Array[join(extra args)]` (or `Array[untyped]`) and proceed with body return folding rather than aborting dispatch.
3. **User-method returns reading ivars/params — `UnweightedGraph#add_edge` 26, `Stack#push` 12, `AvlTree#to_array` 11, `WeightedGraph#edges` 10, `UnweightedGraph#neighbors` 10 — A cascade (ADR-58/67, closed).** e.g. add_edge ends `@neighbors[end_node].add(start_node) unless directed` (/Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/graphs/unweighted_graph.rb:36-42): the return is ivar-sourced (+ modifier-`unless` nil union). This is the `inferred_return_untyped` 1055 family. Counted, not designed.
4. **minitest calls — implicit-self `assert` 120, `assert_equal` 27, `assert_raises` 11 — B (gem RBS not in environment).** Test classes subclass `Minitest::Test` (require 'minitest/autorun'); no minitest RBS in the plugin-aware env, so every assertion is an unresolved implicit-self call. Example: /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/graphs/bfs_test.rb:12.
5. **`{}#[]=` — 11 — D (attribute-write result typing; same mechanism verified on textbringer).** `result_hash[num] = 1` with precise receiver `{}` and precise RHS `1` still types Dynamic. Site: /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/arrays/single_number.rb:23. Cross-corpus confirmation of the setter-RHS rule.
6. **Optional receivers from nil-unions — `String?#split` 11 (`gets.split`, /Users/megurine/repo/ruby/rigor-survey/Ruby/sorting/bead_sort.rb:22) and `0?#-` 9 (`@size - 1` where the ivar summary unions nil, /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/linked_lists/doubly_linked_list.rb:15) — D.** Dispatch on `T?` answers Dynamic instead of the non-nil arm's result. Beginner scripts hit this constantly through `gets`.
7. **`SizedQueue#push` — 7 — B (rbs core alias gap).** Bundled rbs declares `::Thread::Queue` / `::Thread::SizedQueue` but NOT the toplevel `::SizedQueue` / `::Queue` aliases real Ruby defines; Rigor stub-synthesizes the constant (receiver reads nominal `SizedQueue`) and `push` answers `top`. Verified: type-of /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/queues/queue.rb:87:7 → top; RBS env probe shows only Thread::-namespaced decls. Fix: builtin-import/overlay declaring the toplevel aliases.
8. **Container-of-Dynamic — `Hash[Dynamic,Dynamic]#[]` 16, `non-empty-array[top]#[]` 8 — C.** Element reads whose element type is already opaque from A roots. Example: /Users/megurine/repo/ruby/rigor-survey/Ruby/data_structures/arrays/intersection.rb:68.
9. **F check (unsupported_syntax 200 ≈ 9.8%):** among opaque nodes exactly ONE node class lacks a PRISM_DISPATCH handler (`CallOperatorWriteNode`, 1 site); the bucket is again unresolved implicit-self dispatch (minitest asserts, cross-file toplevel functions) mislabeled as syntax — same taxonomy artifact found on textbringer.
10. **attr-backed getters read Dynamic — implicit-self `root` 40, `arr` 18, `stack` 8, `queue` 7, `heap_size` 7 — A (ADR-58).** attr_reader calls resolve through the discovered-method tier to Dynamic[Top]; precision needs ivar-field → accessor return propagation (ADR-58 WD2/3).
