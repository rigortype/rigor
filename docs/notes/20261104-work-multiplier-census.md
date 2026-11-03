# Work-multiplier census — where `rigor check` repeats itself, and which structural change removes it

Status: measurement note, no design commitments. Taken against master `950faa291` (after v0.4.7) on
2026-11-04. It answers the question #1507 left open: once profiling shows "feature cost spread thin",
is there an architecture-level change that reduces the amount of computation rather than its constant?

## Method

A counting harness prepends counters onto the engine and runs `rigor check --no-cache --workers=0`
in-process. It reports exclusive thread CPU per phase, `ExpressionTyper#type_of` and
`StatementEvaluator#evaluate` calls per node and per identical `(scope object, node)` pair, `Scope`
constructions, `Combinator.union` calls, and every return-memo compute classed by why it ran. A
`MEMO=1` switch installs a prototype `type_of` memo to size that lever. The harness is on branch
`work-census-harness` (§ Limitations).

Corpora: Rigor's own `lib` (654 files, 536K AST nodes, no plugins); Mastodon `app lib` (1,416 files,
235K nodes, 10 Rails plugins); Redmine `app lib` (876 files, 6 plugins). The survey checkouts were
copied to a private directory first. Both carry an untracked `sig/` that the 2026-10-27
`rigor-project-init` re-init wrote (Phase 5, `rigor sig-gen`) before #2437 was fixed: it declares
subclasses against superclasses it wrote no declaration for. That made 70 (Mastodon) and 74 (Redmine)
RBS definition builds fail and would have skewed the inference mass, so the copies drop it. They keep
the checkouts' gem RBS collection.

CPU seconds come from one shared host under load. The phase table is one run per corpus. The
prototype A/B is three alternated pairs on Mastodon and `lib`, and one pair on Redmine. Allocations and
call counts are deterministic. Wall was not measured on CI.

## Where the CPU goes

Exclusive thread CPU, `MODE=phases`, one run per corpus (Redmine's is the strict-profile base run of
§ The prototype memo):

| phase (harness keys) | rigor `lib` | Mastodon | Redmine |
| --- | ---: | ---: | ---: |
| callee-body evaluation, user-method return inference (`callee_body`) | 28.9 s (54%) | 11.9 s (29%) | 11.4 s (30%) |
| main per-file evaluation (`index:eval`, `index:propagate`) | 8.4 s (16%) | 9.7 s (23%) | 10.4 s (28%) |
| rule walk: built-in node collectors and plugin node rules (`rules*`) | 6.7 s (13%) | 9.7 s (23%) | 7.7 s (20%) |
| per-file pre-pass indexes: ivar, methods, constants, globals, cvars, declarations, mutations (`index:*` else) | 5.3 s (10%) | 4.1 s (10%) | 4.3 s (11%) |
| project discovery and plugin prepare (`discovery`, `pre_passes`) | 2.6 s (5%) | 3.6 s (9%) | 1.3 s (4%) |
| other: CLI, boot, parse | 1.4 s (3%) | 2.4 s (6%) | 2.6 s (7%) |
| total | 53.3 s | 41.3 s | 37.7 s |

Per-file total CPU scales about linearly with file size: the log-log slope of a file's CPU against its
AST nodes is 1.02 (r² 0.77) on `lib` and 0.97 (r² 0.62) on Mastodon, at about 99 µs and 165 µs per
node. The rows carry each file's total only, so this shows no superlinear growth in a file's total, not
in each phase. The cost is a constant factor, and the census below shows what it multiplies.

## The multipliers

`MODE=census` counts:

| | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| `type_of` calls / distinct typed nodes | 2.82M / 477K (5.9×) | 1.45M / 192K (7.5×) |
| calls repeating an identical `(scope object, node)` pair | 1.16M (41%) | 1.08M (74%) |
| `type_of` calls by phase: callee bodies / rules / main pass (`index:eval`) | 1.73M / 566K / 481K | 456K / 652K / 313K |
| `evaluate` calls / distinct nodes (identical-pair repeats) | 1.04M / 350K (30K) | 207K / 129K (9K) |
| `type_of` per typed node at block depth 0 / 1 / 2 / 3, analysed file's own nodes | 6.5 / 11.3 / 15.8 / 29.3 | 9.4 / 9.4 / 9.5 / 14.0 |
| callee body evaluations / distinct defs | 50.6K / 14.7K (max 619) | 9.3K / 5.3K (max 268) |
| return-memo consults / hits | 133K / 98K | 94K / 84K |
| `Scope` objects built / `union` calls | 1.16M / 1.82M | 310K / 307K |

