# The v0.3.7 allocation regression: attribution and the first recovery (2026-09-08)

Status: measurement + landed-lever record for [#775](https://github.com/rigortype/rigor/issues/775).
Harness on the unmerged branch `perfbench-harness-775` (`tool/perf775/`), per the
preserve-the-harness rule. Successor to
[`20260725-check-allocation-attribution.md`](20260725-check-allocation-attribution.md), whose
headline (54% of the run in a one-time RBS environment build) no longer holds: that build is 3% of
the run now, and the whole regression lives in per-file typing.

## The question

`make bench-perf` (`tool/bench.rb`, an in-process `rigor check --no-cache lib`) went from
18,849,919 allocations at the v0.3.6 cut to 36,171,454 at v0.3.7 on Linux CI (+91.9%), and
[#775](https://github.com/rigortype/rigor/issues/775) blessed the number so the release could
land. The issue asks which v0.3.6..v0.3.7 change paid the 17M before anyone recalibrates again.
Allocations are host-independent (macOS reproduces CI to under 1%: 18,972,086 and 36,492,665 for
the same two trees), so every figure below is a local `GC.stat(:total_allocated_objects)` delta
over the same command, YJIT off (`RIGOR_DISABLE_YJIT=1`), diagnostics compared as the serialised
`--format json` bytes. Wall clocks are quoted only as indications: the host was loaded (load
average 9 on 12 cores) throughout.

## Method

Three independent instruments, all driver-side (`Module#prepend` / `TracePoint` from outside
`lib/`; nothing in the tree was edited to measure):

1. **Per-merge sweep.** `tool/bench.rb` at every code-touching first-parent commit of
   `v0.3.6..v0.3.7` (127 of 175, each in its own worktree checkout with its own `Gemfile.lock`
   bundle). Each commit measures its own `lib`, exactly as the gate does.
2. **Engine A/B on one target.** The v0.3.6 engine and the current engine both analysing the
   *same* v0.3.8 tree (cwd = the target, `$LOAD_PATH` = the engine), under (a) an
   exclusive-allocation phase probe, (b) an allocation-site census over every fourth analysed
   file (`ObjectSpace.trace_object_allocations` with GC disabled for the window, so nothing
   allocated in it is missed; 85–87% of the window's objects are enumerable, the rest are VM
   slots), (c) per-method call counts, (d) the `RIGOR_BUDGET_TRACE` memo and union-arity
   counters, and (e) a caller trace of every `Combinator.union` of ten or more members.
3. **Per-lever measurement.** Each recovery commit measured on its own against its parent, with
   the JSON output diffed against master's.

Two things the harness taught, recorded so the next sweep does not pay for them again. Under
zsh `pipefail`, `git diff --name-only … | grep -q` fails whenever grep exits before git finishes
writing, so the first "touches a non-Markdown file" filter silently kept 13 of 127 merges — every
large one dropped. And the `RIGOR_BUDGET_TRACE` counters drift by about 1% across hours on one
host (42,285 → 42,728 infer entries for the same master tree, both runs deterministic, diagnostics
byte-identical), so they compare only back-to-back.

## Where the 17M went

### Not the target, not the gem bump

The v0.3.6 engine analysing the v0.3.8 tree allocates 21.40M against 19.68M on its own tree: the
9% larger target explains **+1.7M** of the +17.4M. The `rbs` 4.1.3 → 4.2.0 bump ([#651]) is worth
+0.17M in the sweep and +0.19M in a direct A/B (the current engine under the v0.3.6 lockfile).
Everything else is engine behaviour.

### The sweep

Cumulative first-parent allocations, `lib` self-check, top steps of the 127 measured (the full
series is `tool/perf775/sweep-v0.3.6-to-v0.3.7.csv` on the harness branch):

| merge | Δ allocations | share of +17.4M | what it does |
| --- | ---: | ---: | --- |
| [#547] per-parameter binder | +4,102,008 | 23.6% | binds optional / rest / keyword parameters at user-method call sites instead of declining the whole signature, so far more callee bodies are evaluated (issue #524) |
| [#556] alias + intersection translation | +2,315,727 | 13.3% | an RBS `type` alias is expanded and translated instead of reading `untyped` (#529) |
| [#753] autoload-safe `resolve_class` | +1,805,005 | 10.4% | the Ruby-hierarchy subtype check splits the class name on every call to walk `const_defined?` / `autoload?` |
| [#664] declared-reader precedence | +1,727,027 | 9.9% | an RBS-declared attribute reader beats the inferred one |
| [#543] optional-receiver dispatch | +906,831 | 5.2% | `T?` receivers dispatch on `T` when the method would raise on nil |
| [#712] `Result` / `Maybe` carriers | +720,977 | 4.1% | two more members in `Rigor::Type::t`, HKT slices 4–5 |
| [#584] block-return scope threading | +676,546 | 3.9% | |
| [#734] subset-run project discovery | +631,417 | 3.6% | |
| [#558] alias threading in overload selection | +515,082 | 3.0% | |
| [#726], [#685], [#537], [#669], [#620], [#581], [#538] | +200k … +411k each | 13.9% | |
| [#709] callee-rewalk nesting | −729,453 | −4.2% | the one merge that paid back |
| remaining 105 commits | ≈ +1.5M | 8.6% | none above +150k |

No single change is the regression; the top four are 57% and the top ten 77%. Three of the four
largest are precision features that do more inference on purpose ([#547], [#556], [#664]); one is
a correctness fix whose implementation happened to allocate ([#753]).

### The engine A/B on one target

Exclusive allocations by pipeline region, both engines analysing the v0.3.8 tree (446 files):

| region (exclusive) | v0.3.6 engine | v0.3.8 engine | Δ |
| --- | ---: | ---: | ---: |
| `ExpressionTyper#type_of` | 9,038,084 (750,980 calls) | 20,162,957 (982,341 calls) | **+11.1M** |
| `StatementEvaluator#evaluate` | 6,002,622 (221,130 calls) | 9,732,578 (317,615 calls) | **+3.7M** |
| `analyze_file_body` (rest) | 1,660,669 | 1,971,894 | +0.3M |
| project discovery | 650,928 | 1,304,603 | +0.7M |
| `ScopeIndexer.index` | 492,841 | 739,576 | +0.2M |
| one-time RBS env build + `for_project` + stub pass | 1,956,740 | 1,962,964 | 0 |
| on-demand definitions (`build_*_definition`) | 920,133 | 1,047,117 | +0.1M |
| **total (probed)** | **21,396,734** | **37,603,946** | **+16.2M** |

92% of the engine-side growth is the two typing regions, and it is both more calls (+31% `type_of`,
+44% `evaluate`) and more allocation per call (12.0 → 20.5 per `type_of`). The memo counters agree
on the volume: user-method return inferences 25,862 → 42,285 (+64%), body evaluations 10,764 →
18,044 (+68%), `Combinator.union` results 78,252 → 179,902 (2.3×), with the union arity p90 moving
from 3 to **18** and unions of ≥ 10 members from 753 to **20,250**.

### The per-call story

The wide-union trace put 13,592 of the 20,250 wide unions at exactly 21 members, all built by
`RbsTypeTranslator.translate_union` under `translate_alias`: **`Rigor::Type::t`**, the
21-member alias every engine method returns, re-translated at every call site since [#556]. The
expansion itself was memoised in that PR (`expand_type_alias`), but the *translation* of the
expansion — flatten, O(n²) `unique_members` with `Nominal#==`, a `describe`-keyed sort, 21 fresh
members — was not, and the resulting 21-member `Union` then flowed into every join
(`Scope#join_bindings` unions each binding with itself) and narrowing. `Nominal#==` went from
179,880 calls to **4,845,228**.

The census diff (same 111 sampled files, 3.32M → 6.60M window objects) named the rest: `String`
+735k per window, almost all from class-name normalisation (`delete_prefix("::")` copies on names
without a prefix, `resolve_class`'s `split("::")`, `TypeName#relative!.to_s`); `Array` +1.42M from
`[nil, nil]` declines in `content_mutation_target`, `params.zip(arg_types)` pairs and
`partition` / `+` in overload selection, `required.dup` in `positional_params_for`, and rbs's own
`Substitution.build` (110k calls, 109,672 of them from `RbsLoader#class_type_param_names`, because
`RBS::Definition#type_params` re-derives its names through a substitution on every call);
`Proc` +62k from two lambdas per overload selection; `AcceptsResult` +55k; `Hash` +280k from
`**shared` re-splats and empty `{}` answers.

## Levers landed (branch `perf-775-allocation-levers`)

Every step is a mechanical allocation removal — a shared frozen empty answer, a memo of a pure
function, or a rewrite that computes the same thing without the intermediate object. Output is
byte-identical to master on the `lib` self-check after every commit, and on
[redmine](https://github.com/redmine/redmine) (app + lib, seven plugins, 354,912 bytes of JSON)
at the end; `make verify` is green. Cumulative, `rigor check --no-cache lib`:

| lever | allocations after | Δ |
| --- | ---: | ---: |
| master (`ffb456b0`) | 36,492,665 | |
| `normalize_name` copies only when a `::` prefix exists (3 sites) | 35,545,804 | −946,861 |
| `content_mutation_target` declines with one frozen `[nil, nil]` | 34,598,075 | −947,729 |
| `Nominal` shares one frozen empty `type_args` | 34,187,174 | −410,901 |
| `RbsExtended` readers share their empty answers | 33,561,727 | −625,447 |
| translator memoises `TypeName#relative!.to_s` per name | 31,436,905 | −2,124,822 |
| translator memoises a closed alias expansion's translation | 30,856,415 | −580,490 |
| `union(x, x)` answers `x`; `unique_members` tries identity first | 30,278,276 | −578,139 |
| `resolve_class` memoises the split of the name | 28,484,075 | −1,794,201 |
| overload selection without lambdas, `**` splats, `zip`, `dup`, `compact` | 26,655,925 | −1,828,150 |
| receiver-affinity reorder only when the order changes | 25,304,174 | −1,351,751 |
| one `AcceptsResult` per literal reason | 25,055,693 | −248,481 |
| one `FactStore::Target` per local name | 24,322,534 | −733,159 |
| `class_type_param_names` memoised, frozen, on the loader | 22,501,792 | −1,820,742 |
| empty type-vars map and discovered-lookup pair shared | 22,115,323 | −386,469 |
| `nil` / `true` / `false` Constants interned | 21,938,254 | −177,069 |
| **branch head** | **21,933,996** | **−14,558,669 (−39.9%)** |

Against the CI numbers: v0.3.7's 36,171,454 becomes about 21.9M (−39%), which is +16% over
v0.3.6's 18,849,919 rather than +92%. Local wall on the loaded host moved 19.2 s → 17.1 s.

The alias-translation memo is smaller than its trace suggested because the downstream cost of a
21-member union does not vanish when the union is shared — it is only the `union(x, x)` joins that
become free. After both commits the wide-union count is 8,890 (from 19,985) and the 21-member
unions 2,829 (from 13,592).

## The remainder, and why it is real

With the same target, the v0.3.6 engine allocates 21.40M under the phase probe and the branch
engine 23.58M. The branch does the v0.3.7 line's work — 64% more user-method return inferences,
68% more body evaluations, [#547]'s per-parameter bodies, [#556]'s translated aliases, [#664]'s
declared readers — for about 10% more allocation than the v0.3.6 engine did the smaller job. Per
`type_of` call the branch is at 10.0 objects against v0.3.6's 12.0 and master's 20.5. What is
left is the inference volume those features buy, plus the immutable-`Scope` design (`scope.rb` is
the largest remaining file in the census: a rebuilt `Scope` and a merged locals `Hash` per
binding), the `RuleWalk::Context` per visited node, and one `ExpressionTyper` per
`Scope#type_of` — each a design seam, none a mechanical removal.

Not attempted, measured and left for a later cycle: lazy `AcceptsResult` reasons (interpolated
reasons still build a `String` and an `Array` per verdict, ≈150k), `receiver_descriptor`'s
three-element array per dispatch (≈260k), a `StatementEvaluator` per `sub_eval` (≈250k), and the
per-node `RuleWalk::Context` (≈400k).

## Gate

[#775](https://github.com/rigortype/rigor/issues/775) closes on a Linux `release-gate.yml`
`make bench-perf` inside the bands of a baseline that is not the 36.2M blessing. The next
release-gate run on `master` after this branch merges should read about 22M allocations; commit
that artifact as `bench/baseline.json` with a `note` pointing here, so the +16% remainder over
v0.3.6 is the recorded, explained cost of the v0.3.7 line's inference volume rather than a
blessing.

[#537]: https://github.com/rigortype/rigor/pull/537
[#538]: https://github.com/rigortype/rigor/pull/538
[#543]: https://github.com/rigortype/rigor/pull/543
[#547]: https://github.com/rigortype/rigor/pull/547
[#556]: https://github.com/rigortype/rigor/pull/556
[#558]: https://github.com/rigortype/rigor/pull/558
[#581]: https://github.com/rigortype/rigor/pull/581
[#584]: https://github.com/rigortype/rigor/pull/584
[#620]: https://github.com/rigortype/rigor/pull/620
[#651]: https://github.com/rigortype/rigor/pull/651
[#664]: https://github.com/rigortype/rigor/pull/664
[#669]: https://github.com/rigortype/rigor/pull/669
[#685]: https://github.com/rigortype/rigor/pull/685
[#709]: https://github.com/rigortype/rigor/pull/709
[#712]: https://github.com/rigortype/rigor/pull/712
[#726]: https://github.com/rigortype/rigor/pull/726
[#734]: https://github.com/rigortype/rigor/pull/734
[#753]: https://github.com/rigortype/rigor/pull/753
