# Algorithms-and-Data-Structures-in-Ruby — opacity attribution (2026-09-01)

Archetype: beginner plain-Ruby (leetcode/hackerRank/exercism/codility exercises), no config, scanned `.`.

## Numbers

| metric | value |
| --- | --- |
| files | 256 (+3 parse-error files: codility/Iterations/BinaryGap.rb, exercism/atbash_cipher.rb, heuristic/MiniMax.rb) |
| expressions | 18755 |
| precision | 53.41% (10017 / 8738 opaque) |
| tiers | constant 6283, nominal 2503, shaped 743, refined 15, bot 473, dynamic_top 8738 |
| protection | 26.27% (1062 / 2980 unprotected) |
| cause_site_counts | inferred_return_untyped 1852, none 944, unsupported_syntax 144, explicit_untyped 40 |
| tractability | engine_gap 1996, add_rbs 40 |

Opaque split: local reads 3462 (def_param 1990, assigned_local 1263, block_param 209), calls 3328 (receiver: dynamic 2911, precise 306, implicit_self 111), ivars 183.

The most A-dominated target in the batch: def_param is the largest single bucket and the dynamic-receiver call cascade (`[]` 672, `-` 294, `==` 206, `+` 168, `length` 154 in add_a_type_here) is almost entirely arithmetic on untyped function parameters. unsupported_syntax is 4.8% of causes — below the F threshold (unhandled node classes: only CallOperatorWriteNode, 6 sites).

## Classified cases

1. **`Array#[]` 39 + `Array#[]=` 22 on bare Array — D (same two verified mechanisms as the Ruby corpus).** `visited=Array.new(len,0)` with Dynamic `len` discards the fill type → bare `Array` (the Array.new bisect in $SCRATCH/bisect_array_new.rb); the `visited[i]=1` half additionally hits the attribute-write-result gap (value of `x[k]=v` is the RHS). Site: /Users/megurine/repo/ruby/rigor-survey/Algorithms-and-Data-Structures-in-Ruby/arrays/CheckForConsecutive.rb:10-13.
2. **`String?#strip` — 28 — D (optional receiver via `gets`).** Every hackerRank script opens with `t = gets.strip.to_i`; `gets` is String? and dispatch answers Dynamic instead of the String arm, poisoning the whole script. Site: /Users/megurine/repo/ruby/rigor-survey/Algorithms-and-Data-Structures-in-Ruby/hackerRank/algorithms/implementation/AngryProfessor.rb:7. Highest-leverage single fix for this archetype.
3. **`ComplexNumber#real`/`#imaginary` — 28 — A (ADR-58).** `attr_accessor :real,:imaginary` getters resolve through the discovered-method tier to Dynamic; the backing ivars are param-sourced (`initialize(real=0, imaginary=0)`). Site: /Users/megurine/repo/ruby/rigor-survey/Algorithms-and-Data-Structures-in-Ruby/exercism/complex_number.rb:14-15. Counted, not designed (ivar-field + param inference).
4. **`Hash#[]` 11 / `Hash#[]=` 6 on bare Hash from `Hash.new()` — C/known.** `map=Hash.new()` yields unparameterized Hash; subsequent literal writes (`map[a[i]]=1`) accrete at runtime, but the open-shape read contract (PR #249) deliberately reads untyped, so folding Hash.new to `{}` would buy nothing. Site: /Users/megurine/repo/ruby/rigor-survey/Algorithms-and-Data-Structures-in-Ruby/arrays/CheckPairWithGivenDiff.rb:32-41. The `[]=` half is still covered by the attribute-write-RHS rule (D).
5. **`{}#[]` — 13 — C (settled open-shape contract).** Mutated hash literals (point_table in exercism/tournament.rb:12) widen to open HashShape; reads untyped by design.
6. **Container/tuple-of-Dynamic — `Array[Dynamic]#[]` 14, `[Dynamic,Dynamic]#max` 10, `Hash[Dynamic,Dynamic]#[]` 6 — C.** Roots are def params. Example: /Users/megurine/repo/ruby/rigor-survey/Algorithms-and-Data-Structures-in-Ruby/codility/Stacks and Queues/Fish.rb:8.
7. **`{}#[]=` — 6 — D (attribute-write-RHS family).** exercism/etl.rb:9.
8. **Aggregate: def_param 1990 + downstream arithmetic cascade (~2900 dynamic-receiver calls) — A (ADR-67, closed).** The archetype's opacity is overwhelmingly "untyped function parameter flows through integer arithmetic".