Two structural sources account for most of it.

1. **No `type_of` result is remembered.** The main pass records each node's entry scope but not its
   type (the recording lambda, `lib/rigor/inference/scope_indexer.rb:231-235`), and `Scope#type_of`
   builds a fresh `ExpressionTyper` per query (`lib/rigor/scope.rb:2363-2365`). Each call node is then
   checked by about ten rules (`lib/rigor/analysis/check_rules.rb:303-316`), several of which re-type
   the receiver chain on their own (`check_rules.rb:1956`, `:2237`, `:3145`). On Rails code this is
   the largest repeat: 74% of Mastodon's `type_of` calls repeat an identical pair, and the rule walk
   makes 45% of all its `type_of` calls. Repeats per phase were not counted.
2. **Callee bodies are evaluated once per call context.** The return memo keys on the receiver, the
   argument types, the `:self` fold grant and the yield type
   (`lib/rigor/inference/expression_typer.rb:3454-3457`), so a def is evaluated again for every new
   receiver or argument-type combination, apart from the main pass's own evaluation of its body.

The block-depth row is a third, smaller source, and only on some code. A block body is typed by the
value pass and again by the statement pass, through different entry-scope builders
(`expression_typer.rb:4548`, `statement_evaluator.rb:8328`). On `lib` each nesting level roughly
doubles the rate. Mastodon's rate is flat, though it has 19K typed nodes at depth 1, so shallow
nesting does not explain it. A fixture probe during review found the doubling only where the value
pass types the block body under a typed receiver: a `map` in a `map` in a `map`, in a callee evaluated
under four argument types, went 17.3 → 34.3 → 65.3 calls per node. The same chain over a `Dynamic`
parameter stayed at 3.3 / 4.0 / 5.0, and nested `each` at 4.0 / 5.0 / 4.8. Rails DSL blocks mostly have
untyped receivers. `lib`'s gradient is also tangled with callee multiplicity, since callee bodies make
61% of its `type_of` calls and the hottest are block-heavy walkers. The depth row covers the analysed
file's own nodes, which leaves out 766K calls (27%) on nodes from other files. Sized as excess over the
depth-0 rate, the depth effect is about 284K calls, 10% of `lib`'s `type_of` calls. Depth 3 alone is
662 nodes.

## What the callee CPU is made of

Each compute is classed at entry by whether its def or key was seen before. The harness keys a compute
by receiver and argument types only, which is coarser than the memo's key:

| class | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| the def's first evaluation | 16.0 s (28%) | 9.3 s (21%) |
| an evaluated def under a new receiver or argument types | 13.8 s (24%) | 3.7 s (8%) |
| a memo miss on receiver and argument types seen before (a store-gate refusal, or a key that differs only in fold grant or yield type) | 1.07 s, 709 evals | 0.07 s, 52 evals |
| an in-cycle re-entry while the signature is on the guard stack | 0.06 s, 14.7K evals | 0.00 s, 244 evals |

A second census run tagged the same computes by argument shape: typed arguments / every argument
`Dynamic[top]` / no arguments took 25.7 s / 6.2 s / 1.1 s on `lib` and 5.0 s / 2.6 s / 5.3 s on Mastodon.
Shares are of each census run's own total (57–61 s and 44 s; the hooks add CPU). The in-cycle
re-entries are numerous on `lib` (recursive AST walkers such as `CalleeWriteCensus::ValueSources#sources`,
evaluated 619 times) but cheap: they return the current ADR-55 summary without walking the body.

How far could the callee key be collapsed without changing a result?

| collapse | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| drop the parameters the body never read through `Scope#local`, over computes that walked a body | 443 of 35,011 evals (1.3%), 83 disagree | 224 of 9,026 (2.5%), 17 disagree |
| drop the receiver when the arguments match, over all computes | 1,417 of 50,592 (2.8%) | 1,592–1,894 of 9,298 (17–20%) |
| defs with more than one key whose every key returned the same type | 4,991 of 6,988 | 561 of 630 |

The parameter-read mask is not a lever. Only 644 (`lib`) and 190 (Mastodon) evaluations left any
parameter unread through `Scope#local`, which bounds any mask defined at that interface. Some masked
results also disagree, from causes not separated here: readers that take the whole locals table
(`AliasMutationFloor`, `lib/rigor/inference/alias_mutation_floor.rb:318`) can see a parameter's type
without `Scope#local`, and the harness key omits the fold grant and yield type. This confirms ADR-84
WD4(b)'s verdict, now with evaluation mass rather than key counts.

