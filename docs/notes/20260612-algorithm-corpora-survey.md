# Algorithm / data-structure corpora survey (general-code Dynamic-fall + FP hunt)

2026-06-12. Read-only engine-behaviour survey against four freshly-cloned
algorithm/data-structure repositories under
`/Users/megurine/repo/ruby/rigor-survey/`. **No `lib/` (rigor) changes.**
Sibling of `20260612-cruby-stdlib-survey.md`; this round targets
near-metaprogramming-free *textbook* Ruby, where the user's trustworthiness
criterion bites hardest: an unexpected `Dynamic[top]`, or a false positive,
on a plain quicksort or a `node = node.next` loop undermines Rigor. Heavy
generics / metaprogramming are excused; almost everything imprecise here is
signal.

Methodology follows the stdlib survey's **"Residual adjudication" lesson**:
every radius estimate is *sample-adjudicated against the source* before it
is sized. The headline mechanism was confirmed by reading the firing sites,
not inferred from counts.

Targets (READ-ONLY): `algorithms/` (kanwei/algorithms gem, `lib/` only),
`Ruby/` (TheAlgorithms/Ruby), `Algorithms-and-Data-Structures-in-Ruby/`
(ADSR), `Data-Structures-and-Algorithms-in-Ruby/` (DSAR).

Invocation: cwd=target, `BUNDLE_GEMFILE=<rigor>/Gemfile`, flake-wrapped
`bundle exec exe/rigor {coverage|check --no-cache} <paths>`.

## Per-repo coverage (rigor coverage --format=json)

| Repo | files | exprs | precise_ratio | constant | nominal | shaped | dynamic_top |
| --- | --- | --- | --- | --- | --- | --- | --- |
| algorithms (gem `lib/`) | 14 | 4 076 | **0.357** | 0.212 | 0.084 | 0.038 | 0.642 |
| Ruby (TheAlgorithms) | 188 | 17 755 | **0.595** | 0.399 | 0.120 | 0.061 | 0.404 |
| ADSR | 256 | 18 755 | **0.519** | 0.319 | 0.136 | 0.037 | 0.480 |
| DSAR | 113 | 49 743 | **0.606** | 0.419 | 0.131 | 0.031 | 0.394 |

`refined` and `dynamic_specific` are ~0 everywhere (these corpora ship no
RBS and use no refinements). `bot` 0.01–0.03 (dead clauses / empty bodies).

**The coverage split is explained by one axis: data-structure density.**
The kanwei gem (`algorithms/`) is *all* container classes (RB/splay tree,
heap, trie, kd-tree) — every method threads ivar-backed node fields, so it
floors at 0.357 (64 % Dynamic). TheAlgorithms/Ruby is mostly standalone
toplevel-`def` array/number scripts → 0.595. The two mixed repos sit
between. **The precise-ratio is a direct readout of "how much of this file
is node-ivar plumbing vs untyped-param array math."**

### Worst files (≥30 exprs), per repo — all are container/tree classes or unannotated array algos

- **algorithms**: `kd_tree` 0.256, `rb_tree_map` 0.279, `heap` 0.297,
  `sort` 0.330, `trie` 0.338, `splay_tree_map` 0.374.
- **Ruby**: `binary_trees/avl_tree` 0.212, `binary_trees/bst` 0.271,
  then unannotated sorts (`merge_sort` 0.297, `quicksort` 0.357,
  `bucket_sort` 0.322, `pancake_sort` 0.346).
- **ADSR**: `middle_of_a_linked_list` 0.129, `invert_binary_tree` 0.137,
  `lowest_common_ancestor` 0.174, `*_linked_list` 0.19–0.20,
  `sorted_array_to_bst` 0.244.
- **DSAR**: `RBTree` 0.273, `SPLAYTree` 0.329, `AVLTree` 0.369,
  `BTree` 0.386, plus unannotated `QuickSort`/`QuickSelect`/`MergeSort`.

## Diagnostic adjudication (rigor check --no-cache)

Per-repo totals: algorithms 32 err / 3 warn · Ruby 20 err / 15 warn · ADSR
27 err / 19 warn · DSAR 100 err / 11 warn. Because every file here *runs*
(textbook implementations), each `error` is an FP candidate unless it is a
genuine bug in the textbook code (those are flagged separately — fun finds).

