# Work-multiplier census — where `rigor check` repeats itself, and which structural change removes it

Status: measurement note, no design commitments. Taken against master `950faa291` (after v0.4.7) on
2026-11-04. It answers the question #1507 left open: once profiling shows "feature cost spread thin",
is there an architecture-level change that reduces the amount of computation rather than its constant?

## Method

A counting harness (branch `work-census-harness`, `tool/work_census/`) prepends counters onto the
engine and runs `rigor check --no-cache --workers=0` in-process. It reports exclusive thread CPU per
phase, `ExpressionTyper#type_of` and `StatementEvaluator#evaluate` calls per node and per identical
`(scope object, node)` pair, `Scope` constructions, `Combinator.union` calls, and every return-memo
compute classed by why it ran. A `MEMO=1` switch installs a prototype `type_of` memo to size that lever.

Corpora: Rigor's own `lib` (654 files, 536K AST nodes, no plugins); Mastodon `app lib` (1,416 files,
235K nodes, 10 Rails plugins); Redmine `app lib` (876 files, 6 plugins). The survey checkouts were
copied to a private directory first. Mastodon's copy dropped an untracked `sig/` left by an earlier
sig-gen experiment: it made 70 RBS definition builds fail and would have skewed the inference mass.

CPU seconds come from one shared host under load. They are indicative, from two or three alternated
runs per arm. Allocations and call counts are deterministic. Wall was not measured on CI.

## Where the CPU goes

Exclusive thread CPU, `MODE=phases`:

| phase | rigor `lib` | Mastodon | Redmine |
| --- | ---: | ---: | ---: |
| callee-body evaluation (user-method return inference) | 28.9 s (54%) | 11.9 s (29%) | 9.3 s (26%) |
| main per-file evaluation (`ScopeIndexer.index`'s evaluator pass and `propagate`) | 8.4 s (16%) | 9.7 s (23%) | 9.8 s (28%) |
| rule walk (built-in node collectors and plugin node rules) | 6.7 s (13%) | 9.7 s (24%) | 8.2 s (23%) |
| per-file pre-pass indexes (ivar, methods, constants, globals, cvars) | 5.3 s (10%) | 4.1 s (10%) | 4.3 s (12%) |
| project discovery and plugin prepare | 2.6 s (5%) | 3.6 s (9%) | 1.2 s (3%) |
| total | 53.3 s | 41.3 s | 35.3 s |

Per-file CPU scales linearly with file size: the log-log slope of CPU against AST nodes is 1.02 on
`lib` and 0.97 on Mastodon, at about 90 µs (`lib`) and 165 µs (Mastodon) per node. No phase grows
superlinearly with a file. The cost is a constant factor, and the census below shows what it multiplies.

## The multipliers

`MODE=census` counts:

| | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| `type_of` calls / distinct typed nodes | 2.82M / 477K (5.9×) | 1.45M / 192K (7.5×) |
| calls repeating an identical `(scope object, node)` pair | 1.16M (41%) | 1.08M (74%) |
| `type_of` calls by phase: callee bodies / rules / main pass | 1.73M / 566K / 481K | 456K / 652K / 313K |
| `evaluate` calls / distinct nodes (identical-pair repeats) | 1.04M / 350K (30K) | 207K / 129K (9K) |
| `type_of` per typed node at block depth 0 / 1 / 2 / 3 | 6.5 / 11.3 / 15.8 / 29.3 | 9.4 / 9.4 / 9.5 / 14.0 |
| callee body evaluations / distinct defs | 50.6K / 14.7K (max 619) | 9.3K / 5.3K (max 268) |
| return-memo consults / hits | 133K / 98K | 94K / 84K |
| `Scope` objects built / `union` calls | 1.16M / 1.82M | 310K / 307K |

Two structural sources account for most of it.

1. **No `type_of` result is remembered.** The main pass records each node's entry scope but not its
   type (the recording lambda, `lib/rigor/inference/scope_indexer.rb:231-235`), and `Scope#type_of` builds a fresh
   `ExpressionTyper` per query (`lib/rigor/scope.rb:2363`). Each call node is then checked by about ten
   rules (`lib/rigor/analysis/check_rules.rb:303-316`), several of which re-type the receiver chain on
   their own (`check_rules.rb:1956`, `:2237`, `:3145`). On Rails code this is the largest repeat: 74%
   of Mastodon's `type_of` calls repeat an identical pair, and the rule walk makes 45% of them.
2. **Callee bodies are evaluated once per call context.** The return memo keys on the receiver, the
   argument types, the `:self` fold grant and the yield type
   (`lib/rigor/inference/expression_typer.rb:3454-3457`), so a def is evaluated again for every new
   receiver or argument-type combination, apart from the main pass's own evaluation of its body.

The block-depth row is a third, smaller source on parser-shaped code. A block body is typed by the
value pass and again by the statement pass, through different entry-scope builders
(`expression_typer.rb:4548` and `statement_evaluator.rb:8328`), so each nesting level roughly doubles
the work under it. Mastodon's blocks are shallow, which is why its row stays flat.

## What the callee CPU is made of

Each compute is classed at entry by whether its def or key was seen before, and by argument shape:

| class | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| the def's first evaluation | 16.0 s (28%) | 9.3 s (21%) |
| an evaluated def under a new key | 13.8 s (24%) | 3.7 s (8%) |
| a key already computed but not stored, or refused while its signature is on the stack | 1.1 s (2%), 12.5K evals | 0.1 s |
| by argument shape: typed / all `Dynamic[top]` / no arguments | 25.7 s / 6.2 s / 1.1 s | 5.0 s / 2.6 s / 5.3 s |

Shares are of the census run's own total (57–61 s and 44 s; the hooks add CPU). The in-cycle re-entries
are numerous on `lib` (recursive AST walkers such as `CalleeWriteCensus::ValueSources#sources`,
evaluated 619 times) but cheap: they return the current ADR-55 summary without walking the body.

How far could the callee key be collapsed without changing a result? Counted over the computes that
walked a body (in-cycle re-entries excluded):

| collapse | rigor `lib` | Mastodon |
| --- | ---: | ---: |
| drop the parameters the body never read through `Scope#local` | 443 evals (1.3%), 83 disagree | 224 evals (2.5%), 17 disagree |
| drop the receiver when the arguments match | 1,417 evals (2.8%) | 1,894 evals (20%) |
| defs with more than one key whose every key returned the same type | 4,991 of 6,988 | 561 of 630 |

The parameter-read mask is not a lever. It recovers 1–3%, and the cheap read-set proxy is not even
sound: some stored results disagree, because parameter types also reach a result through readers that
take the whole locals table (`AliasMutationFloor` and the alias scans). This confirms ADR-84 WD4(b)'s
verdict, now with evaluation mass rather than key counts. The receiver axis is real on Rails, where an
inherited helper (`current_account`, `authorize`) is evaluated once per controller subclass. Collapsing
it soundly needs a record of what the body read about `self`; nothing measured here provides one.
The "same type for every key" row is an observation after the fact and licenses nothing.

## The prototype memo

`MEMO=1` memoises `ExpressionTyper#type_of` on `(scope identity, node identity)`, bypassed when the
typer threads an operand table or a key-presence guard walk is active, and cleared per file. It has no
store gate. Results, alternated base/memo runs:

| corpus | CPU base → memo | allocations | diagnostics (strict profile, no baseline) |
| --- | --- | ---: | --- |
| Mastodon | 42.1 / 45.3 / 42.7 s → 35.0 / 30.1 / 33.3 s | 99.0M → 65.1M (−34%) | 2,783 rows, identical in order |
| Redmine | 35.3 s → 31.0 s | 70.6M → 51.6M (−27%) | 1,861 rows, identical in order |
| rigor `lib` | 52.7 / 54.3 / 53.5 s → 51.6 / 49.0 / 50.8 s | 75.4M → 67.3M (−11%) | 1 row, identical |

On Mastodon the rule walk falls by 54–63%, and callee bodies and the main pass by roughly 10–30% each.
On `lib` only the rule walk moves: most of its repeats are cheap leaves (606K of the 1.16M are
`LocalVariableReadNode`s), and a callee body runs under a fresh scope each time, so nothing in it can
hit across evaluations.

The identical diagnostics do not make the prototype sound. The ADR-55 fixpoint evaluates the same
`body_scope` object up to three times with a changing assumption (`expression_typer.rb:3755-3758`), so
a hit in a later iteration can serve an earlier iterate. A return-sink push skipped by a hit can also
lose a `return` arm, since `fixpoint_step` returns the computed value rather than the join
(`expression_typer.rb:3835-3843`). A real implementation stores a result only when its compute was
silent: no sink grew, no ADR-84 transient event was logged, the ADR-46 recorder was inactive, and no
context flag was installed mid-compute. It also needs a spec that lists every thread-local the typer
reads and requires each to be in the key or on a reasoned allow-list. ADR-52 WD5 rejected a per-node
cache because its results depend on narrowing state. Keying on the scope's identity answers that,
since a `Scope` is immutable and every transition allocates a new one. WD5 did not name the ambient
thread-local state, and that is what the gate and the spec must cover.

## Levers, ranked

| # | lever | measured or bounded payoff | risk |
| --- | --- | --- | --- |
| 1 | a `(scope, node, context)` `type_of` memo with a silent-compute store gate (#2709) | prototype: −12 to −25% CPU on Rails corpora, −27 to −34% allocations; −5% on `lib` | soundness rests on the thread-local enumeration; output-identical by design |
| 2 | let the main pass seed the return memo for a def's no-argument or all-`Dynamic` key (#2710) | upper bound: the first-evaluation rows tagged `noargs` / `alldyn`, about 14% of Mastodon's CPU and 9% of `lib`'s | untested: the main pass's `widen_clauses:`, yield frame, receiver and fold grant must match the callee's |
| 3 | one memoised block entry scope shared by the value and statement passes (#1228, generalised) | the `lib` depth row (29 calls per node at depth 3); little on Rails | the two builders differ today; needs its own equivalence spec |
| 4 | a receiver-insensitive key for inherited methods (#2711) | 20% of Mastodon's callee evaluations, 3% of `lib`'s | needs a record of the body's reads about `self` |

Measured not to be levers:

- the parameter-read mask (above);
- the in-cycle re-entries (12.5K evaluations, 1.1 s);
- the `call.possible-nil-receiver` guard re-walk (`key_presence_guard.rb:132-146`): it re-ran
  `ScopeIndexer.index` for 2 of 1,416 Mastodon files and none on `lib`;
- fusing the per-file pre-pass walks: at most the 10–12% row, and #1507's measurement of the #1197
  walk merge put four of the walks together at about 0.2% of a cold run;
- a context-insensitive dataflow graph in the TypeProf v2 style (one return vertex per def,
  `references/typeprof/lib/typeprof/core/graph/box.rb:698-723`). It unions every caller's argument
  types into one answer, which is the worst-case reading the false-positive discipline rules out. It
  would also rebuild the plugin hooks and the incremental gates, and it would still need every cap.

What remains after levers 1–4 is mostly callee bodies evaluated under genuinely different argument
types (`lib`'s 25.7 s of typed-argument computes). Reducing that means abstracting the key, for
example widening argument types after k distinct keys. That changes inferred types and so diagnostics,
which makes it a maintainer decision, not a performance change.

## Also found

`ExpressionTyper#widen_optimistic_predicate_constant` reads `scope.optimistic_origins` back into a
typing decision (`expression_typer.rb:1941`). The inference-engine spec's purity paragraph names
`dynamic_origins` and `void_origins` as the identity-keyed advisory tables that nothing reads back. It
does not mention `optimistic_origins`, which behaves differently. A memo design has to treat it as an
input. It is harmless to an identity-keyed memo, because the table is shared by reference across
derived scopes and the first compute has already written the entry.

## Limitations

- CPU comes from a loaded shared host, with at most three runs per arm. The allocation and count
  deltas are the reliable axis; a CI-Linux wall A/B (`engine-wall.yml`) is still owed before any of
  this is quoted as a speedup.
- Rigor's own `lib` produces one diagnostic even under the strict profile, so its output identity
  carries little weight. The Rails corpora's 4,644 rows carry the claim.
- The harness classifies callee computes at entry. The CPU of a class is the body's exclusive time,
  and nested computes are charged to their own class.
- The prototype memo is not a candidate implementation (see above).
