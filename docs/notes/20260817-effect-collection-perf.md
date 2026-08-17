# Effect collection — where the WD13 budget went, and what got it back (#382)

Status: measurement note, no design commitments. Taken against Rigor 0.3.3 on branch
`claude/effect-labels/05-collection-perf`, stacked on the catalogue slice. It answers the
question [`20260817-effect-catalogue-corpus.md`](20260817-effect-catalogue-corpus.md) § The WD13
budget left open: collection cost +17 % / +50 % / +230 % of wall on redmine / mastodon / gitlab,
sharply superlinear in project size, and that note called the profiling somebody else's job.

## Harness

Identical to the catalogue note's, and re-read from it rather than re-invented: the project's own
committed `.rigor.dist.yml` with `baseline:` removed and three keys added — `parallel: {workers: 0}`,
a scratch `cache.path`, and (for the `+effects` column) `effects: {}`. The cache directory is wiped
before every run, so **every measurement is cold**.

```sh
cd ~/repo/ruby/rigor-survey/<project>
BUNDLE_GEMFILE=<rigor>/Gemfile /usr/bin/time -l bundle exec <rigor>/exe/rigor \
  check --no-ci-detect app lib --config <scratch>/<project>-check{,fx}.yml
```

Survey checkouts: redmine `a12198ea0`, mastodon `163f96cee`, gitlab `1a15763b5119`. Nothing was
written into a survey checkout.

The phase attribution below comes from a second harness: `Rigor::CLI.start` driven in-process with
`Propagator.propagate`, `Collector.collect_for`, `Scanner.scan` and `FileCollection#merge` wrapped in
a monotonic-clock stamp. Sequential, so no fork hides the work.

**Read the wall columns as ratios within one block, not across the two.** "Before" and "after" were
measured in separate sessions on the same laptop and the machine drifted badly between them —
`rigor check` alone, with no collection in it either way, was mastodon 12.5 s against 14.3 s and
gitlab 174.5 s against 231.7 s. Each block's two columns are contemporaneous, so each block's ratio
is sound; the absolute seconds are not comparable across blocks. The before block reproduces the
catalogue note's published +17 % / +50 % to the digit, which is what says the harness is the same one.

## Before — where the time was

Cold and sequential. Redmine and mastodon are medians of three; gitlab is one run each way.

| project | `rigor check` | with collection | Δ wall | Δ peak RSS |
| --- | --- | --- | --- | --- |
| redmine | 9.35 s / 398 MB | 11.25 s / 420 MB | **+20 %** | +6 % |
| mastodon | 14.27 s / 657 MB | 21.38 s / 703 MB | **+50 %** | +7 % |
| gitlab | 231.7 s / 6.76 GB | 689.1 s / 7.28 GB | **+197 %** | +8 % |

(One redmine collecting run came in at 21.28 s against its siblings' 10.86 s and 11.25 s — something
else on the machine, discarded by the median rather than by judgment.)

Phase attribution, mastodon (1,312 files, 7,361 methods):

| phase | wall | n |
| --- | --- | --- |
| `FileCollection#merge` — the run's fold | **5.077 s** | 1,312 |
| `Collector.build` (the per-def `Scanner` walk) | 0.228 s | 1,312 |
| `Propagator.propagate` | 0.235 s | 1 |
| `Collector.record_call` | ~0.26 s | 492,592 |

Redmine's is the same shape one size down: merge 1.120 s, build 0.233 s, propagate 0.151 s — 1.50 s
of a ~1.9 s overhead. **The fold is the whole superlinear term, and everything else is linear.**

`Runner#effect_collection` folded the run with
`effect_collections.reduce(FileCollection.empty) { |merged, c| merged.merge(c) }`, and
`FileCollection#merge` is written as a value-object merge: it rebuilds every accumulated table, runs
`freeze_table`'s `transform_values` over all of it, and re-`uniq`s **and re-sorts every accumulated
edge list** — per file. That is O(files × methods) with a sort inside, and it is exactly the observed
shape: the overhead itself (1.90 s / 7.11 s / 457.3 s) grows 1 : 3.7 : 241 against a method count that
grows 1 : 1.8 : 16.

Nothing else was superlinear. The suspects the task listed and the measurement cleared: the
closed-world override join is already a per-run index; `Collector.active?` really is an integer read;
`record_call` costs 0.5 µs a site; the per-def `Scanner` walk is linear in AST size; and the
post-pool fixpoint, the headline suspect in the catalogue note, was a quarter of a second.

## What changed

- **`Effects::FileCollection.merge_all`** (`lib/rigor/effects/file_collection.rb:88`) folds a run in
  one pass — each key's summaries join once, each table is built and frozen once, edge lists are
  de-duplicated and sorted once at the end. `#merge` stays, for the two-collection case its cost
  model fits, and delegates. `Runner#effect_collection` (`lib/rigor/analysis/runner.rb:87`) calls it.