| Diagnostic class | ~Count (4 repos) | Verdict | Mechanism / note |
| --- | --- | --- | --- |
| `call.possible-nil-receiver` on **node fields** (`left` `right` `next` `parent` `value` `val` `data` `key` `color`/`colour` `child` `src` `dest` `cost`) | **109** (alg 31, Ruby 0, ADSR 11, DSAR 67) | **ARTIFACT — engine gap (dominant)** | Attr-accessor-backed node ivar reads `Dynamic[top] \| nil`; `node.left.foo` chains in rotations / traversal fire. THE survey headline — see §Ivar radius. |
| `call.undefined-method`/`possible-nil` `… for nil` on `Array#index`/`#last`/`#first`/`#pop` results consumed by `<`/`*`/`+` | ~8 (Ruby `topological_sort_test` 9× `index < `, `get_products` 2× `.last *`) | **MIXED — genuine-conservative, guard-near-miss** | `Array#index` truly returns `Integer?`; `.last * num` is guarded by `count > 0` but the existing non-empty-array narrowing keys on `empty?`/`any?`, not `count > 0`/`size > 0`. |
| `flow.always-truthy/falsey-condition` | 14 (alg 3, Ruby 1, ADSR 4, DSAR 6) | **ARTIFACT — ivar/local constant-fold over-eagerness** | e.g. deque `if @size == 1` folds to false: `@size` seeded `0` in ctor, mutation not credited. Same family as stdlib C5 `$extmk`. |
| `call.unresolved-toplevel` (`traverse`, `private`, etc.) | 22 (Ruby 12, ADSR 9, DSAR 1) | **EXCUSED — script idiom** | Each standalone script defines its own toplevel `def traverse`/calls `private` at toplevel; ADR-17 `pre_eval:` territory, not an engine bug on library code. |
| `flow.dead-assignment` (`… assigned but never read`) | 11 (Ruby 2, ADSR 5, DSAR 4) | **GENUINE catch (benign)** | Real dead locals in textbook code (`two_sum` allocates `result`/`result_array` then `return [i,j]`; `find_missing_number` `missing_element`, etc.). Correct, low-stakes — fun finds. |
| `instance variable … previously assigned Float; this write assigns Array` | 1 (ADSR `min_stack`) | **ARTIFACT — two impls in one file** | File holds two `MinStack` class bodies (Float-sentinel vs Array); flow-insensitive class-ivar union crosses them. |
| `wrong number of arguments to 'new' on OpenStruct` | 1 (ADSR) | **NEEDS-RBS** | `OpenStruct.new(hash)` — RBS arity gap. |
| `.Equals` / `.ToCharArray` for `String`, `Console.WriteLine` | 6 (DSAR `String/StringClass.rb`) | **GENUINE catch (true find)** | The file is literally **C# pasted into a `.rb`** — does not run as Ruby. Rigor correct. |
| parse errors | 12 files (Ruby 4, ADSR 3, DSAR 5) | **GENUINE catch — broken scripts** | Unterminated regexp/`while`, stray `else`/`end`, C#-style `)` — genuinely un-parseable textbook files, not Rigor bugs. |

### Fun finds (genuine bugs in the textbook code)

- **Dead allocations**: `Ruby/two_sum.rb` `result_array = []`, `ADSR
  two_sum.rb` `result`, `ADSR FindMissingNumber` `missing_element`,
  `FindTwoRepeatingElem` `temp`, `run_length_encoding` `curr_char`,
  `insert_delete_get_random_o1` `last_index` — all assigned, never read.
- **C# in a `.rb`**: `DSAR String/StringClass.rb` (`Console.WriteLine`,
  `str.Equals`, `text.ToCharArray`).
- **Broken scripts**: 12 files fail to parse (genuine syntax errors).

## Dynamic-fall mechanism buckets

Sample-adjudicated against the firing sites and `rigor type-of` probes.
Radius = sites across the four repos.