The receiver axis is real on Rails, where an inherited helper (`current_account`, `authorize`) is
evaluated once per controller subclass. The range is wide because the count includes up to 302
same-key repeats. Collapsing it soundly needs a record of what the body read about `self`, and nothing
measured here provides one. The "same type for every key" row is an observation after the fact and
licenses nothing.

## The prototype memo

`MEMO=1` memoises `ExpressionTyper#type_of` on `(scope identity, node identity)`, bypassed when the
typer threads an operand table or a key-presence guard walk is active, and cleared per file. It has no
store gate. Alternated base/memo pairs, total exclusive CPU:

| corpus, configuration | CPU base → memo | allocations | diagnostics |
| --- | --- | ---: | --- |
| Mastodon, survey config (lenient, baseline on), pair 1 | 42.1 → 35.0 s (−17%) | 99.0M → 65.1M (−34%) | 6 rows, identical |
| Mastodon, survey config, pair 2 | 45.3 → 30.1 s (−34%), host-shifted | 99.0M → 65.1M | 6 rows, identical |
| Mastodon, strict, no baseline | 42.7 → 33.3 s (−22%) | 98.3M → 64.4M (−34%) | 2,783 rows, identical in order |
| Redmine, strict, no baseline | 37.7 → 30.8 s (−18%) | 79.6M → 60.6M (−24%) | 1,844 rows, identical in order |
| rigor `lib`, pairs 1 and 2 | 52.7 → 51.6 s (−2%); 54.3 → 49.0 s (−10%), host-shifted | 75.4M → 67.3M (−11%) | 1 row, identical |
| rigor `lib`, strict | 53.5 → 50.8 s (−5%) | 75.7M → 67.6M (−11%) | 1 row, identical |

Mastodon's pair 2 also cut phases the memo cannot reach, such as parse (0.41 → 0.31 s, −24%) and the
ivar index (−19%), so about 20 points of its −34% are host load. `lib`'s pair 2 is shifted the same
way (parse −11%). The allocation axis is the reliable one: −24% to −34% on the Rails corpora and −11%
on `lib`. On Mastodon's two clean pairs the rule walk (`rules*`) falls by 52–53%, callee bodies by
12–18% and the main pass by 8–15%. On `lib` only the rule walk moves. Most of its repeats are cheap
leaves (606K of the 1.16M are `LocalVariableReadNode`s), and separate callee evaluations each build
their own body scope, so nothing in one can hit in another.

The identical diagnostics do not make the prototype sound, for these reasons:

- **The spec's purity MUST does not hold today.** `docs/internal-spec/inference-engine.md:24` requires
  the same `(scope, node)` pair to give structurally equal results within a run. Within one callee
  evaluation, though, the ADR-55 fixpoint evaluates the same `body_scope` object up to three times
  under a changing thread-local assumption (`expression_typer.rb:3755-3758`), so the engine already
  types the same pair differently across iterations. A memo hit in a later iteration serves an
  earlier iterate. A return-sink push skipped by a hit can also lose a `return` arm, since
  `fixpoint_step` returns the computed value rather than the join (`expression_typer.rb:3835-3843`).
  A memo cannot cite that MUST as its licence. The spec has to be amended to say what does hold.
- **A real memo needs a store gate.** Store a result only when its compute was silent: no sink grew,
  no ADR-84 transient event was logged, the ADR-46 recorder was inactive, and no context flag was
  installed mid-compute.
- **Its key must cover the ambient state.** A spec has to list every thread-local the typer reads and
  require each to be in the key or on a reasoned allow-list. Two inputs are not thread-locals:
  - the typer's per-instance `tracer:` (`expression_typer.rb:256-258`), whose fallback events (bound by
    the spec's Fallback Tracer section) a hit would drop, which matters for lens and `--explain`
    output;
  - the key-presence guard walk's isolated side tables. `Scope#with_isolated_side_tables`
    (`scope.rb:414-417`) copies them, `optimistic_origins` included, so the memo must keep bypassing that
    walk.
- ADR-52 WD5 rejected a per-call-node cache of plugin contribution results, because those results
  depend on the narrowing state at consultation time. Keying on the scope's identity answers that,
  since a `Scope` is immutable and every transition allocates a new one. WD5 did not name the ambient
  state, and that is what the gate and the spec must cover.

## Levers, ranked

