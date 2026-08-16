# Effect catalogue — corpus measurement, before and after (#380)

Status: measurement note, no design commitments. Taken against Rigor 0.3.3 on branch
`claude/effect-labels/04-catalogue`. "Before" is the tracer slice's in-code seed table
(commit `ae1c735d`, ~30 rows); "after" is `data/effects/core.yml` (80 classes) plus the
per-class postures and argument-dependent narrowing.

## Harness

Everything below was produced by these commands, inside the Nix Flake, one project at a time.
Each scratch config is the project's own committed `.rigor.dist.yml` with `baseline:` removed
and three keys added — `effects: {}`, `parallel: {workers: 0}` (`rigor effects` is sequential,
so `rigor check` is pinned sequential too for the comparison) and a scratch `cache.path`.
The cache directory is wiped before every run, so **every measurement below is cold**; a warm
`rigor check` is served whole by the ADR-45 result cache, which a collecting run declines, and
comparing the two would measure the cache rather than the collection.

```sh
# the census
cd ~/repo/ruby/rigor-survey/<project>
BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor \
  effects --format json --full app lib --config <scratch>/<project>.yml

# the WD13 budget: the same analysis with and without the effects: block
BUNDLE_GEMFILE=<rigor>/Gemfile /usr/bin/time -l bundle exec <rigor>/exe/rigor \
  check --no-ci-detect app lib --config <scratch>/<project>-check.yml
BUNDLE_GEMFILE=<rigor>/Gemfile /usr/bin/time -l bundle exec <rigor>/exe/rigor \
  check --no-ci-detect app lib --config <scratch>/<project>-checkfx.yml
```

`<rigor>` is this worktree for "after" and a scratch worktree at `ae1c735d` for "before".
Survey checkouts: redmine `a12198ea0`, mastodon `163f96cee` (v4.6.3), gitlab `1a15763b5119`.
Nothing was written into a survey checkout — the configs and caches live outside them.

## Redmine — 4,029 methods

| | before | after |
| --- | --- | --- |
| methods collected | 4,029 | 4,029 |
| exhaustive | 650 (16.1%) | 649 (16.1%) |
| with ≥1 proven label | 1,762 (43.7%) | 1,788 (44.4%) |
| proven label instances | 3,195 | **3,975** (+24.4%) |
| distinct labels | 12 | 18 |

| label | before | after |
| --- | --- | --- |
| `mutate.self` | 1,275 | 1,275 |
| `mutate.static` | 547 | 547 |
| `mutate.local` | 456 | 456 |
| `io.fs.read` | 379 | 424 |
| `global.read` | 279 | 284 |
| `exit` | 4 | 211 |
| `io.output.stderr` | 2 | 211 |
| `mutate.instance` | 187 | 187 |
| `io.fs.write` | 0 | 95 |
| `io.process` | 13 | 91 |
| `io` | 0 | 81 |
| `nondet.time` | 45 | 50 |
| `io.net` | 0 | 25 |
| `nondet.random` | 0 | 21 |
| `global.write` | 6 | 6 |

`exit` and `io.output.stderr` move together because `Kernel#abort` is now one row carrying both,
and `Redmine::Configuration.load` calls it on four separate malformed-config paths. The 207
methods that gained it reach `Redmine::Configuration[]` — which loads on first use — from a
controller. That is the truthful reading: those requests really can abort the process.

| taint cause (methods carrying it) | before | after |
| --- | --- | --- |
| `unresolved-self-call` | 10,284 | 10,281 |
| `dynamic-receiver` | 7,183 | 7,445 |
| `unknown-ownership` | 1,031 | 1,136 |
| `dynamic-send` | 237 | 425 |
| `opaque-callable` | 81 | 122 |

## Mastodon — 7,361 methods

| | before | after |
| --- | --- | --- |
| methods collected | 7,361 | 7,361 |
| exhaustive | 1,308 (17.8%) | 1,288 (17.5%) |
| with ≥1 proven label | 2,785 (37.8%) | 2,830 (38.4%) |
| proven label instances | 4,176 | **4,543** (+8.8%) |
| distinct labels | 10 | 16 |