- **The propagator's fixpoint is a real worklist** (`lib/rigor/effects/propagator.rb:74`). A key's
  closure moving can only move its *callers*' closures, so each pass re-visits exactly those instead
  of round-robining the whole table; the reverse adjacency is built once. Causes ride through the
  fixpoint as a `Set` rather than an Array re-concatenated and re-`uniq`ed on every visit of every
  edge (`:106`).
- **Edge resolution is memoised** on `(receiver class, kind, selector)`, and the transitive subclass
  closure on the class name (`lib/rigor/effects/propagator.rb:161`). One triple is asked for once per
  call site, and `ApplicationRecord`'s subclass forest was being re-walked thousands of times.
- **`LabelSet#join` returns `self` without allocating when the join adds nothing**
  (`lib/rigor/effects/label_set.rb:84`) — the common case in any loop that joins, and the thing that
  makes a worklist pass over a converged region free.
- **`Collector.record_call` asks whether the node is already recorded before building anything**
  (`lib/rigor/effects/collector.rb:114`). First write wins, and `CheckRules` re-runs `type_of` over
  the same nodes, so about half of all recording calls were building a `Data` and running an origin
  lookup only to drop the result.
- **Values that are the same at every site are built once**: the construct origins
  (`lib/rigor/effects/unit_scan.rb:54`), the synthesised `attr_writer` summary
  (`lib/rigor/effects/scanner.rb:51`), and a catalogue row's un-narrowed `Entry`
  (`lib/rigor/effects/catalog.rb:246`).

None of it changes what is collected. The `rigor check` diagnostic stream is byte-identical with and
without `effects:` on all three projects (`cmp`; 710,800 bytes on gitlab), which was already the
coexistence gate and still holds.

With collection **off** nothing here runs at all, and the measurement says so: `exe/rigor check lib`
over Rigor's own tree is diagnostic-identical to the parent commit (only the wall / RSS report line
differs), and its whole-run allocation count moves 17,926,639 → 17,939,795 — the eleven frozen values
now built at load time, +0.07 %. Peak RSS on that run reads 8 % higher, which is the noise floor: the
same binary measured three times spans 266–296 MB.

## After

| project | `rigor check` | with collection | Δ wall | Δ peak RSS |
| --- | --- | --- | --- | --- |
| redmine | 8.61 s / 384 MB | 9.08 s / 420 MB | **+5.5 %** | +9 % |
| mastodon | 12.54 s / 663 MB | 13.03 s / 668 MB | **+3.9 %** | +0.8 % |
| gitlab | 174.5 s / 8.33 GB | 178.7 s / 8.00 GB | **+2.4 %** | −4 % |

Redmine and mastodon are medians of three; gitlab is one cold run each way.

**The overhead now falls with project size instead of growing with it**, which is the shape a
per-file linear cost has against a base that is superlinear in its own right. Mastodon is inside
WD13's ≤ ~5 % wall / RSS. Redmine sits just outside on wall at +5.5 %: it is the smallest of the
three and the per-file scan is the largest share of the smallest base, so this is the linear term
showing, not a residue of the old one.

RSS is the noisy column, exactly as the catalogue note warned — three runs of the *same* `rigor
check` config on redmine spanned 371–403 MB. Gitlab's −4 % on 8 GB and mastodon's +0.8 % on 663 MB
are the figures to trust, and both say the collections themselves are cheap.

### The fixpoint at gitlab scale

The graph is 65,148 methods, 47,441 methods with edges, 133,565 edges after resolution.

| step | wall |
| --- | --- |
| edge resolution (ancestry + closed-world override join) | 0.446 s |
| **the fixpoint itself** | **0.642 s** |
| building the table's 65,148 entries | 0.202 s |
| `Propagator.propagate` end to end | 1.340 s |

WD13 budgets "≤ 1 s of fixpoint at gitlab scale". The fixpoint is 0.64 s and inside it; the whole
propagation step, which also resolves every edge and materialises every row, is 1.34 s — 0.7 % of the
run it sits at the end of. Stated both ways rather than picking the flattering one.

### Allocations

Mastodon, in-process, `GC.stat(:total_allocated_objects)` over the whole run:

| | allocations |
| --- | --- |
| `rigor check` | 37.2 M |
| with collection, before | 87.2 M |
| with collection, after | 38.7 M |

Collection went from **+134 %** allocations to **+4 %**. On a corpus that is allocation-bound
(GC ≈ 57 % of CPU on mastodon, `20260620-corpus-cold-warm-reprofile.md`) that is the number behind
the wall column.

## What remains

A linear per-file cost that WD13 anticipates and does not budget away: the effect scan is a
**separate Prism descent** per file (3.77 s of gitlab's 178.7 s, 0.24 s of mastodon's 13.0 s), taken
rather than riding `ScopeIndexer`'s existing `def` walk because the scanner must attribute each
recorded call *node* to its enclosing unit, and doing that inside the indexer would put an
effects-shaped concern on the hot path of every run — including the runs with collection off. Folding
the two walks together is the remaining ~2 % and is a WD13-scoped change to the indexer, not a
collection one.