| Bucket | Representative snippet | Radius (4 repos) | Verdict | Difficulty | FP-risk of fix |
| --- | --- | --- | --- | --- | --- |
| **M1. Node-ivar nilable read** (attr_accessor ivar `nil`/untyped-written across methods → `Dynamic[top] \| nil`; every `node.left.x` chain fires possible-nil) | `r = @right; r_key = r.key` (rb_tree `rotate_left`); `self.left = nullNode` then `node.left.colour` (RBTree) | **109 possible-nil errors** + drives the **64 %/48 % `dynamic_top` floor** in every container file | **ENGINE GAP — top priority** (queued cross-method ivar definite-assignment ADR candidate) | high | **medium** (must keep genuinely-optional fields nilable) |
| **M2. `node = node.next` / `root = root.right` while-loop traversal** | `root = @next; loop { root = root.right; break if root == @next }; … root.key` (heap); `current = current.next until current.next.next.nil?` (linked list) | subsumed in M1 (~20 of the 109 are loop-rebind reads of a nilable ivar) | ENGINE GAP (M1 with a loop-carried nilable local) | high | medium |
| **M3. Untyped-param → whole-method Dynamic** | `def quicksort(arr); pivot = arr.delete_at(…)` → `arr` untyped → all derived Dynamic; `def merge_sort(array); mid = array.length/2` Dynamic | drives the 0.33–0.40 precise-ratio of *every* unannotated sort/number script (Ruby/DSAR `QuickSort` etc.) | **EXCUSED** (gradual-typing entry point — no signature, no inference seed) | n/a | n/a |
| **M4. `Array#index`/`#last`/`#first`/`#pop` returns `T?` consumed bare** | `sorted_items.index(:a) < sorted_items.index(:b)` (topo test); `prefix_products.last * num` under `count > 0` | ~8 (Ruby) | **MIXED**: genuine-conservative on `index`; **near-miss** on `.last`/`.first` after a `count > 0`/`size > 0` guard (existing non-empty narrowing keys on `empty?`/`any?`, not `count`) | low (extend non-empty narrowing to `count`/`size` comparisons) | low |
| **M5. Ivar/local constant-fold over-eagerness → always-truthy/falsey** | `def initialize; @size = 0; end … if @size == 1` folds false (deque) | 14 always-truthy/falsey | **ARTIFACT** — same family as stdlib survey C5 (`$extmk`); don't constant-fold a mutated ivar's value inside other method bodies | medium | **medium–high** (FP-validate vs Mastodon/haml) |
| **M6. `nil`-returning method then `\|\|`-guarded use** | `d = distance2(node, target)` (`return nil if node.nil?`); `if nearest.size < k \|\| d < nearest.last[0]` | ~1–2 (kd_tree) | genuine-conservative (method *can* return nil); the `\|\|` short-circuits but the engine doesn't relate the two | medium | low |
| **M7. Toplevel-`def` cross-file resolution** | each script's own `def traverse` | 22 `unresolved-toplevel` warnings | **EXCUSED** — `pre_eval:` / script idiom, not library code | n/a | n/a |

## Ivar mechanism radius (decides the queued ivar definite-assignment ADR)

**This is the load-bearing section for the user's trustworthiness
criterion**: the node-ivar nilable read (M1+M2) is, by a wide margin, the
dominant general-code FP across all four corpora.

- **Radius: 109 of 116 total possible-nil errors (94 %)** are node-field
  reads — `algorithms` 31/32, `Ruby` 0/0, `ADSR` 11/13, `DSAR` 67/71. The
  Ruby repo's **zero** is the control: it has no node classes (toplevel
  array functions only), and it has zero node-ivar possible-nil. The
  mechanism tracks data-structure density exactly.
- **Root cause (probed, not assumed).** `rigor type-of` on
  `rb_tree_map.rb` `r = @right` → `Dynamic[top]?`. The node class does
  `attr_accessor :left, :right` and `@left = nil` / `@right = nil` in
  `initialize` (or `self.left = nullNode` with `nullNode` untyped). The
  accessor read therefore carries BOTH a `nil` constituent (from the
  ctor/`left=` writes) and a `Dynamic[top]` value (untyped/cross-method
  join). The `nil` constituent is what fires possible-nil on the
  ubiquitous `r.key`, `node.left.colour`, `current.next` reads inside
  rotations and traversals — code that runs because the caller has
  *already* established the child is present (a left-rotate is only
  invoked when `@right` is non-nil), but no intraprocedural proof exists.
