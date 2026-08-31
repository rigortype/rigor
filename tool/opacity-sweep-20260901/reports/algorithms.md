# algorithms — opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/algorithms (paths: lib)

## Numbers

| metric | value |
| --- | --- |
| files | 14 (0 parse errors) |
| expressions | 4,076 |
| precision | 37.61% — lowest of the five (constant 904, nominal 367, shaped 173, bot 89; opaque 2543) |
| protection | 16.37% (156/953; lower_bound_typed 3) |
| cause_site_counts | inferred_return_untyped 385 (48.3%), none 367 (46.0%), unsupported_syntax 37 (4.6% — under threshold), explicit_untyped 8 |
| tractability | engine_gap 422, add_rbs 8 |

Opaque split: local reads 948 (def_param 544 / assigned_local 356 / block_param 48), calls 916 (precise 64 / dynamic 775 / implicit_self 77), ivars 196.

## Cases

1. **`Struct.new` node classes — D — the dominant root.**
   `Node = Struct.new(:left, :right, :obj)` (lib/containers/deque.rb:10), `Node = Struct.new(:key, :value, :left, :right)` (lib/containers/splay_tree_map.rb:19). The constant resolves (receiver shows `singleton(Containers::RubySplayTreeMap::Node)`), but `#new` answers Dynamic (5 named sites) — Struct's synthesized constructor and accessors are unmodeled. Everything downstream is the gem's core data flow: `left` 74, `right` 68, `key` 37, `right=` 30, `left=` 28, plus comparison/arithmetic on node fields — several hundred dynamic-receiver sites are C-propagation of this one hole.
   Fix direction: synthesize member accessors + `new` arity from literal `Struct.new(:sym,...)` — the ADR-48 Data-value folding sibling. Highest single-mechanism payoff in this target.

2. **`require`-fallback C-extension alias — D (runtime implementation selection, same family as concurrent-ruby).**
   `begin; require 'CDeque'; Containers::Deque = Containers::CDeque; rescue LoadError; Containers::Deque = Containers::RubyDeque; end` (lib/containers/deque.rb:163-171); same pattern for other containers. One arm names a class that exists only as a C extension (statically unresolvable), so the joined constant goes Dynamic even though the rescue arm is fully analyzable.
   Fix direction: in a `rescue LoadError` fallback assignment, type the constant as the resolvable arm (FP-safe: the unresolvable arm contributes Dynamic anyway, and the join direction that keeps the known class strictly improves precision downstream).

3. **Container API over ivar state (`Containers::Stack#push/pop/empty?`, `Heap#size/#pop`) — A-family (resolved, untyped return).**
   Plain defs; bodies delegate to `@container`/`@stored`/`@next` (heap.rb) — ADR-58 ivar territory. Examples: rb_tree_map.rb:186-190, heap.rb:176.

4. **`instance_variable_get` reflection — 4 sites — F/legitimate dynamism.**
   `otherheap.instance_variable_get("@next")` (lib/containers/heap.rb:164-166) — reflection on another object's ivars; no static answer short of literal-string ivar modeling.

5. **Empty-literal shape writes with dynamic index — C (shape family).**
   `[]#[]=` (sort.rb:182), `[]#[]` (heap.rb:353), `Hash[Dynamic?,Dynamic]#[]` (sort.rb:167) — dynamic-key access on literal-derived shapes; same family as parser/rgl.

6. **Recursive tree helpers (`isred` 11, `splay` 6, `colorflip` 5, `*_recursive`) — A.**
   Param-fed recursive helpers over node params (`def isred(h)` rb_tree_map.rb) — ADR-67 counted; note these will only close if Struct nodes (case 1) type first.

7. **def_param 544 + assigned_local 356 — A/C.** Sort/search take naked arrays and thread locals through swaps — assigned_local share (356) is the highest proportionally of the five targets; mostly C from Dynamic containers.

unsupported_syntax is 4.6% — below the 5% sampling threshold; no F breakdown required.