| # | lever | measured or bounded payoff | risk |
| --- | --- | --- | --- |
| 1 | a `(scope, node, context)` `type_of` memo with a silent-compute store gate (#2709) | prototype: allocations −24 to −34% on the Rails corpora and −11% on `lib`; CPU −17 to −22% on clean Mastodon pairs, −18% on Redmine, −2 to −5% on `lib` | soundness rests on the store gate and the ambient-state enumeration, and the spec's MUST must be amended first; output-identical by design |
| 2 | let the main pass seed the return memo for a def's no-argument or all-`Dynamic` key (#2710) | upper bound: the first-evaluation computes tagged no-argument or all-`Dynamic`, about 14% of Mastodon's census CPU and 9% of `lib`'s | untested: the main pass's `widen_clauses:`, yield frame, receiver and fold grant must match the callee's, and a hit must replay the ADR-46 read set |
| 3 | one memoised block entry scope shared by the value and statement passes (#1228, generalised) | about 10% of `lib`'s `type_of` calls (the excess over the depth-0 rate); little on Rails | the two builders differ today; needs its own equivalence spec |
| 4 | a receiver-insensitive key for inherited methods (#2711) | 17–20% of Mastodon's callee evaluations, 3% of `lib`'s | needs a record of the body's reads about `self` |

Measured not to be levers:

- the parameter-read mask (above);
- the in-cycle re-entries (14.7K evaluations, 0.06 s);
- the `call.possible-nil-receiver` guard re-walk (`lib/rigor/inference/key_presence_guard.rb:132-146`):
  the harness saw 1,418 `ScopeIndexer.index` runs for 1,416 Mastodon files and 654 for 654 `lib` files,
  so at most two re-walks;
- fusing the per-file pre-pass walks: at most the 10–11% row, and #1507's measurement of the #1197
  walk merge put four of the walks together at about 0.2% of a cold run.

Argued against, not measured: a context-insensitive dataflow graph in the TypeProf v2 style (one return
vertex per def, `references/typeprof/lib/typeprof/core/graph/box.rb:698-723`). It unions every caller's
argument types into one answer, which is the worst-case reading the false-positive discipline rules
out. It would also rebuild the plugin hooks and the incremental gates, and it would still need every
cap.

What remains after levers 1–4 is mostly callee bodies evaluated again under different argument types:
`lib`'s `new_key` computes with typed arguments, 12.8 s or 21% of the census run's CPU. Reducing that
means abstracting the key, for example widening argument types after k distinct keys. That changes
inferred types and so diagnostics, which makes it a maintainer decision, not a performance change.

## Also found

`optimistic_origins` is read back into typing decisions at four sites: `expression_typer.rb:1941`
(`widen_optimistic_predicate_constant`), `def_return_typer.rb:129`, and `optimistic_origin.rb:111` and
`:172`. The inference-engine spec's purity paragraph names `dynamic_origins` and `void_origins` as the
identity-keyed advisory tables that nothing reads back. It does not mention `optimistic_origins`, which
behaves differently. A memo design has to treat it as an input. It is harmless to an identity-keyed
memo outside the guard walk, because the table is shared by reference across derived scopes and the
first compute has already written the entry.

## Limitations

- The instrument is on branch `work-census-harness` (`tool/work_census/`, with a README), kept for
  follow-up questions and not meant to be merged. Its callee key is receiver and argument types only.
  Its receiver-collapse count includes in-cycle computes and same-key repeats. The guard re-walk count
  is inferred from phase entry counts.
- CPU comes from a loaded shared host: one run per corpus for the phase table, and at most three
  pairs for the prototype, two of them host-shifted. The allocation and count deltas are the reliable
  axis. A CI-Linux wall A/B (`engine-wall.yml`) is still owed before any of this is quoted as a
  speedup.
- Rigor's own `lib` produces one diagnostic even under the strict profile, so its output identity
  carries little weight. The Rails corpora's 4,627 rows carry the claim.
- The harness classifies callee computes at entry. A class's CPU is the body's exclusive time, and
  nested computes are charged to their own class.
- The survey checkouts under `~/repo/ruby/rigor-survey/` still carry that pre-#2437 `sig/`
  (§ Method), and any measurement taken from them in place inherits the same RBS build failures.
  Re-running `rigor sig-gen` over it does not help, because sig-gen keeps a stale header (#2716).
  Deleting `sig/` and regenerating clears Mastodon's failures but leaves 6 in Redmine (#2715).
- The prototype memo is not a candidate implementation (§ The prototype memo).
