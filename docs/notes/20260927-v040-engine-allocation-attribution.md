# The v0.3.9 → v0.4.0 engine allocation cost, attributed per merge (2026-09-27)

Status: measurement record for [#1469](https://github.com/rigortype/rigor/issues/1469). Nothing in
`lib/` was changed to measure. Four follow-ups were filed to milestone v0.4.x
([#1502](https://github.com/rigortype/rigor/issues/1502)–[#1505](https://github.com/rigortype/rigor/issues/1505)).
The harness is on the unmerged branch `allocation-attribution-1469-harness` (`tool/perf1469/`).
Predecessors: [`20260908-v037-allocation-regression-attribution.md`](20260908-v037-allocation-regression-attribution.md)
(the same question for v0.3.6..v0.3.7) and #1046 (the early part of this range, through #1036).

## The question

At the v0.4.0 cut the release-gate baseline was recalibrated to +80.5% allocations on `lib`. Most
of that rise is corpus growth, since Rigor's own `lib` grew 26%. Holding the corpus fixed at the
v0.3.9 tree, the v0.4.0 engine still allocates +19.1% more than the v0.3.9 engine, and #1469 asks
which merges pay for it. #1046 had looked at the early part of the range, but on a different axis:
it ran each merge over its own growing `lib`, so corpus growth is inside its numbers, and its +6.8%
is the figure after #1045. On this note's frozen axis the same stretch is +12.0% through #1036
(`81133b8a`, 26,555,627, with #1035's bug still in) and +2.66% once #1045 lands (`22f5a1a7`,
24,336,177).

## Method

- **Frozen corpus.** `git archive v0.3.9` unpacked to a scratch directory, the main clone's
  `vendor/` symlinked into it, and `.bundle/config` copied. Every arm runs with that directory as
  cwd and `lib` as the target, so the configuration (`plugins: []`) and `sig/` are v0.3.9's for
  every engine.
- **One engine per first-parent commit.** Each arm is `git archive <sha> lib sig plugins data exe`.
  `lib/rigor` reads `data/` and `plugins/` from beside itself, through `ENGINE_ROOT` and the
  `../../../data` paths. Of the 255 first-parent commits in `v0.3.9..v0.4.0`, 183 change `lib/`,
  `plugins/` or `data/`: 182 merges and one direct commit (`c56c2ccf`). All 183 were measured. The
  other 72 carry the previous arm's engine byte for byte. The bundle is master's for every arm. Within
  the range, `Gemfile.lock` moves RuboCop 1.90.0 → 1.91.0 with its dependencies json 2.21.2 → 3.0.2
  and parallel 2.1.0 → 2.2.0, plus the version bump. Every arm runs on the v0.4.0 set, so no step
  here includes a gem change.
- **A fresh process per arm.** The process puts the arm's `lib` first on `$LOAD_PATH`, requires
  `rigor/cli`, and calls `Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json",
  "lib"]).run` in-process, the same way `tool/bench.rb` does. It reads the
  `GC.stat(:total_allocated_objects)` delta and the diagnostic count, and prints
  `$LOADED_FEATURES` to prove which engine loaded. The only feature from another root is the main
  clone's `rigor/version.rb`, which bundler's gemspec loads before the arm and the arm then
  redefines. Every arm ran sequentially, in the foreground, and exited 0.
- **Calibration.** The v0.3.9 arm allocated 23,705,247 objects, against a known local anchor of
  23,710,878 (−0.02%). The v0.4.0 arm (`07f49bdb`) allocated 28,238,280, against 28,235,304
  (+0.01%). The sweep's total step is +4,533,033 (+19.12%), matching #1469's +19.1%.
- **Attribution inside a step.** A second driver (`tp.rb`) runs the same check under a
  `TracePoint(:call, :return)`. For every Ruby method it records the allocations made while that
  method was the innermost Ruby frame, which includes C calls such as `Array#map` that the method
  makes, and it records the method's call count. The driver's own allocations are subtracted, and its
  totals reproduce the sweep to within 5K objects per arm. Diffing two arms method by method names
  where a step's objects are allocated. It was run on the parent and merge arms of ten of the largest
  positive steps, and on v0.3.9 and v0.4.0. The split between an iterator and its caller in this
  trace depends on YJIT (see Limitations), so the #1166 pair was traced again with
  `RIGOR_DISABLE_YJIT=1`.
- **Levers.** Each suspected accidental cost was prototyped in a scratch copy of the v0.4.0 arm and
  measured on its own and then combined, with the `--format json` output compared byte for byte to
  the unpatched arm. Nothing was landed.

Diagnostics held at 1 on every arm: the corpus's only finding is the `rbs.coverage.missing-gem`
info. So no step in this range is explained by a diagnostic change, and the byte-identity check on
the prototypes is weak (see Limitations). Arms whose engines differ only off the check path land within a few
dozen objects of each other (`4c48106c`, `79ef2ae2` and `02bc9467` read 28,316,964–28,316,977), which
bounds the noise floor. Re-running the prototype arms moved them by 43–802 objects. The
`call_arg_types`, block-entry and `mutated_receiver` levers (pB, pC and pE in the harness) moved by
405–486, more than that floor. The union-order lever's 802 (pD) comes from its `WeakMap` memo,
whose hit rate depends on GC timing. Every such move is under 0.003%, and none of them changes a conclusion.
Wall was one sample per arm, taken while other lanes ran on the host, and is recorded only.

## Where the +4.53M went

| bucket | steps | net Δ |
| --- | ---: | ---: |
| steps ≥ +100K | 19 | +6,170,085 |
| steps ≤ −100K ([#1045], [#1441], [#1453]) | 3 | −2,611,875 |
| 20K ≤ \|Δ\| < 100K | 21 | +741,346 |
| \|Δ\| < 20K | 140 | +233,477 |
| **total** | **183** | **+4,533,033** |

The [#1035] / [#1045] pair nets to −253, because #1045 fixed exactly what #1035 added. Without that
pair, the +4.53M is 18 positive steps of +100K or more (+3.94M), two paybacks (−0.38M), and a long
tail. Most of the step sizes are one feature doing more inference on purpose, but four of the
eleven largest positive steps carry a cost that the feature does not need.

### The largest steps, and what the trace says

| merge | PR | Δ | where the objects are (exclusive, traced) | verdict |
| --- | --- | ---: | --- | --- |
| `b5af5cf7` | [#1135] Sorbet annotation DSL | +720,553 | `ScopeIndexer.rebound_self_base` is a new method taking 542,519 allocations over 972,530 calls. Three walks call it for every AST node they visit, and it splits a String self owner on `::`, but the result is read only under a `class_eval`-style call with a block. A per-caller probe puts 523,300 of the allocations under `walk_mixin_call_children` (143,880 calls; `scope_indexer.rb` ~:5755), 19,222 under the publication census (562,796 calls), and none under `walk_constant_write_children`, whose owner there is never a String on this corpus. It is a String inside a `class_eval` body. The other ~178K is diffuse. The largest rows are `RbsDispatch.allowed_rbs_complete_extended_module` +32,096, `record_deferred_def` +25,626, `meta_new_child_prefix` +18,080, `nesting_lexical_prefix` +16,029, `fold_per_file_extends` +13,728, `Prism::Node#location` +13,275, `Scope#def_shadows_call?` +12,502, `decl_body_context` +12,025 and `record_collected_method_def` +11,626. | **542K accidental** ([#1502]); the rest inherent |
| `b587a70e` | [#1096] `-> self` keeps receiver type args | +507,162 | Rendering: `DataInstance#describe` +66.6K, `Constant#describe` +60.6K (+60.9K calls), `HashShape#render_entry` +60.2K, `Tuple#describe` +20.2K, `nominal_of` +39.2K, `sort_members` +36.1K, `unique_members` +26.1K. More precise receivers make more and wider unions. `Combinator.sort_members` orders each one by re-rendering every member's `describe` string, which is one path into these methods (not measured separately per step). | inherent volume at a **systemic cost** ([#1505]) |
| `66177b9c` | [#1166] `**h` shapes and `...` at the call site | +402,739 | With YJIT on, `ExpressionTyper#call_arg_types` +262K and `Array#each` +193K, less `Array#map` −127K. With `RIGOR_DISABLE_YJIT=1`, `call_arg_types` alone is +321,006 on unchanged call counts (292,850 → 293,796), so its allocations per call roughly double; the other ~82K is spread thin. The `map` became a `flat_map` that wraps each argument's type in a one-element Array, for the sake of `...` alone. | **accidental** ([#1503]) |
| `11455d5c` | [#1103] destructure `Array[T]` block params | +294,385 | `BlockParameterBinder#reset_per_bind_state` +133K, which runs twice per bind, `MultiTargetBinder::Result#apply_to` +132K, and `bind_onto` +97K. The old entry path saves −76K. | **accidental plumbing** ([#1504]) |
| `54f120d9` | [#1129] composite receiver per projected member | +249,066 | Dispatch volume: `CallContext.build` +58K on +19.4K calls, union algebra ~+40K, `try_composite_receiver` 11.7K over 177K calls. | inherent; the per-dispatch `CallContext` cost is #150 / #820 |
| `9b54f41e` | [#1441] | −239,994 | payback | |
| `b73747d6` | [#1020] value-position `and`/`or` narrowing | +226,945 | Statement-evaluator volume: `Scope#join_bindings` +51.5K on +24K calls, `join_with_nil_injection` +30.4K, `Scope#type_of` +13.9K. | inherent, as #1046 found |
| `2b26e4f9` | [#1015] ternary predicate narrowing | +175,049 | The same shape as #1020: `join_bindings` +32K, `join_with_nil_injection` +17K, `sub_eval` +11K. | inherent |
| `0765b45b` | [#1178] calls through included RBS modules | +165,737 | `RbsDispatch.included_module_method` 50.8K over 100,911 calls; `each_source_ancestor_candidate` +39.6K (6.5 per call); `ExternalAncestorResolution.compute` now runs twice per question (4,893 → 9,786 calls, +19.6K). | inherent; a memo of the doubled `compute` is worth about 35K, below the filing bar |
| `40a08499` | [#1114] ivar destructuring targets | +142,735 | `Result#apply_to` +101.5K, from four `reduce`s, three of them over empty collections, and `Result#initialize` +53K, from a keyword re-splat. | **accidental plumbing** ([#1504]) |
| `faae6273` | [#1111] rigor-grape | +140,463 | Diffuse: more block bodies are typed as methods (`CallContext.build` +14K, `Scope#type_of` +9.5K, …). The plugin itself is not loaded, because `plugins: []`. | inherent |
| `f7935458` | [#1453] | −136,961 | payback | |
| `6a0bb52c` | [#1250] | +135,013 | not traced | |
| `7e42c48f` | [#1301] | +129,303 | Not traced per step. The whole-range trace shows the `Scope#shadowing_constant_names` it adds at 99,805 allocations over 81,005 calls, a `split("::")` per qualified constant reference. | small lever, noted on [#1502] |

The remaining steps of +100K or more were not traced: [#1006] +111,608 (`tuple_absorbed_by?`,
accepted in #1046), [#1010] +111,093 (trim tracked in #1077), [#1310] +109,400, [#1243] +107,131,
[#1159] +105,924 and [#1104] +101,112. In the tail, [#1112] adds
`BlockAutoSplat::ParameterShape.of` (75.6K at v0.4.0), and [#1203] adds
`CapturedLocals.mutated_receiver`. Its `when *INDEX_STORE_NODES` arm copies an Array per call:
125,609 allocations at v0.4.0, over call volume that later merges raised. That is the same #1035
shape, and it is folded into [#1502].

## What is recoverable

Prototype levers on the v0.4.0 engine, frozen v0.3.9 `lib` (28,238,280 unpatched). The figures are
from each lever's first run. The re-run result lines are in the harness's
`tool/perf1469/prototypes/results.jsonl`, and they differ by at most 802 objects (see Method):

| lever | issue | allocations | Δ |
| --- | --- | ---: | ---: |
| split the self owner only where `eval_receiver_self` reads it | [#1502] | 27,695,758 | −542,522 |
| `mutated_receiver` without the `when *` splat | [#1502] | 28,112,239 | −126,041 |
| `call_arg_types` maps unless the list ends in `...` | [#1503] | 27,922,890 | −315,390 |
| block-entry plumbing: `each` loops, lazy optimistic arrays, no `Result` round trip | [#1504] | 27,772,456 | −465,824 |
| union order by a memoised per-instance key, with a two-member fast path | [#1505] | 27,199,245 | −1,039,035 |
| **all five** | | **25,750,636** | **−2,487,644 (−8.8%)** |

On the v0.4.0 tree's own `lib`, the corpus the release gate measures, all five together take the
v0.4.0 engine from 42,940,599 to 39,120,227 (−3.82M, −8.9%). The output is byte-identical on both
corpora. That base is +0.40% over the 42.77M in #1469, because the two measure different trees. The
42.77M was a local measurement of the release branch at `665440d8`, the first version-bump commit,
before #1470, #1478, #1479 and #1483 landed on it. The committed baseline, 42,721,526, is the Linux release-gate
run 36278383180 on that same commit. The release head `6503cd49` measured 42,895,332 on Linux
(release-gate run 36286123530). The arm here, `07f49bdb`, merges that head, and 42,940,599 is
+0.10% over it.

The first four are the accidental share of this range: about −1.45M together, a third of the
+4.53M. After them, the engine's cost over v0.3.9 on the frozen corpus drops from +19.1% to about
+13%. That remainder is the inference the v0.4.0 line bought on purpose (narrowing through the
statement evaluator, per-member dispatch, ancestor and module resolution, destructuring), plus the
union-ordering cost those features amplify. The fifth lever is a design choice rather than a
mechanical removal, and it predates the range. At v0.4.0, `sort_members` costs 1,419,145
allocations inclusive, 5.0% of the run, over 163,939 calls and 617,243 members. The prototype
recovers −1,039,035 of that. It is filed `ready-for-human`. With all five, the frozen-corpus cost over
v0.3.9 would be +8.6%.

## Wall

The per-arm wall rose from 14.5 s at v0.3.9 to 21.7 s at v0.4.0 (+49%, one sample each). The rise
is not monotone across the sweep, and its later arms overlapped other lanes' `make verify-changed`
runs, so none of it is attributed here. The prototypes' walls (18.4–24.0 s) sit inside the same
noise. Deciding a wall question needs alternated repeated samples on a quiet host
(`docs/agents/measurement.md`, "A phased A/B confounds phase with treatment").

## Limitations

- **Output equality is weak evidence here.** The frozen corpus and the v0.4.0 `lib` each produce a
  single info diagnostic, so "byte-identical" rules out a crash or a new finding and little else.
  Each filed issue's gate asks for the survey-corpus diff.
- **The trace attributes to the innermost Ruby frame, and that frame depends on YJIT.** A method
  that calls a C iterator absorbs the iterator's allocations. `Array#map` and `Array#each` are
  implemented in Ruby only when YJIT is enabled (`array.rb`'s `with_jit` block), and Rigor enables
  YJIT after a 5 s deadline (`CLI#arm_jit_deadline`, `lib/rigor/runtime/jit.rb`). On a loaded host
  the point where YJIT turns on moves from run to run. When it is on, `Array#map` and `Array#each`
  appear as their own Ruby frames, and they take allocations that would otherwise be charged to the
  caller. So an iterator-versus-caller split can differ between the two arms of a step. Only the
  #1166 pair was re-traced with `RIGOR_DISABLE_YJIT=1`. For the other steps, read an `Array#…` row
  and its callers' rows together. In the same way, a block passed to a Ruby-level iterator (for
  example `rigor_each_child`) charges its allocations to the iterator. A refactor that renames or
  moves a method shows as a matched ± pair. Between v0.3.9 and v0.4.0 there are three:
  `with_local` → `bind_local`, `sub_eval` → `evaluator_at` and `select_candidates` →
  `select_declared`. The per-arm totals do not depend on any of this: YJIT on and off agree to
  within 55 objects on both #1166 arms.
- **Eight steps of +100K or more were not traced per step** ([#1250], [#1301] and the six listed
  after the table). Each is +101K to +135K, and all eight together are 0.91M. The steps sum to the
  total by construction, so nothing in the range is unmeasured, only unexplained at the method
  level.
- **The inclusive `sort_members` figure was corrected before merge.** The first probe counted its
  own per-member tally inside the measured window and reported 4,505,381. The tally now runs
  outside the window, and the figure is 1,419,145.
- **The harness** is on `allocation-attribution-1469-harness` under `tool/perf1469/`. It holds:
  - the sweep driver and the fresh-process measure script;
  - the TracePoint tracer and its diff;
  - the raw per-arm results, including the v0.3.9 base arm and its load-path proof;
  - the gzipped per-method traces;
  - the inclusive-probe output;
  - the five prototype diffs and their measured result lines.

  Its scripts hard-code the scratch paths they ran from.

## The full series

Allocations for `rigor check --no-cache lib` over the frozen v0.3.9 tree, one row per
engine-changing first-parent commit of `v0.3.9..v0.4.0`, in first-parent order. Δ is against the
previous row. "diags" is the JSON diagnostic count, and wall is a single sample.

| # | merge | PR | allocations | Δ | diags | wall s | title |
| ---: | --- | --- | ---: | ---: | ---: | ---: | --- |
| 0 | `d0c370f7` (v0.3.9) | | 23,705,247 | | 1 | 14.49 | the base engine |
| 1 | `be73e08d` | [#999] | 23,717,840 | +12,593 | 1 | 15.28 | Check arity against a source-defined method's own signature |
| 2 | `d32ad0d9` | [#1005] | 23,717,964 | +124 | 1 | 16.27 | Distinguish an unresolvable inline type name from a duplicate one |
| 3 | `e747d0d5` | [#1000] | 23,717,935 | −29 | 1 | 15.72 | Propose the inferred return for a declared-untyped method |
| 4 | `3be3d8f1` | [#1001] | 23,717,909 | −26 | 1 | 15.01 | Project Integer#to_s / Float#to_s to numeric-string refinements |
| 5 | `4d6ac321` | [#1006] | 23,829,517 | +111,608 | 1 | 15.45 | Absorb a union arm that another arm contains element-wise |
| 6 | `4922fb7f` | [#1010] | 23,940,610 | +111,093 | 1 | 16.48 | Arity-check a method the project defines in source and declares nowhere |
| 7 | `bc9808fa` | [#1012] | 23,941,131 | +521 | 1 | 16.49 | Key the synthesizer and plugin-producer caches on the engine source |
| 8 | `caa258dc` | [#1013] | 23,941,147 | +16 | 1 | 14.55 | Narrow to_s(base) and regex hex/octal producers to non-empty-string |
| 9 | `2b26e4f9` | [#1015] | 24,116,196 | +175,049 | 1 | 16.32 | Narrow a value-position conditional through the statement evaluator |
| 10 | `5922448f` | [#1018] | 24,116,423 | +227 | 1 | 17.73 | Read the same-line %a{} inline annotation forms |
| 11 | `5b3a8196` | [#1022] | 24,092,922 | −23,501 | 1 | 16.59 | Treat a union with an untyped member as imprecise in overload selection |
| 12 | `b73747d6` | [#1020] | 24,319,867 | +226,945 | 1 | 18.08 | Narrow a value-position and/or through the statement evaluator |
| 13 | `826bef9f` | [#1023] | 24,319,933 | +66 | 1 | 15.81 | Report the two inline-RBS spellings the reader still drops silently |
| 14 | `256a34ef` | [#1024] | 24,320,082 | +149 | 1 | 14.92 | Narrow through a conditional used as a condition |
| 15 | `638959cb` | [#1031] | 24,320,167 | +85 | 1 | 15.27 | Key the rbs.* producer caches on the engine source |
| 16 | `323e696d` | [#1032] | 24,320,147 | −20 | 1 | 22.98 | Render a project-declared RBS alias instead of its expansion |
| 17 | `839bcbc2` | [#1029] | 24,320,554 | +407 | 1 | 20.8 | Decline a compact-header rename collision the two crefs disagree about |
| 18 | `02d96189` | [#1030] | 24,320,862 | +308 | 1 | 16.0 | Model a define_method block's self as the class instance |
| 19 | `aa98a7d9` | [#1034] | 24,320,877 | +15 | 1 | 16.18 | Fold a concern's included-block scopes into the including model |
| 20 | `dd029e0e` | [#1035] | 26,555,544 | +2,234,667 | 1 | 14.82 | Route the .freeze and \|\|= constant spellings to the meta-constant handler |
| 21 | `81133b8a` | [#1036] | 26,555,627 | +83 | 1 | 15.56 | Write %a{pure} and effect envelopes from sig-gen |
| 22 | `6e4929d3` | [#1037] | 26,571,097 | +15,470 | 1 | 15.28 | Revive the ADR-16 Tier-D seam as template units |
| 23 | `22f5a1a7` | [#1045] | 24,336,177 | −2,234,920 | 1 | 15.15 | Spell the meta-constant write arms out instead of splatting the list |
| 24 | `7eb23692` | [#1044] | 24,336,647 | +470 | 1 | 14.54 | Add rigor-active-model-serializers plugin (object recognizer) |
| 25 | `0bd70a45` | [#1042] | 24,336,384 | −263 | 1 | 15.78 | Resolve a Const.new effect edge to the class's #initialize |
| 26 | `cd550f31` | [#1050] | 24,336,944 | +560 | 1 | 16.53 | Compile app/views ERB into template units in rigor-actionpack |
| 27 | `36c0e248` | [#1052] | 24,336,940 | −4 | 1 | 15.59 | Fold delegate, concern associations and attachment macros into the model index |
| 28 | `98ef7f63` | [#1054] | 24,336,533 | −407 | 1 | 14.17 | Emit a plugin's project-global disclosure once per run |
| 29 | `cd30c74b` | [#1053] | 24,336,728 | +195 | 1 | 14.21 | Carry the compiled template-unit index on ProjectScan |
| 30 | `0a586556` | [#1062] | 24,337,182 | +454 | 1 | 14.45 | Disclose the six discovery plugins' load errors once per run |
| 31 | `02f48ea4` | [#1061] | 24,337,265 | +83 | 1 | 14.28 | Stop the pool's workers dying on a class-ivar memo |
| 32 | `c03fd94d` | [#1063] | 24,337,261 | −4 | 1 | 14.17 | Let a plugin-supplied member veto the top-level def |
| 33 | `63bbfa33` | [#1057] | 24,337,791 | +530 | 1 | 15.58 | Edge a controller action to the template it renders |
| 34 | `121620ed` | [#1066] | 24,337,851 | +60 | 1 | 14.89 | Trace render-site locals, and compile layouts |
| 35 | `53edd83f` | [#1067] | 24,338,029 | +178 | 1 | 15.37 | Emit a positioned plugin batch once per run |
| 36 | `b8a6051a` | [#1068] | 24,338,112 | +83 | 1 | 14.69 | Make Ractor pool workers read only shareable constants and a parent-resolved lockfile |
| 37 | `81707d3e` | [#1070] | 24,338,304 | +192 | 1 | 15.35 | Fall back to the HTML partial a .js template really renders |
| 38 | `c22278b7` | [#1069] | 24,338,309 | +5 | 1 | 15.91 | Route rigor type-of on a template through its compiled unit |
| 39 | `b50441d8` | [#1087] | 24,338,365 | +56 | 1 | 15.65 | Pure-Ruby xxh3-64 for lens anchors |
| 40 | `f65429a0` | [#1088] | 24,338,311 | −54 | 1 | 15.62 | Add Plugin::Base#declared_members for lens member enumeration |
| 41 | `7836b2e7` | [#1091] | 24,338,374 | +63 | 1 | 16.51 | Prune redundant comments across lib, plugins, and specs |
| 42 | `b587a70e` | [#1096] | 24,845,536 | +507,162 | 1 | 16.93 | Keep the receiver's type arguments on an RBS `-> self` return |
| 43 | `11455d5c` | [#1103] | 25,139,921 | +294,385 | 1 | 15.5 | Destructure a non-tuple Array[T] into per-slot T bindings |
| 44 | `608be0a9` | [#1104] | 25,241,033 | +101,112 | 1 | 16.12 | Distribute destructuring over unions and wrap values without to_ary |
| 45 | `0c9c618f` | [#1105] | 25,241,290 | +257 | 1 | 16.47 | Drop the callee's return when an exactly-once block never completes |
| 46 | `a18e5407` | [#1112] | 25,334,725 | +93,435 | 1 | 14.91 | Auto-splat numbered block parameters as their explicit list |
| 47 | `1b916f3b` | [#1115] | 25,355,251 | +20,526 | 1 | 16.96 | Unload the rbs gem's unsound Enumerable#each_slice shim |
| 48 | `7bf685df` | [#1113] | 25,337,302 | −17,949 | 1 | 16.12 | Type Kernel#loop as completing when its body may raise StopIteration |
| 49 | `40a08499` | [#1114] | 25,480,037 | +142,735 | 1 | 18.39 | Destructure instance-variable targets through MultiTargetBinder |
| 50 | `ce48b4fa` | [#1106] | 25,466,796 | −13,241 | 1 | 18.99 | Type the graphql-ruby class-level DSL in rigor-graphql |
| 51 | `faae6273` | [#1111] | 25,607,259 | +140,463 | 1 | 16.09 | Add rigor-grape: type the Grape endpoint and entity DSLs |
| 52 | `9ec52001` | [#1118] | 25,607,195 | −64 | 1 | 15.42 | Bind rigor-grape `desc` blocks to the route-attribute config context |
| 53 | `4f54815b` | [#1128] | 25,611,296 | +4,101 | 1 | 15.55 | Splat block parameters over an array carrier the binder cannot decompose |
| 54 | `54f120d9` | [#1129] | 25,860,362 | +249,066 | 1 | 15.74 | Dispatch a composite receiver per projected member |
| 55 | `51a190f7` | [#1127] | 25,860,490 | +128 | 1 | 16.11 | Give the external-ancestor walk one owner |
| 56 | `e82cd076` | [#1131] | 25,953,151 | +92,661 | 1 | 17.4 | Resolve inherited calls into core and stdlib RBS |
| 57 | `9cc94876` | [#1133] | 25,953,728 | +577 | 1 | 15.75 | Bound the class-graph memo to one slot |
| 58 | `b04e538f` | [#1136] | 25,962,170 | +8,442 | 1 | 15.79 | Bound the two remaining per-file memos in ExpressionTyper |
| 59 | `72903708` | [#1142] | 26,034,437 | +72,267 | 1 | 16.06 | Read []= splice stores through the value's element types |
| 60 | `be733aab` | [#1144] | 26,034,453 | +16 | 1 | 15.7 | Tidy the XXH3 follow-ups from the #1087 review |
| 61 | `79fa99cf` | [#1159] | 26,140,377 | +105,924 | 1 | 15.45 | Block parameters share the `-> self` substitution verdict |
| 62 | `9fd4b6d4` | [#1160] | 26,140,465 | +88 | 1 | 14.95 | Edge a respond_to format arm to the template that arm renders |
| 63 | `19c2af59` | [#1161] | 26,140,368 | −97 | 1 | 17.12 | Type enum-backed column readers as the enum key, not the storage type |
| 64 | `b5af5cf7` | [#1135] | 26,860,921 | +720,553 | 1 | 16.22 | Type the Sorbet annotation DSL through bundled RBS and an extend bridge |
| 65 | `e763cf3a` | [#1163] | 26,898,811 | +37,890 | 1 | 15.79 | Keep Enumerator::Lazy lazy through a chained call |
| 66 | `66177b9c` | [#1166] | 27,301,550 | +402,739 | 1 | 16.33 | Read a double-splatted hash shape and `...` at the call site |
| 67 | `c5487a37` | [#1164] | 27,302,277 | +727 | 1 | 15.78 | Bind `case/in` pattern names against the case subject |
| 68 | `a8396ced` | [#1165] | 27,321,772 | +19,495 | 1 | 16.31 | Order a prepended module ahead of the class it is prepended into (#1123) |
| 69 | `594e54f6` | [#1176] | 27,324,014 | +2,242 | 1 | 15.95 | Widen nil-collapsing predicate folds on optimistic carriers to bool (#1172) |
| 70 | `0765b45b` | [#1178] | 27,489,751 | +165,737 | 1 | 16.9 | Resolve calls through a discovered class's included RBS modules |
| 71 | `e890b0dc` | [#1179] | 27,534,768 | +45,017 | 1 | 16.2 | Seed compound ivar writes in the class-ivar accumulator |
| 72 | `c56c2ccf` | [#1190] | 27,534,715 | −53 | 1 | 17.58 | sig: declare Effects::Registry and the plugin effect row classes (#1181) (#1190) |
| 73 | `908a5c9a` | [#1201] | 27,534,785 | +70 | 1 | 16.39 | Snapshot the full signature state on the pool's sequential fallback |
| 74 | `1e5695bc` | [#1206] | 27,534,944 | +159 | 1 | 16.68 | Bind captured rebinds at every pair of the HashShape transform fold |
| 75 | `ebed1e53` | [#1202] | 27,554,545 | +19,601 | 1 | 16.67 | Type a value-position index compound write as what it stores |
| 76 | `feaf058a` | [#1204] | 27,564,955 | +10,410 | 1 | 16.57 | Widen rebound instance variables under the per-element fold |
| 77 | `bda0dfda` | [#1207] | 27,603,782 | +38,827 | 1 | 17.03 | Iterate a self-reading block store's evidence to a fixpoint |
| 78 | `416e205d` | [#1203] | 27,605,834 | +2,052 | 1 | 18.7 | Widen captured locals the per-element fold mutates in place |
| 79 | `362a6a49` | [#1205] | 27,609,736 | +3,902 | 1 | 16.57 | Thread block returns through index writes in the prefix |
| 80 | `68ed39bb` | [#1209] | 27,617,323 | +7,587 | 1 | 16.71 | Widen a multi-assign index target's receiver |
| 81 | `04457555` | [#1211] | 27,617,834 | +511 | 1 | 16.07 | Widen a for-index and rescue-reference index target's receiver |
| 82 | `ed1dff20` | [#1210] | 27,617,767 | −67 | 1 | 16.41 | Carry a block's instance-variable rebinds into the continuation |
| 83 | `74970d1e` | [#1213] | 27,617,629 | −138 | 1 | 16.21 | Floor nested per-element and per-pair folds on a stale tail |
| 84 | `bf5edbb3` | [#1215] | 27,699,225 | +81,596 | 1 | 16.56 | Join a block's next and break paths into its captured rebinds |
| 85 | `15a29720` | [#1224] | 27,704,052 | +4,827 | 1 | 16.96 | Widen captured locals a rebinding block mutates in place |
| 86 | `ca80be0c` | [#1225] | 27,619,261 | −84,791 | 1 | 16.89 | Floor unthreaded rebinds in block folds and the generic block-return pass |
| 87 | `06f540ff` | [#1212] | 27,619,589 | +328 | 1 | 16.78 | Decline the HashShape transform fold on a mapping hash or a bang self-read |
| 88 | `a98bd9c8` | [#1221] | 27,652,472 | +32,883 | 1 | 17.14 | Read a block store's rebound local as Dynamic[top] |
| 89 | `1149769d` | [#1236] | 27,655,452 | +2,980 | 1 | 20.87 | Give a compound index write's [] read the call-site context |
| 90 | `52a8c086` | [#1242] | 27,655,384 | −68 | 1 | 17.77 | Decline the per-element Tuple fold on a find ifnone argument |
| 91 | `2dec06df` | [#1243] | 27,762,515 | +107,131 | 1 | 17.15 | Type a constant compound write as the value it stores |
| 92 | `bd503e93` | [#1244] | 27,766,816 | +4,301 | 1 | 17.74 | Re-answer stale tail names in the generic block-return pass |
| 93 | `91c214bf` | [#1247] | 27,767,030 | +214 | 1 | 17.67 | Join the mapping's values into transform_keys(mapping)'s key type |
| 94 | `0192519e` | [#1249] | 27,682,304 | −84,726 | 1 | 17.2 | Widen captured contents a block mutates through a slot or a callee |
| 95 | `5f2a07d8` | [#1245] | 27,683,629 | +1,325 | 1 | 17.13 | Shadow outer locals inside an unentered block's body |
| 96 | `ad70fe7d` | [#1248] | 27,698,506 | +14,877 | 1 | 16.76 | Join a loop body's next and break paths into its rebinds |
| 97 | `d61d41d4` | [#1252] | 27,711,480 | +12,974 | 1 | 17.06 | Join splatted entries into a hash literal's Hash[K, V] |
| 98 | `5e51f5e5` | [#1253] | 27,711,061 | −419 | 1 | 17.2 | List Hash#shift as a Hash mutator |
| 99 | `0c4ad0f7` | [#1255] | 27,711,078 | +17 | 1 | 17.44 | Accept provably non-empty literals against empty-witness refinements |
| 100 | `21d9fddc` | [#1254] | 27,711,093 | +15 | 1 | 19.66 | Count a Tuple or HashShape seed as pinned in the unmoved-pin floor |
| 101 | `e41a43fb` | [#1266] | 27,710,984 | −109 | 1 | 19.38 | Load Hash#transform_keys replacements overloads on rbs 3.x |
| 102 | `6a0bb52c` | [#1250] | 27,845,997 | +135,013 | 1 | 17.95 | Thread writes nested in call operands into the post-statement scope |
| 103 | `0ea5ea6e` | [#1265] | 27,846,012 | +15 | 1 | 18.25 | Fold constant-block Hash filters to an empty Hash, not an empty Array |
| 104 | `e54c4725` | [#1269] | 27,846,075 | +63 | 1 | 18.37 | Give a rewritten empty-witness refinement the gradual arm |
| 105 | `e8bfe604` | [#1261] | 27,846,749 | +674 | 1 | 18.55 | Count global, class-variable and it receivers as in-place mutations |
| 106 | `f1d1f964` | [#1274] | 27,850,133 | +3,384 | 1 | 18.88 | Give Enumerable#detect find's ifnone overloads |
| 107 | `a433a96f` | [#1275] | 27,850,321 | +188 | 1 | 18.53 | Let a record answer maybe for a Hash whose entries went unread |
| 108 | `29e634a8` | [#1273] | 27,853,782 | +3,461 | 1 | 19.78 | Leave a block-return variable untyped when a parameter names it |
| 109 | `847ec9c2` | [#1279] | 27,865,512 | +11,730 | 1 | 21.64 | Stop counting a nested scope's own local as a captured rebind |
| 110 | `47208a6f` | [#1259] | 27,864,672 | −840 | 1 | 18.12 | Carry the primary body's rebinds across the retry edge |
| 111 | `441182fa` | [#1277] | 27,916,610 | +51,938 | 1 | 19.31 | Give a straight-line rewrite its gradual arm |
| 112 | `b5942231` | [#1276] | 27,938,835 | +22,225 | 1 | 18.03 | Bind a constant compound write gradually when another file writes it |
| 113 | `4b70a574` | [#1270] | 27,941,202 | +2,367 | 1 | 18.67 | Complete the String mutator table and make it the only one |
| 114 | `be9a887f` | [#1284] | 27,941,645 | +443 | 1 | 17.97 | Pin the refinement arm's exact type under a rewrite and a reorder |
| 115 | `997ddcd3` | [#1280] | 27,946,980 | +5,335 | 1 | 18.99 | Stop reading a missing key as nil after Hash#default= |
| 116 | `8426cf99` | [#1278] | 27,961,990 | +15,010 | 1 | 20.75 | Read a computed key on a closed hash shape with its nil arm |
| 117 | `eef0de8d` | [#1294] | 27,962,107 | +117 | 1 | 20.32 | Join each side of a mixed Array \| Hash seed with its own evidence |
| 118 | `f8cce839` | [#1292] | 27,961,616 | −491 | 1 | 18.76 | Classify Hash#compare_by_identity as a receiver mutation |
| 119 | `0d6867fa` | [#1295] | 28,015,612 | +53,996 | 1 | 19.15 | Carry the optimistic mark through destructuring and safe navigation |
| 120 | `4f8d8756` | [#1296] | 28,072,549 | +56,937 | 1 | 19.06 | Widen a mutator's receiver when the mutator is an operand |
| 121 | `8c1b8f4d` | [#1293] | 28,073,160 | +611 | 1 | 19.52 | Bind a shared block-return variable to the class both sides share |
| 122 | `3f069e0e` | [#1291] | 28,073,605 | +445 | 1 | 18.42 | Stop a mutated constant's Hash or Array reading its literal contents |
| 123 | `7e42c48f` | [#1301] | 28,202,908 | +129,303 | 1 | 18.95 | Stop the constant ladder at a candidate another file writes |
| 124 | `91b83c66` | [#1303] | 28,202,991 | +83 | 1 | 21.99 | Read Enumerable#sum's return at class level |
| 125 | `33dd2ef2` | [#1307] | 28,207,091 | +4,100 | 1 | 20.0 | Include Enumerable[String] in StringIO through the core overlay |
| 126 | `efaf8675` | [#1306] | 28,207,576 | +485 | 1 | 19.1 | Count new as an allocation only on a class object |
| 127 | `1d0f8dfe` | [#1308] | 28,207,598 | +22 | 1 | 18.32 | Classify Enumerable blocks on IO, File and StringIO as non-escaping |
| 128 | `db80dfe3` | [#1309] | 28,207,608 | +10 | 1 | 17.46 | Bound Relation builders for the association proxy too |
| 129 | `07bf9cb1` | [#1310] | 28,317,008 | +109,400 | 1 | 17.36 | Type and record a later operand from the scope earlier ones left |
| 130 | `0ee3777c` | [#1312] | 28,316,986 | −22 | 1 | 18.06 | Accept the association proxy's delete_all argument |
| 131 | `4c48106c` | [#1314] | 28,316,964 | −22 | 1 | 18.9 | Name the read a Relation writer issues before its write |
| 132 | `79ef2ae2` | [#1315] | 28,316,964 | 0 | 1 | 17.97 | Declare insert, insert! and upsert on the bundled Relation |
| 133 | `02bc9467` | [#1321] | 28,316,977 | +13 | 1 | 18.79 | Type Relation#find with several ids as an Array |
| 134 | `6b008cb3` | [#1316] | 28,317,296 | +319 | 1 | 18.25 | Key an effect unit on the side Ruby defines it on |
| 135 | `2cdc9745` | [#1320] | 28,317,290 | −6 | 1 | 17.97 | Leave a singleton-class include out of the instance ancestry |
| 136 | `4240f48f` | [#1323] | 28,317,270 | −20 | 1 | 18.67 | Decline a view seed for a find that returns several records |
| 137 | `11902cb7` | [#1326] | 28,318,863 | +1,593 | 1 | 17.61 | Declare Enumerable#many? and the other missing ActiveSupport core_ext rows |
| 138 | `71c94cf9` | [#1327] | 28,318,823 | −40 | 1 | 21.14 | Type the block form of find as Enumerable#find |
| 139 | `17ff493e` | [#1328] | 28,318,556 | −267 | 1 | 29.55 | Keep the find note off a model's own self.find |
| 140 | `418089ef` | [#1330] | 28,322,013 | +3,457 | 1 | 20.87 | Declare deep_dup, the Hash aliases and core_ext/range in the ActiveSupport overlay |
| 141 | `fa4b3cbe` | [#1334] | 28,344,633 | +22,620 | 1 | 19.91 | Declare the remaining ActiveSupport 8.1 Object, String and Symbol rows |
| 142 | `f35fdd4d` | [#1331] | 28,349,170 | +4,537 | 1 | 24.9 | Keep a fold-stored slot out of the memoizing index \|\|= reading |
| 143 | `94d4a2cf` | [#1338] | 28,349,354 | +184 | 1 | 22.68 | Read an unbound variable \|\|= guard as the binding it guards |
| 144 | `028b4fd1` | [#1340] | 28,348,755 | −599 | 1 | 22.72 | Read an unbound variable &&= as the unseen binding beside its rvalue |
| 145 | `b7213d23` | [#1343] | 28,350,437 | +1,682 | 1 | 20.99 | Make the op= ivar seed independent of source order |
| 146 | `5149b656` | [#1345] | 28,350,508 | +71 | 1 | 21.5 | Probe for the Ruby::Box fix before re-exec'ing under RUBY_BOX=1 |
| 147 | `e59b7b89` | [#1349] | 28,349,784 | −724 | 1 | 23.16 | Drop the inline experimental-features flag from nix commands |
| 148 | `9a1b40ac` | [#1348] | 28,364,274 | +14,490 | 1 | 18.46 | Take a proven argument's arm in declared RBS order |
| 149 | `cdd97157` | [#1353] | 28,364,864 | +590 | 1 | 19.59 | Never prove a module or stubbed parameter out in pass 0 |
| 150 | `73bf3bfa` | [#1355] | 28,364,427 | −437 | 1 | 21.99 | Bind a bounded method type variable to the widened argument |
| 151 | `4c6ae438` | [#1370] | 28,394,414 | +29,987 | 1 | 23.31 | Forget the $~ narrowing a block or closure in the frame may rebind |
| 152 | `56ba5aad` | [#1354] | 28,410,302 | +15,888 | 1 | 19.86 | Select by a narrow Dynamic facet's members, not its wrapper |
| 153 | `6cd8395a` | [#1374] | 28,410,777 | +475 | 1 | 18.55 | Keep the $~ narrowing across a call into a Ruby-defined method |
| 154 | `acce26ba` | [#1378] | 28,411,363 | +586 | 1 | 19.17 | Read a call's match rebinding by what it calls and its operands' types |
| 155 | `d7a65e91` | [#1391] | 28,411,377 | +14 | 1 | 21.17 | Drop nil from min_by / max_by on a non-empty receiver |
| 156 | `0c8a7356` | [#1396] | 28,396,594 | −14,783 | 1 | 20.95 | Keep a local's declaration mark across an in-place mutation |
| 157 | `f946c3b9` | [#1390] | 28,396,707 | +113 | 1 | 18.24 | Credit block returns in sig-gen and annotate return types |
| 158 | `78dba449` | [#1395] | 28,396,743 | +36 | 1 | 18.15 | Declare test roots with a test_paths: key; sig-gen observes them instead of a hard-coded s… |
| 159 | `79e66699` | [#1392] | 28,396,852 | +109 | 1 | 30.58 | Enter thread, fiber and define_method blocks with the match globals unbound |
| 160 | `96e38343` | [#1401] | 28,397,243 | +391 | 1 | 20.11 | Record a marked binding's miss answer beside its mark |
| 161 | `327accfd` | [#1404] | 28,397,101 | −142 | 1 | 22.8 | Let a closed record answer maybe for an open hash shape |
| 162 | `d5439363` | [#1409] | 28,397,675 | +574 | 1 | 20.58 | Count an attr writer declaration as a write to its ivar |
| 163 | `b08656ec` | [#1405] | 28,417,800 | +20,125 | 1 | 18.79 | Treat $_ as frame-local and narrow it on a reader condition |
| 164 | `698604d1` | [#1414] | 28,417,593 | −207 | 1 | 22.23 | Amend ADR-2: a dynamic_return answer outranks the RBS return |
| 165 | `4c9161a6` | [#1419] | 28,417,742 | +149 | 1 | 20.44 | Floor a mutated constant's literal shape to its gradual nominal |
| 166 | `23216d66` | [#1420] | 28,515,772 | +98,030 | 1 | 19.32 | Treat a catalogued iterator on an unclassified receiver as repeating |
| 167 | `577aacb3` | [#1428] | 28,516,630 | +858 | 1 | 20.21 | Compare sig/ and inline declarations of one member (ADR-112 WD5) |
| 168 | `7d6da46a` | [#1425] | 28,580,034 | +63,404 | 1 | 18.75 | Bind $! and $@ in rescue clauses and $? after a subprocess |
| 169 | `5c76d7e8` | [#1424] | 28,582,914 | +2,880 | 1 | 20.31 | Scope refinement methods to their lexical using |
| 170 | `ed93188b` | [#1422] | 28,582,832 | −82 | 1 | 20.77 | Write inline-declared members to sig/ and add sig-gen --check |
| 171 | `42871afd` | [#1434] | 28,582,863 | +31 | 1 | 22.21 | Bind a (?) method's parameters to Dynamic[top] instead of crashing |
| 172 | `904d371f` | [#1438] | 28,583,783 | +920 | 1 | 18.8 | Declare Process.last_status and read $? through it |
| 173 | `d155a706` | [#1433] | 28,595,092 | +11,309 | 1 | 17.13 | Join a builtin global's declared type into its program-global seed |
| 174 | `0c89c2f8` | [#1442] | 28,595,609 | +517 | 1 | 17.06 | Stop labelling frame-local special-variable writes as global effects |
| 175 | `7e48c870` | [#1444] | 28,595,488 | −121 | 1 | 20.5 | Require DeclarationSourcedGuard where the evaluator uses it |
| 176 | `9b54f41e` | [#1441] | 28,355,494 | −239,994 | 1 | 18.28 | Lay the content-mutation widening on every repeating body's entry |
| 177 | `a690a612` | [#1449] | 28,356,870 | +1,376 | 1 | 18.43 | Narrow $_ on an implicit-self gets unless the file shows another self |
| 178 | `407bd3ec` | [#1448] | 28,366,677 | +9,807 | 1 | 23.02 | Report writes a special global's setter rejects |
| 179 | `f7935458` | [#1453] | 28,229,716 | −136,961 | 1 | 20.73 | Narrow global and constant receivers under guards, and keep disjoint class guards off unre… |
| 180 | `bbaed629` | [#1470] | 28,230,522 | +806 | 1 | 20.32 | Fold a constant slice of the proven $~ to a Tuple, and fix the match narrowing it reads |
| 181 | `4e630c9e` | [#1479] | 28,237,825 | +7,303 | 1 | 19.65 | Read a safe-navigation call's arguments and block with the receiver non-nil |
| 182 | `493c4269` | [#1483] | 28,237,843 | +18 | 1 | 19.45 | Keep the declared parameters in a sig-gen tighter-return proposal |
| 183 | `07f49bdb` | [#1490] | 28,238,280 | +437 | 1 | 21.66 | Bump up version to 0.4.0 |

[#999]: https://github.com/rigortype/rigor/pull/999
[#1000]: https://github.com/rigortype/rigor/pull/1000
[#1001]: https://github.com/rigortype/rigor/pull/1001
[#1005]: https://github.com/rigortype/rigor/pull/1005
[#1006]: https://github.com/rigortype/rigor/pull/1006
[#1010]: https://github.com/rigortype/rigor/pull/1010
[#1012]: https://github.com/rigortype/rigor/pull/1012
[#1013]: https://github.com/rigortype/rigor/pull/1013
[#1015]: https://github.com/rigortype/rigor/pull/1015
[#1018]: https://github.com/rigortype/rigor/pull/1018
[#1020]: https://github.com/rigortype/rigor/pull/1020
[#1022]: https://github.com/rigortype/rigor/pull/1022
[#1023]: https://github.com/rigortype/rigor/pull/1023
[#1024]: https://github.com/rigortype/rigor/pull/1024
[#1029]: https://github.com/rigortype/rigor/pull/1029
[#1030]: https://github.com/rigortype/rigor/pull/1030
[#1031]: https://github.com/rigortype/rigor/pull/1031
[#1032]: https://github.com/rigortype/rigor/pull/1032
[#1034]: https://github.com/rigortype/rigor/pull/1034
[#1035]: https://github.com/rigortype/rigor/pull/1035
[#1036]: https://github.com/rigortype/rigor/pull/1036
[#1037]: https://github.com/rigortype/rigor/pull/1037
[#1042]: https://github.com/rigortype/rigor/pull/1042
[#1044]: https://github.com/rigortype/rigor/pull/1044
[#1045]: https://github.com/rigortype/rigor/pull/1045
[#1050]: https://github.com/rigortype/rigor/pull/1050
[#1052]: https://github.com/rigortype/rigor/pull/1052
[#1053]: https://github.com/rigortype/rigor/pull/1053
[#1054]: https://github.com/rigortype/rigor/pull/1054
[#1057]: https://github.com/rigortype/rigor/pull/1057
[#1061]: https://github.com/rigortype/rigor/pull/1061
[#1062]: https://github.com/rigortype/rigor/pull/1062
[#1063]: https://github.com/rigortype/rigor/pull/1063
[#1066]: https://github.com/rigortype/rigor/pull/1066
[#1067]: https://github.com/rigortype/rigor/pull/1067
[#1068]: https://github.com/rigortype/rigor/pull/1068
[#1069]: https://github.com/rigortype/rigor/pull/1069
[#1070]: https://github.com/rigortype/rigor/pull/1070
[#1087]: https://github.com/rigortype/rigor/pull/1087
[#1088]: https://github.com/rigortype/rigor/pull/1088
[#1091]: https://github.com/rigortype/rigor/pull/1091
[#1096]: https://github.com/rigortype/rigor/pull/1096
[#1103]: https://github.com/rigortype/rigor/pull/1103
[#1104]: https://github.com/rigortype/rigor/pull/1104
[#1105]: https://github.com/rigortype/rigor/pull/1105
[#1106]: https://github.com/rigortype/rigor/pull/1106
[#1111]: https://github.com/rigortype/rigor/pull/1111
[#1112]: https://github.com/rigortype/rigor/pull/1112
[#1113]: https://github.com/rigortype/rigor/pull/1113
[#1114]: https://github.com/rigortype/rigor/pull/1114
[#1115]: https://github.com/rigortype/rigor/pull/1115
[#1118]: https://github.com/rigortype/rigor/pull/1118
[#1127]: https://github.com/rigortype/rigor/pull/1127
[#1128]: https://github.com/rigortype/rigor/pull/1128
[#1129]: https://github.com/rigortype/rigor/pull/1129
[#1131]: https://github.com/rigortype/rigor/pull/1131
[#1133]: https://github.com/rigortype/rigor/pull/1133
[#1135]: https://github.com/rigortype/rigor/pull/1135
[#1136]: https://github.com/rigortype/rigor/pull/1136
[#1142]: https://github.com/rigortype/rigor/pull/1142
[#1144]: https://github.com/rigortype/rigor/pull/1144
[#1159]: https://github.com/rigortype/rigor/pull/1159
[#1160]: https://github.com/rigortype/rigor/pull/1160
[#1161]: https://github.com/rigortype/rigor/pull/1161
[#1163]: https://github.com/rigortype/rigor/pull/1163
[#1164]: https://github.com/rigortype/rigor/pull/1164
[#1165]: https://github.com/rigortype/rigor/pull/1165
[#1166]: https://github.com/rigortype/rigor/pull/1166
[#1176]: https://github.com/rigortype/rigor/pull/1176
[#1178]: https://github.com/rigortype/rigor/pull/1178
[#1179]: https://github.com/rigortype/rigor/pull/1179
[#1190]: https://github.com/rigortype/rigor/pull/1190
[#1201]: https://github.com/rigortype/rigor/pull/1201
[#1202]: https://github.com/rigortype/rigor/pull/1202
[#1203]: https://github.com/rigortype/rigor/pull/1203
[#1204]: https://github.com/rigortype/rigor/pull/1204
[#1205]: https://github.com/rigortype/rigor/pull/1205
[#1206]: https://github.com/rigortype/rigor/pull/1206
[#1207]: https://github.com/rigortype/rigor/pull/1207
[#1209]: https://github.com/rigortype/rigor/pull/1209
[#1210]: https://github.com/rigortype/rigor/pull/1210
[#1211]: https://github.com/rigortype/rigor/pull/1211
[#1212]: https://github.com/rigortype/rigor/pull/1212
[#1213]: https://github.com/rigortype/rigor/pull/1213
[#1215]: https://github.com/rigortype/rigor/pull/1215
[#1221]: https://github.com/rigortype/rigor/pull/1221
[#1224]: https://github.com/rigortype/rigor/pull/1224
[#1225]: https://github.com/rigortype/rigor/pull/1225
[#1236]: https://github.com/rigortype/rigor/pull/1236
[#1242]: https://github.com/rigortype/rigor/pull/1242
[#1243]: https://github.com/rigortype/rigor/pull/1243
[#1244]: https://github.com/rigortype/rigor/pull/1244
[#1245]: https://github.com/rigortype/rigor/pull/1245
[#1247]: https://github.com/rigortype/rigor/pull/1247
[#1248]: https://github.com/rigortype/rigor/pull/1248
[#1249]: https://github.com/rigortype/rigor/pull/1249
[#1250]: https://github.com/rigortype/rigor/pull/1250
[#1252]: https://github.com/rigortype/rigor/pull/1252
[#1253]: https://github.com/rigortype/rigor/pull/1253
[#1254]: https://github.com/rigortype/rigor/pull/1254
[#1255]: https://github.com/rigortype/rigor/pull/1255
[#1259]: https://github.com/rigortype/rigor/pull/1259
[#1261]: https://github.com/rigortype/rigor/pull/1261
[#1265]: https://github.com/rigortype/rigor/pull/1265
[#1266]: https://github.com/rigortype/rigor/pull/1266
[#1269]: https://github.com/rigortype/rigor/pull/1269
[#1270]: https://github.com/rigortype/rigor/pull/1270
[#1273]: https://github.com/rigortype/rigor/pull/1273
[#1274]: https://github.com/rigortype/rigor/pull/1274
[#1275]: https://github.com/rigortype/rigor/pull/1275
[#1276]: https://github.com/rigortype/rigor/pull/1276
[#1277]: https://github.com/rigortype/rigor/pull/1277
[#1278]: https://github.com/rigortype/rigor/pull/1278
[#1279]: https://github.com/rigortype/rigor/pull/1279
[#1280]: https://github.com/rigortype/rigor/pull/1280
[#1284]: https://github.com/rigortype/rigor/pull/1284
[#1291]: https://github.com/rigortype/rigor/pull/1291
[#1292]: https://github.com/rigortype/rigor/pull/1292
[#1293]: https://github.com/rigortype/rigor/pull/1293
[#1294]: https://github.com/rigortype/rigor/pull/1294
[#1295]: https://github.com/rigortype/rigor/pull/1295
[#1296]: https://github.com/rigortype/rigor/pull/1296
[#1301]: https://github.com/rigortype/rigor/pull/1301
[#1303]: https://github.com/rigortype/rigor/pull/1303
[#1306]: https://github.com/rigortype/rigor/pull/1306
[#1307]: https://github.com/rigortype/rigor/pull/1307
[#1308]: https://github.com/rigortype/rigor/pull/1308
[#1309]: https://github.com/rigortype/rigor/pull/1309
[#1310]: https://github.com/rigortype/rigor/pull/1310
[#1312]: https://github.com/rigortype/rigor/pull/1312
[#1314]: https://github.com/rigortype/rigor/pull/1314
[#1315]: https://github.com/rigortype/rigor/pull/1315
[#1316]: https://github.com/rigortype/rigor/pull/1316
[#1320]: https://github.com/rigortype/rigor/pull/1320
[#1321]: https://github.com/rigortype/rigor/pull/1321
[#1323]: https://github.com/rigortype/rigor/pull/1323
[#1326]: https://github.com/rigortype/rigor/pull/1326
[#1327]: https://github.com/rigortype/rigor/pull/1327
[#1328]: https://github.com/rigortype/rigor/pull/1328
[#1330]: https://github.com/rigortype/rigor/pull/1330
[#1331]: https://github.com/rigortype/rigor/pull/1331
[#1334]: https://github.com/rigortype/rigor/pull/1334
[#1338]: https://github.com/rigortype/rigor/pull/1338
[#1340]: https://github.com/rigortype/rigor/pull/1340
[#1343]: https://github.com/rigortype/rigor/pull/1343
[#1345]: https://github.com/rigortype/rigor/pull/1345
[#1348]: https://github.com/rigortype/rigor/pull/1348
[#1349]: https://github.com/rigortype/rigor/pull/1349
[#1353]: https://github.com/rigortype/rigor/pull/1353
[#1354]: https://github.com/rigortype/rigor/pull/1354
[#1355]: https://github.com/rigortype/rigor/pull/1355
[#1370]: https://github.com/rigortype/rigor/pull/1370
[#1374]: https://github.com/rigortype/rigor/pull/1374
[#1378]: https://github.com/rigortype/rigor/pull/1378
[#1390]: https://github.com/rigortype/rigor/pull/1390
[#1391]: https://github.com/rigortype/rigor/pull/1391
[#1392]: https://github.com/rigortype/rigor/pull/1392
[#1395]: https://github.com/rigortype/rigor/pull/1395
[#1396]: https://github.com/rigortype/rigor/pull/1396
[#1401]: https://github.com/rigortype/rigor/pull/1401
[#1404]: https://github.com/rigortype/rigor/pull/1404
[#1405]: https://github.com/rigortype/rigor/pull/1405
[#1409]: https://github.com/rigortype/rigor/pull/1409
[#1414]: https://github.com/rigortype/rigor/pull/1414
[#1419]: https://github.com/rigortype/rigor/pull/1419
[#1420]: https://github.com/rigortype/rigor/pull/1420
[#1422]: https://github.com/rigortype/rigor/pull/1422
[#1424]: https://github.com/rigortype/rigor/pull/1424
[#1425]: https://github.com/rigortype/rigor/pull/1425
[#1428]: https://github.com/rigortype/rigor/pull/1428
[#1433]: https://github.com/rigortype/rigor/pull/1433
[#1434]: https://github.com/rigortype/rigor/pull/1434
[#1438]: https://github.com/rigortype/rigor/pull/1438
[#1441]: https://github.com/rigortype/rigor/pull/1441
[#1442]: https://github.com/rigortype/rigor/pull/1442
[#1444]: https://github.com/rigortype/rigor/pull/1444
[#1448]: https://github.com/rigortype/rigor/pull/1448
[#1449]: https://github.com/rigortype/rigor/pull/1449
[#1453]: https://github.com/rigortype/rigor/pull/1453
[#1470]: https://github.com/rigortype/rigor/pull/1470
[#1479]: https://github.com/rigortype/rigor/pull/1479
[#1483]: https://github.com/rigortype/rigor/pull/1483
[#1490]: https://github.com/rigortype/rigor/pull/1490
[#1502]: https://github.com/rigortype/rigor/issues/1502
[#1503]: https://github.com/rigortype/rigor/issues/1503
[#1504]: https://github.com/rigortype/rigor/issues/1504
[#1505]: https://github.com/rigortype/rigor/issues/1505
