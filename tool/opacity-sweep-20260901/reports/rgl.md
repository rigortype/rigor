# rgl — opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/rgl (paths: lib; target_ruby 3.3)

## Numbers

| metric | value |
| --- | --- |
| files | 28 (0 parse errors) |
| expressions | 3,938 |
| precision | 49.90% (constant 1040, nominal 737, shaped 134, bot 54; opaque 1973) |
| protection | 38.11% (274/719; lower_bound_typed 3) |
| cause_site_counts | inferred_return_untyped 247 (55.5%), none 135 (30.3%), unsupported_syntax 54 (12.1%), explicit_untyped 7, external_gem_without_rbs 2 |
| tractability | engine_gap 301, add_rbs 9 |

Opaque split: local reads 744 (def_param 406 / block_param 253 / assigned_local 85), calls ~680 (precise 113 / dynamic 428 / implicit_self 138), ivars 135. Block-param share is the highest of the five targets — graph traversal yields untyped vertices into every block.

## Cases

1. **Vertex/property maps: `Hash[Dynamic,Dynamic]#[]/#[]=` — 28+ sites — C.**
   Color maps, distance maps, component maps keyed by vertices that are inherently untyped (`comp_map[v]`, lib/rgl/condensation.rb:45; connected_components.rb:63). Downstream of the untyped-vertex design; closes only via generics on the graph (see case 3).

2. **Graph API returns: `DirectedAdjacencyGraph#add_edge/add_vertex/each_adjacent`, `Graph#each_vertex/detect` — ~30 sites — A-family (resolved, untyped return).**
   Plain defs reached through the `include MutableGraph`/`include Graph` chain (adjacency.rb:21, base.rb:139-140); the 55.5% `inferred_return_untyped` cause share says dispatch resolves and the *return* is the hole — bodies end in ivar dictionaries (`@vertices_dict`) and param-fed values. ADR-58 + ADR-67 territory; counted.

3. **Graph-as-module + non-generic Enumerable — C (design-level).**
   `module Graph; include Enumerable` (base.rb:139): `detect`/`inject`/`size` (base.rb:250 `inject(0) {...}`) yield untyped elements because Graph carries no element parameter. The real closer is RBS generics on Graph (add_rbs/ADR-20 flavored), not dispatch work.

4. **`def_event_handlers` string-eval macro — E.**
   lib/rgl/graph_visitor.rb:104-122: `class_eval <<-END` generates `handle_*` visitor methods; invoked at class level (graph_visitor.rb:133, edmonds_karp.rb). Generated defs invisible to the engine; plugin territory.

5. **Nilable Hash receiver `Hash[...]?#[]/#[]=` — 9 sites — D (repeat).**
   bipartite.rb:61,70; graph_visitor.rb:60 (`Hash[Dynamic,Symbol]?#[]`). Same nilable-receiver dispatch collapse verified on concurrent-ruby.

6. **`{}#[]=` empty-shape write, non-literal key — 3 sites — C (shape family).**
   path_builder.rb:26: a write with a dynamic key cannot extend the literal empty shape; answers Dynamic. Same family as parser's conditionally-populated shape key.

7. **attr_reader-backed state (`color_map` 5+2, `distance_map` 8 on dynamic recv) + 135 ivar reads — A-family known (ADR-58).**
   EdmondsKarpBFSIterator#color_map (edmonds_karp.rb:38) etc.

8. **`quote_ID` and dot-export helpers — 15 implicit-self sites — A.** Param-fed string helpers (rgl/dot.rb).

9. **F unsupported_syntax — 54 sites (12.1%).** Named constructs: `alias == eql?` operator aliasing (base.rb:57 — the base.rb:54 `==` example's receiver is attr_reader `source` over @source, then the aliased operator), `class_eval` heredoc metaprogramming (graph_visitor.rb:110), splat-only bracket constructors `def self.[](*a)` (base.rb:41). Small absolute volume.

10. **def_param 406 + block_param 253 — A (ADR-67, counted).**