- **Why it is the canonical "cross-method ivar definite-assignment" ADR
  case.** This is the stdlib-survey C2 mechanism, but where C2 surfaced as
  rare `argument-type-mismatch`/`return-type-mismatch` on a handful of
  stdlib ivars, here it is the **primary FP class** on the most idiomatic
  Ruby data-structure code there is. The stdlib survey already landed the
  FP-safe *literal-write* subset (`dead_transient_nil_writes`) and
  measured it at **zero radius** on real code, deferring the real fix
  ("intraprocedural definite-assignment over ivars, incl. cross-method
  write-effect summaries") behind an ADR. **This corpus is the
  justification that ADR was waiting for**: 109 FPs on running textbook
  code, the single biggest dent in Rigor's general-code trustworthiness
  measured to date.
- **What the ADR must handle** (read off these sites): (a) `@x = nil` in
  `initialize` + later non-nil writes via `self.x =` / `attr_accessor`
  writer, joined flow-insensitively — needs a definite-assignment /
  declared-type view that doesn't fold the defensive `nil` into every
  read; (b) the node field is *legitimately* sometimes nil (leaf
  children) — so a blanket "ivars are never nil" rule is **unsound**; the
  fix must be narrowing-driven (relate the read to a guard / the
  cross-method established-non-nil context) or a declared-type that keeps
  nil but lets a local `if node.left` / loop-exit guard narrow it. FP-risk
  is **medium**, not low — this is why it needs an ADR, not a patch.

## Ranked attack order (weighted by general-code trustworthiness)

The user's criterion: a plain `node = node.next` loop or a textbook
quicksort falling to Dynamic/FP is top priority; metaprogramming is
excused. So the order is **FP-on-running-textbook-code first**, Dynamic
precision second, excused/needs-RBS last.

1. **M1+M2 — node-ivar definite-assignment (the queued ivar ADR).** 109
   FPs (94 % of all possible-nil) on the most idiomatic data-structure
   code. This corpus *justifies the deferred ivar definite-assignment ADR*
   — that is the single highest-value general-code trustworthiness move
   available. Engine, high difficulty, medium FP-risk → ADR-gated.
2. **M4 — extend non-empty-array narrowing to `count`/`size` comparisons.**
   `arr.last`/`first` after `if arr.count > 0` / `arr.size > 0` should
   narrow non-nil, reusing the existing `empty?`/`any?` non-empty
   refinement. Low difficulty, low FP-risk, removes a clean FP slice; a
   cheap independent win.
3. **M5 — stop constant-folding a mutated ivar's value inside other
   method bodies** (`if @size == 1` always-falsey). 14 always-truthy
   FPs; same family as stdlib C5. Medium difficulty, **medium–high
   FP-risk → FP-validate against Mastodon/haml first** (per the stdlib
   note's standing caveat).
4. **M6 — `nil`-return then `||`-guarded use** narrowing. Small radius
   (~2), low FP-risk; nice-to-have.
5. **M3 — untyped-param → whole-method Dynamic: EXCUSED, do not pursue.**
   This is the largest *coverage* contributor (it sets the 0.33–0.40 floor
   on every unannotated sort), but it is correct gradual-typing behaviour
   — the program supplies no signature. Pursuing it would mean inferring
   param types from bodies/call-sites (a separate, large initiative), not
   pruning a trustworthiness gap. Leave.
6. **M7 toplevel-`def` resolution, OpenStruct arity, parse errors,
   C#-in-`.rb`, dead-assignment catches: EXCUSED / NEEDS-RBS / GENUINE.**
   No engine slice. The dead-assignment and C#-file diagnostics are
   correct catches worth keeping.

**Headline.** Across four near-metaprogramming-free corpora the precise
picture is binary: **node-ivar nilable reads (M1/M2) are 94 % of the FP
surface and the entire trustworthiness story**, and they are exactly the
cross-method ivar definite-assignment case the stdlib survey deferred
behind an ADR. Everything else is either excused gradual-typing
(untyped-param Dynamic), a cheap independent narrowing win (M4
`count`-guarded non-empty), or correct catches (dead code, C# pasted into
Ruby, broken scripts). The ivar ADR is justified.