| label | before | after |
| --- | --- | --- |
| `mutate.self` | 2,162 | 2,169 |
| `global.read` | 599 | 608 |
| `mutate.static` | 542 | 542 |
| `nondet.time` | 428 | 438 |
| `nondet.random` | 197 | 237 |
| `mutate.local` | 156 | 156 |
| `io.fs` | 0 | 118 |
| `io.fs.write` | 0 | 108 |
| `mutate.instance` | 50 | 50 |
| `global.write` | 0 | 43 |
| `io` | 29 | 37 |
| `io.fs.read` | 12 | 18 |
| `io.net` | 0 | 16 |
| `io.net.http` | 0 | 1 |
| `io.ipc` | 0 | 1 |

`io.fs` at 118 against `io.fs.read` at 18 is the `fs` posture doing the work the rows do not:
its direct origins are `Tempfile#close` / `#binmode` / `#unlink`, `FileUtils.rmdir` /
`.remove_file`, `File#seek`, `File.umask` — filesystem calls the catalogue does not row
individually, answered at the subsystem parent rather than guessed at a direction.

| taint cause | before | after |
| --- | --- | --- |
| `dynamic-receiver` | 11,011 | 11,034 |
| `unresolved-self-call` | 10,152 | 10,158 |
| `unknown-ownership` | 1,014 | 1,097 |
| `dynamic-send` | 214 | 214 |
| `opaque-callable` | 132 | 132 |

## GitLab — 65,148 methods

| | before | after |
| --- | --- | --- |
| methods collected | 65,148 | 65,148 |
| exhaustive | 17,314 (26.6%) | 17,339 (26.6%) |
| with ≥1 proven label | 22,984 (35.3%) | 23,592 (36.2%) |
| proven label instances | 46,164 | **54,518** (+18.1%) |
| distinct labels | 16 | 23 |

| label | before | after |
| --- | --- | --- |
| `mutate.self` | 17,239 | 17,247 |
| `global.read` | 6,905 | 7,479 |
| `mutate.static` | 6,898 | 6,898 |
| `mutate.instance` | 5,920 | 5,921 |
| `io.fs.read` | 4,469 | 5,483 |
| `global.write` | 1 | 4,358 |
| `mutate.local` | 2,347 | 2,349 |
| `nondet.time` | 1,253 | 1,694 |
| `io` | 772 | 980 |
| `nondet.random` | 80 | 891 |
| `io.fs.write` | 29 | 487 |
| `io.fs` | 0 | 165 |
| `telemetry` | 0 | 161 |
| `io.output.stdout` | 144 | 144 |
| `io.output.stderr` | 51 | 64 |

`global.write` going 1 → 4,358 is the single largest movement in the whole census, and it is
`Thread.current[:key] = value` reaching most of the request path: fiber-local storage is state
shared beyond the frame, and before the catalogue that write classified as an unownable receiver
mutation (an `unknown-ownership` taint) rather than as a label. `unknown-ownership` falls
12,205 → 11,966 for the same reason — the row replaces a taint with a proven label.

| taint cause | before | after |
| --- | --- | --- |
| `unresolved-self-call` | 196,367 | 196,299 |
| `dynamic-receiver` | 94,329 | 94,326 |
| `unknown-ownership` | 12,205 | 11,966 |
| `opaque-callable` | 4,208 | 4,473 |
| `dynamic-send` | 1,630 | 1,630 |

## The WD13 budget

Cold and sequential on a 12-core Apple Silicon machine; median of three for redmine and mastodon,
a single run for gitlab. The pair is `rigor check` against **the same command with `effects: {}`
in the config** — collection and propagation, no report — which is the quantity WD13 budgets.

| project | `rigor check` | with collection | Δ wall | Δ peak RSS |
| --- | --- | --- | --- | --- |
| redmine | 8.93 s / 372 MB | 10.42 s / 430 MB | **+17%** | +16% |
| mastodon | 12.94 s / 661 MB | 19.36 s / 718 MB | **+50%** | +9% |
| gitlab | 185.0 s / 7.78 GB | 611.2 s / 7.88 GB | **+230%** | +1% |

