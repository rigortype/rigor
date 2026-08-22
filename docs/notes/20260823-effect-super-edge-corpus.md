# The edge a `super` contributes — corpus movement and cost (#446)

Status: measurement note, no design commitments. Taken against Rigor 0.3.4 on branch
`claude/effects/super-edge`, over private copies of the redmine and mastodon survey checkouts.

[#446](https://github.com/rigortype/rigor/issues/446) is a soundness hole in the declared lane: a `super`
contributed nothing to a summary **and** left the row exhaustive, so a method whose whole body delegates
upward read as provably effect-free and passed any envelope. The fix gives `super` an edge, resolved
above the enclosing class, and taints `unresolved-super` when the project's own ancestry answers nothing.
Adding a call edge moves summaries corpus-wide, which is what this note measures.

## Harness

Both projects were `rsync`ed to a scratch directory first; nothing was written into a survey checkout.
Checkouts: redmine `a12198ea0`, mastodon `163f96cee`. Each project's committed `.rigor.dist.yml` with
`baseline:` dropped and `effects: {}` added — the same shape
[`20260817-effect-collection-perf.md`](20260817-effect-collection-perf.md) uses — saved as
`.rigor.446.yml`.

```sh
cd <scratch>/survey/<project>
rm -rf .rigor/cache                                     # every run is COLD
BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor \
  check   --config .rigor.446.yml --format json         # diagnostics + the stats block
BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor \
  effects --config .rigor.446.yml --full --format json  # the whole table, per arm
```

The cache is wiped before every run because the ADR-45 run-result cache fingerprints the project and the
configuration, neither of which changes between arms: a warm run would have replayed one arm's
collections into the other.

The two arms are the same working tree with `lib/` toggled by `git apply` / `git checkout --`, and they
are **interleaved** — `off, on, off, on, …` for seven iterations — so a host whose load drifts moves both
arms together. Movement is read by diffing the two `effects --full --format json` tables key by key:
labels gained and lost per unit, the exhaustiveness bit's transitions, and which selectors sit behind an
`unresolved-super`.

## Movement

Deterministic, and the reason this is the part worth trusting: it is a diff of two JSON tables, not a
timing.

| | redmine | mastodon |
| --- | --- | --- |
| effect units in the table | 4,683 | 8,355 |
| `super` occurrences in `app/` + `lib/` | 166 | 114 |
| units that **gained** a proven label | 28 (0.6 %) | 121 (1.4 %) |
| units that **lost** a proven label | 0 | 0 |
| units that went exhaustive → hedged | 37 (0.8 %) | 28 (0.3 %) |
| units that went hedged → exhaustive | 0 | 0 |
| units carrying an `unresolved-super` cause | 463 (9.9 %) | 792 (9.5 %) |
| …of which were already hedged for another reason | 440 | 768 |

Three readings.

**The hedge is wide but almost free.** Roughly a tenth of all units end up carrying the cause, because it
travels call edges like any other; but 95 % of them were already non-exhaustive for a reason of their own
(`dynamic-receiver`, `unresolved-self-call`), so they gain a cause and not a transition. The *new*
information — a row that used to claim completeness and no longer does — is 37 and 28 units.

**Nothing lost a label**, which is the monotonicity the change should have: an edge can only add.

**The labels gained are what a Rails ancestry does.** On mastodon the top three are `mutate.local` (107),
`nondet.random` (97) and `nondet.time` (81), almost all through `super` into an ActiveRecord-shaped
project ancestor. On redmine the spread is wider and smaller: `mutate.self` 13, `mutate.instance` 10,
`mutate.local` 9, `io.fs.read` 5, and single digits of `io`, `io.process`, `io.net`.

The selectors behind an unresolved `super` are exactly the framework boundary — redmine's `mail` (209
units downstream), `identifier=` (65), `admin?` (33), `initialize` (33); mastodon's `current_user` (350),
`authorize` (340), `role` (33), `initialize` (24). Every one of these has its implementation in a gem, so
"the project's ancestry does not define it" is the truth about them and the taint is the honest answer.

**`rigor check`'s diagnostic stream is byte-identical between the arms** on both projects — 792
diagnostics on redmine, 2,349 on mastodon, zero added and zero removed, at every iteration, with only the
`stats` block (wall time, RSS) differing. Neither project declares an envelope, and a taint never
produces a finding, so all of the movement lands in the report and in a judgment nobody here opted into.
That is the expected shape of a change that fixes a *false negative*: it can only ever fire where an
author wrote a bound.

## Cost

ADR-103 WD13 budgets the collection path, so the edge has to be priced. Seven cold interleaved
iterations per arm — six on redmine's `off` arm, whose first is set aside below; the numbers are
`rigor check`'s own `wall_seconds`, which excludes process startup.
Both arms analysed the same positive file count — 347 on redmine, 1,312 on mastodon — at every iteration.

| project | arm | wall (s), range | median | peak RSS (MB) |
| --- | --- | --- | --- | --- |
| redmine | off | 9.33 – 9.69 (n=6) | 9.52 | 414 – 436 |
| redmine | on | 9.41 – 9.61 | 9.54 | 416 – 424 |
| mastodon | off | 13.89 – 14.53 | 14.17 | 697 – 712 |
| mastodon | on | 13.65 – 14.37 | 14.16 | 677 – 716 |

The ranges overlap completely in both projects and in both metrics; the medians differ by less than the
spread within either arm. **No cost is detectable at this sample size**, which is the expected shape: the
collector adds one edge per `super` node — 166 and 114 in these two projects, against tens of thousands
of ordinary call edges — and the propagator's resolution is memoised on the same tuple as every other
edge.

Two things this measurement is not:

- The host was **shared with three other agent sessions** working in the same repository for the whole
  run. That is why the arms are interleaved and why the ranges are carried rather than a single median:
  the claim being made is "the two arms are indistinguishable under identical conditions", which
  interleaving supports, and not "collection costs 9.54 s", which this host cannot say.
- The first run of the session (redmine, off arm, iteration 1) came in at 15.78 s against a 9.33 – 9.69 s
  range for its own arm. It is excluded above as a session warm-up — the first cold run pays a bundled-RBS
  build the rest of the session does not — and it is recorded here rather than silently dropped. Including
  it would have made the *unfixed* arm look 6 s slower, which is exactly the direction a reader should be
  suspicious of.

## What this does not answer

The `unresolved-super` rate is a function of how much of a project's ancestry is a gem, and both projects
here are Rails. A library with an in-project class hierarchy would resolve nearly all of its `super`
calls and see the label movement without the hedge; nothing here measures that shape.
