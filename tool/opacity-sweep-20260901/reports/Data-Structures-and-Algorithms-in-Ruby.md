# Data-Structures-and-Algorithms-in-Ruby — opacity attribution (2026-09-01)

Archetype: beginner plain-Ruby (textbook chapters, Java-flavored style: `self.attr` accessors, `while` loops, camelCase). No config, scanned `.`. Largest corpus by expressions.

## Numbers

| metric | value |
| --- | --- |
| files | 113 (+5 parse-error files: AlgorithmsChapters/BT/GraphColouring.rb, Collections/Queue.rb, LinkedList/{Circular,DoubleCircular,LinkedList}.rb) |
| expressions | 49743 |
| precision | 61.20% (30443 / 19300 opaque) |
| tiers | constant 21069, nominal 6608, shaped 1570, refined 35, bot 1161, dynamic_top 19237, top 63 |
| protection | 49.77% (6011 / 6066 unprotected) |
| cause_site_counts | inferred_return_untyped 4095, none 1454, explicit_untyped 386, unsupported_syntax 124, analyzer_budget_cutoff 7 |
| tractability | engine_gap 4226, add_rbs 386 |

Opaque split: calls 8864 (receiver: dynamic 6151, precise 2510, implicit_self 203), local reads 7244 (def_param 5074, assigned_local 2074, block_param 96), ivars 13 (everything goes through `self.attr` accessors instead — see case 2). ParenthesesNode 1272 + If/And/Or joins ~600 are G mirrors.

Notable: the highest precise-receiver-but-opaque count in the batch (2510) — this corpus names its receivers and still loses them.

## Classified cases

1. **`Array#[]` 301 + `Array#[]=` 138 on bare Array — D (the verified `Array.new` mechanism, at its largest).** `f1 = Array.new(n){0}` with a Dynamic `n` discards the block's element type and yields unparameterized `Array` (bisect: $SCRATCH/bisect_array_new.rb); every subsequent `f1[i]` read is Dynamic and `f1[i] = …` also hits the attribute-write-result gap. Site: /Users/megurine/repo/ruby/rigor-survey/Data-Structures-and-Algorithms-in-Ruby/AlgorithmsChapters/DP/ALS.rb:2-12. Fixing `Array.new(dynamic_size, fill_or_block)` → `Array[T_fill]` closes ~440 sites in this corpus alone.
2. **Accessor-mediated state — `Heap#arr` 147, `Heap#size` 86, `Graph#count` 82, `Tree#root` 55, `Graph#Adj` 31, `BTree#root` 25, `RBTree#NullNode` 24 — A (ADR-58).** The textbook style writes ALL state through `attr_accessor` + `self.attr = …` (opaque ivar reads are just 13 — the state lives behind accessors): `attr_accessor :CAPACITY,:size,:arr,:isMinHeap; self.arr = Array.new(100){0}` (/Users/megurine/repo/ruby/rigor-survey/Data-Structures-and-Algorithms-in-Ruby/AlgorithmsChapters/Greedy/ChotaBhim.rb:1-8). Getters resolve through the discovered-method tier to Dynamic; the lever is ivar-field → accessor-return propagation (ADR-58 WD2/WD3), counted not designed. Also implies: ADR-58 work that types only literal `@ivar` reads misses this archetype — it must flow through the attr writer/reader pair.
3. **User-method returns — `Graph#addEdge` 95, `#addUndirectedEdge` 60, `GraphAM#addUndirectedEdge` 29 — A cascade.** `addEdge` ends `self.Adj[source].append(edge)` (/Users/megurine/repo/ruby/rigor-survey/Data-Structures-and-Algorithms-in-Ruby/Graph/Graph.rb:127-131): accessor-sourced Dynamic feeds the return (`inferred_return_untyped`, 4095 cause sites — the biggest cause bucket in the whole batch).
4. **`Queue#push` 46 (+pop/empty? in the dynamic bucket) — B (rbs core toplevel-alias gap, same as SizedQueue on the Ruby corpus).** `que = Queue.new()` (/Users/megurine/repo/ruby/rigor-survey/Data-Structures-and-Algorithms-in-Ruby/BinaryTree/Tree.rb:145) uses toplevel `::Queue`; the bundled rbs core declares only `::Thread::Queue`, so Rigor stub-synthesizes the constant and all methods answer Dynamic/top. One builtin-import alias (`Queue = Thread::Queue`, `SizedQueue = Thread::SizedQueue`) closes it corpus-wide.
5. **`Array[Dynamic]#[]` 52 — C.** Param-rooted container elements. Site: /Users/megurine/repo/ruby/rigor-survey/Data-Structures-and-Algorithms-in-Ruby/AlgorithmsChapters/BT/TSP.rb:43.
6. **`CallOperatorWriteNode` — 45 opaque sites — F (a genuinely unhandled construct, the only one in the batch).** `self.size += 1`-style attr op-writes have no PRISM_DISPATCH handler and fall to `unsupported_syntax`. This corpus's accessor-heavy style makes it the largest CallOperatorWriteNode population of the four targets (textbringer 5, Ruby 1, ADSR 6). Fix: desugar to read + operator + attribute-write (the attribute-write-RHS rule then types it).
7. **Aggregate — def_param 5074 + dynamic-receiver arithmetic cascade 6151 (`[]` 1632, `==` 518, `-` 496, `+` 487 in add_a_type_here) — A (ADR-67, closed).**