**Wall is well outside the ~5% budget, and the overshoot grows sharply with project size.** It
does not look like the per-file scan, which is linear in AST size: redmine and mastodon differ by
1.8× in methods and 3× in collection overhead, and gitlab is another order out. The suspect is
the propagator's round-robin worklist, which iterates the whole merged method table to a fixpoint
in sorted key order — superlinear in the table's size, run once after the pool. This is a
measurement, not a diagnosis; profiling it belongs to whoever takes the budget on.

*(Followed up in [`20260817-effect-collection-perf.md`](20260817-effect-collection-perf.md). The
suspect above was wrong: the fixpoint was a quarter of a second. The superlinear term was the
per-file fold of the collections, and it is gone.)*

Read the RSS column with the noise in mind. Three runs of the *same* `rigor check` config on
redmine spanned 367–401 MB, so a +16% delta on a 372 MB base is close to the floor; gitlab's
+1% on 7.8 GB is the figure to trust, and it says the per-file collections are cheap — which is
what their shape predicts, being frozen Hashes of Strings and `LabelSet`s.

The catalogue itself is free. `rigor effects --format json --full` before against after, best of
three:

| project | before | after |
| --- | --- | --- |
| redmine | 10.02 s / 381 MB | 9.98 s / 383 MB |
| mastodon | 23.20 s / 658 MB | 23.33 s / 642 MB |
| gitlab | 632.5 s / 8.10 GB | 762.8 s / 7.60 GB |

Redmine and mastodon are best-of-three; gitlab is one run of each side, and at ten minutes a run
its two numbers are a ±20% spread rather than a difference — do not read a regression into them.

## Coexistence

The diagnostic streams of `rigor check` and `rigor check` with `effects: {}` are **byte-identical
on all three projects** (`cmp` on the captured stdout, 710,800 bytes on gitlab). `exe/rigor check
lib` over Rigor's own tree is byte-identical between `ae1c735d` and this branch.

## What the measurement found

**A `Kernel` row shadowing a project method.** Redmine defines `CustomField#format`, and
`Kernel#format` is a catalogue row. An unqualified `format` resolves against self's ancestry
first, so the project method wins at run time — but a matched row suppressed the project edge,
and seventeen Redmine methods silently lost a transitively proven label. The tracer had the same
hazard over its thirty rows; widening the catalogue widened it. Fixed by taking the **union**: a
claimed implicit-self call keeps its project edge, and so does a posture answer, since an edge
that reaches no project definition is dropped by the propagator anyway. The `after` column above
is post-fix; the label losses are gone.

**The union costs taint, and that is the honest trade.** Keeping those edges propagates callees'
taint causes as well as their labels, which is where mastodon's exhaustive count moves 1,308 →
1,288 and redmine's `dynamic-send` reach nearly doubles. A summary that says "and possibly more"
because it now knows about a callee is more truthful than one that was exhaustive because it had
cut the callee off.

**Two wrong labels the census caught, both from the posture being too blunt.** `IO#respond_to?`
read as `io` and `Kernel.Float(x)` read as `io`, because a world-facing default answers for every
selector the class does not row — including the `Object`-level ones that exist on every receiver,
and including `Kernel`'s `module_function` side, which is the pure conversion family. Fixed with a
universal ∅ selector list consulted before any posture, and an optional per-class
`singleton_posture:`. Both were labels on correct code, which is the failure mode ADR-5 budgets
against; neither would have been visible without running the census.

**The exhaustiveness bit barely moves** (16.1% → 16.1%, 17.8% → 17.5%, 26.6% → 26.6%). That is the expected
shape: a posture default answers where the tracer answered nothing, and neither taints, so the
catalogue's work is entirely in the proven lane. The bit is governed by `dynamic-receiver` and
`unresolved-self-call`, which are dispatch-quality questions, not catalogue-coverage ones.
