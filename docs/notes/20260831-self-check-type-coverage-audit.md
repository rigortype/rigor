# Self-check type-coverage audit — where Rigor's own `lib` stays untyped (2026-08-31)

Status: measurement note. Master `83aaad82` (v0.3.6), `lib` = 427 files / 165,820 typed expressions
/ 247,256 AST nodes. `make check` and `make check-plugins` were clean throughout; no repository file
was modified to take any measurement here. Findings became
[#501](https://github.com/rigortype/rigor/issues/501),
[#502](https://github.com/rigortype/rigor/issues/502),
[#503](https://github.com/rigortype/rigor/issues/503) and
[#506](https://github.com/rigortype/rigor/issues/506), all landed the same day (PRs
[#504](https://github.com/rigortype/rigor/pull/504),
[#505](https://github.com/rigortype/rigor/pull/505),
[#507](https://github.com/rigortype/rigor/pull/507),
[#508](https://github.com/rigortype/rigor/pull/508)); the § Ranking section carries the order and why
it was that order.

The question: run Rigor over Rigor, find where types do not attach, and rank what to fix next.

## Method

Four instruments, three of them shipped:

- `rigor check --no-cache --no-ci-detect lib` — the gate. Clean (one `info` line about 28 gems
  without RBS).
- `rigor type-scan lib` — per-node-class recognition. 5,156 / 247,256 unrecognised (2.1%),
  concentrated in `ConstantPathNode` (20.9%), `ConstantReadNode` (8.6%), `CallNode` (7.7%). This axis
  is close to saturated and is **not** where the remaining work is.
- `rigor coverage lib` / `rigor coverage --protection lib` — precision tiers and dispatch-site
  receiver concreteness.
- A scratch probe reusing `Inference::PrecisionScanner`'s own classifier, recording for every
  `:dynamic_top` / `:top` expression its node class, and for a `CallNode` the tier its **receiver**
  typed to. Driver-side only; the repo is never modified, per the harness convention.

Every A/B below is a deterministic count, not a timing, so the interleaving discipline that binds
perf work does not apply.

## The headline split

`rigor coverage lib` reports precise 55.20%, `Dynamic[Top]` 44.64%. Of the 74,284 opaque
expressions:

| node class | count | share |
| --- | --- | --- |
| `LocalVariableReadNode` | 28,765 | 38.7% |
| `CallNode` | 27,783 | 37.4% |
| `LocalVariableWriteNode` | 3,551 | 4.8% |
| `BlockNode` | 2,453 | 3.3% |
| `InstanceVariableReadNode` | 2,169 | 2.9% |
| everything else | 9,563 | 12.9% |

Two attributions decide where the work is.

**Opaque local reads are parameters.** Bucketed by whether the name is a `def` parameter, a block
parameter, or an assigned local of the enclosing scope:

| bucket | count | share of opaque local reads |
| --- | --- | --- |
| `def` parameter | 17,203 | 59.8% |
| assigned local | 8,079 | 28.1% |
| block parameter | 3,483 | 12.1% |

Parameters are 20,686 sites — **27.8% of every opaque expression in `lib`**.

**Opaque calls are propagation, not origin.** Across the 120 most frequent
`(receiver tier, method)` keys, the receiver was already `Dynamic` at 15,478 sites against 1,476
nominal, 133 implicit-self and 126 shaped. `coverage --protection` agrees from its own provenance
side-channel (ADR-75): **10,940 engine-gap against 375 add-rbs**, i.e. 96.7% of untyped-receiver
dispatch sites are not closable by writing RBS. The lever is inference, not signatures — which is
what [ADR-67](../adr/67-parameter-type-inference.md)'s `INFERRED_RETURN_UNTYPED` cause was defined
to say.

## Finding 1 — the precision lens is measured on a weaker scope than the engine has

[`CLI::CoverageScan.precision_report`](../../lib/rigor/cli/coverage_scan.rb) builds a bare
`Scope.empty`. [`CoverageCommand#scope_with_inferred_params`](../../lib/rigor/cli/coverage_command.rb),
the `--protection` path, seeds `discovered_classes` + `param_inferred_types`, and its own comment
records that the missing `discovered_classes` seed had caused a measured undercount (found
2026-07-04) because a single-file scan cannot see a class it does not itself declare. **That fix
was never applied to the precision path.**

| scope | precise | ratio | delta |
| --- | --- | --- | --- |
| bare `Scope.empty` (what `coverage` reports) | 91,536 | 0.5520 | — |
| + `discovered_classes` (621) | 93,907 | 0.5663 | +1.43pp |
| + `param_inferred_types` (1,338) | 99,607 | 0.6007 | +4.87pp / +8,071 sites |

The ratio is user-facing — `rigor coverage`, `rigor check --coverage`, and the
`make check-coverage --threshold 0.43` gate all report it. The consequence for anyone measuring:
**a precision ratio and a protection ratio from the same run describe two different engines and
must not be compared.**

Seeding both unconditionally would over-report, because `parameter_inference:` defaults to false
and the check walk's table is empty (ADR-67 WD6a). The lens should mirror the walk: seed
`discovered_classes` always, `param_inferred_types` under the flag. Filed as
[#502](https://github.com/rigortype/rigor/issues/502).

The `param_inferred_types` half is itself a result: **+3.44pp on our own `lib`**, a data point for
the open WD6 default-on question, taken on a codebase whose call graph is entirely in-project —
the favourable end of the range ADR-67 measured on faraday / haml / Mastodon.

## Finding 2 — receiver-independent `Object` / `Kernel` methods answer `Dynamic[Top]`

`x.nil?` is `bool` whatever `x` is. With `x` untyped it is `Dynamic[top]`, and so are `is_a?`,
`kind_of?`, `instance_of?`, `respond_to?`, `!`, `frozen?`, `equal?`, `to_s`, `inspect`, `hash`,
`object_id`, `class` — confirmed one by one with `rigor type-of`. `MethodDispatcher.resolve` finds
no tier for a `Dynamic` receiver and `ExpressionTyper` falls through to `inherit_receiver_origin`.

Spike: answer from a fixed table when `resolve` returns nil and the receiver is `Type::Dynamic`,
measured on top of Finding 1's seeded baseline.

| table | precise ratio | delta | new `check` diagnostics |
| --- | --- | --- | --- |
| baseline (seeded) | 0.6007 | — | 0 |
| `nil? is_a? kind_of? instance_of? respond_to? equal? frozen? !` | 0.6191 | +1.84pp | 4 |
| + `inspect hash object_id` | 0.6218 | +2.11pp | +0 |
| + `to_s` | 0.6303 | +2.96pp | +7 |
| + `class` | 0.6317 | +3.10pp | +13 |
| + `== != eql?` | 0.6378 | +3.71pp | more |

The diagnostics are the whole value of the spike, and each column says something different:

- **`class` must be excluded.** All 13 are `undefined method X for Class`. `p.class.dynamic_returns`
  on a plugin instance is real code in `lib/rigor/plugin/registry.rb`; folding `class` to
  `Nominal[Class]` erases the singleton that defines the method. A textbook
  [ADR-5](../adr/5-robustness-principle.md) false positive, bought for +0.14pp.
- **`==` / `!=` / `eql?` stay out** for the same reason at a larger blast radius.
- **`to_s`'s 7 are not the fold's fault** — they are `possible-nil-receiver` on
  `child.to_s.split("::")[0...-1]`, the RBS `Array#[](Range) -> Array[T]?` optional-return noise
  that the fold merely makes reachable.
- **The first row's 4 are pre-existing bugs**, not a cost of the change. One was Finding 3
  (`@class_rows[k] ||= {}`); chasing the other three found a *second*, distinct mutation path the
  shape machinery does not recognise — see Finding 4 below. Neither is caused by the fold; both are
  unmasked by it.

FP-free set: the eight predicates plus `inspect hash object_id`, **+2.11pp with zero new
diagnostics**. Filed as [#503](https://github.com/rigortype/rigor/issues/503), landed as
[#508](https://github.com/rigortype/rigor/pull/508) — re-measured on the integrated tree at
**56.71% → 58.98% (+2.27pp, +3,830 sites)**, with protection moving 45.6% → 45.8% as a side effect
because a chained call on one of these results now has a receiver.

One implementation detail cost a full measurement cycle and is worth recording: spelling `bool` as
`Nominal[TrueClass] | Nominal[FalseClass]` instead of the canonical
`Constant[true] | Constant[false]` (`RbsTypeTranslator::BOOL_UNION`) produces 17 spurious
`def.return-type-mismatch` warnings reading `declared bool, inferred TrueClass | FalseClass`.

## Finding 3 — a live false positive: index or/and/operator-writes never widen

Chasing the four `flow.always-truthy-condition` warnings above led to a bug that needs no spike to
reproduce. `MutationWidening.widen_after_call` runs from the `CallNode` path in
`StatementEvaluator`, so `@h[k] = 1` widens — it is a `[]=` `CallNode`. `@h[k] ||= 1` is a
`Prism::IndexOrWriteNode`, reaches `eval_index_or_write`, and never passes the widening call site.

| mutation in a sibling method | `@h.empty?` types |
| --- | --- |
| `@h[k] = 1` | `bool` |
| `@h.store(k, 1)` | `bool` |
| `@a << x` | `bool` |
| `@h[k] \|\|= 1` | `true` |
| `@h[k] += 1` | `true` |
| `@h[k] &&= 2` | (`@h.size` stays `1`) |

On master, `return nil if @rows.empty? || $stdout.tty?` warns "condition is always truthy" while
the bare `return nil if @rows.empty?` in the same class correctly does not. This is the G1/G2 gap
`MutationWidening` was written to close
([`20260521-mastodon-cluster4-flow-folding-triage.md`](20260521-mastodon-cluster4-flow-folding-triage.md)),
reappearing through the three node classes the fix did not cover.

`lib/rigor/effects/plugin_facts.rb` writes `@class_rows[entry.singleton] ||= {}` and guards four
readers with `return nil if x.nil? || @rows.empty?`. Those four are silent today only because the
left operand is `Dynamic` — which is exactly what Finding 2 would change. Filed as
[#501](https://github.com/rigortype/rigor/issues/501).

## Finding 4 — a second aliasing path: an ivar handed out by a sibling method

Three of Finding 2's four diagnostics were not Finding 3. `plugin_facts.rb`'s `@self_rows`,
`@path_rows` and `@result_rows` are each `{}` in `initialize`, handed out by `bucket_for(entry)`,
and filled through `(bucket_for(entry)[entry.receiver] ||= {})[entry.method.to_s] = row`. The
class-ivar pre-pass records a mutation only when its receiver is an `InstanceVariableReadNode`, so a
mutation through the returned alias is invisible and the ivar keeps its empty `HashShape`. On master
before the fix, `rigor type-of` read `@path_rows` as `{}` and `@path_rows.empty?` as `Constant[true]`
on a hash that is never empty in a working program — a wrong type, provable without any of the
changes above.

Same family as Finding 3 — a mutation path the shape-invalidation machinery does not recognise —
and the same latency: the bare guard stays silent, the compound one fires. Filed as
[#506](https://github.com/rigortype/rigor/issues/506), landed as
[#507](https://github.com/rigortype/rigor/pull/507). The fix stays narrow on purpose (self-call
receiver, same-class callee, ivars in RETURN position only) because over-recording widens a shape
carrier that nothing mutates and costs precision on every reader in the class.

One thing worth keeping from writing it: `make check` rejected the first draft, and was right —
`gather_aliased_mutations` read `node.receiver` behind a predicate that cannot narrow
(`NODE_CLASSES.any? { |k| node.is_a?(k) }` reads as a call on `Prism::Node`), a latent
`NoMethodError`. The engine found a real bug in the fix for its own false positive.

## Ranking

Findings 1, 3 and 4 landed the same day, in that dependency order; Finding 2 last, because both
mutation bugs had to be gone before its measurement was clean.

1. **[#501](https://github.com/rigortype/rigor/issues/501)** → [#504](https://github.com/rigortype/rigor/pull/504)
   — index or/and/operator-writes bypassing `MutationWidening`.
2. **[#506](https://github.com/rigortype/rigor/issues/506)** → [#507](https://github.com/rigortype/rigor/pull/507)
   — an ivar mutated through the alias a sibling method returned.
3. **[#502](https://github.com/rigortype/rigor/issues/502)** → [#505](https://github.com/rigortype/rigor/pull/505)
   — the precision lens seeded like the protection lens; also the ADR-67 WD6 data point.
4. **[#503](https://github.com/rigortype/rigor/issues/503)** → [#508](https://github.com/rigortype/rigor/pull/508)
   — the receiver-independent selector table.
5. **Parameters** — still open, and now the whole of what is left worth sizing: 27.8% of all opacity,
   the ADR-67 WD2 (in-body structural inference) territory that stays deferred. The attribution above
   is the baseline to re-measure against, on the post-#508 tree.

The reusable part is the shape of the day rather than any single number: **a precision lever's value
was 2.27 points, and its by-product was two live false-positive bugs neither the gate nor the corpus
had surfaced.** A fold that types more expressions makes existing wrong types *reachable* by the
diagnostic rules, which is why the diagnostic count belongs in the same table as the ratio.

## What this note does not claim

The precision ratio is a *lens*, not a goal: a higher number is only worth having when it comes
with no new false positives, which is why every row above carries its diagnostic count. Nothing
here was measured on a corpus other than this repository's own `lib`, whose call graph is unusually
self-contained; the parameter-inference figure in particular should be read as an upper bound for
real applications.
