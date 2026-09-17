# The controller → template effect edge — corpus measurement

Status: measurement note for [#1048](https://github.com/rigortype/rigor/issues/1048); the design
commitments are in the PR and in
[`effect-labels.md`](../type-specification/effect-labels.md) § The plugin stratum. Taken against the
branch `controller-template-effect-edge-1048`, base `00714154` (which carries the #393 ERB template
units), Ruby 4.0.5.

Two sub-changes ship together and they are measured **apart**, because a label-set diff cannot tell
them from each other otherwise (§ 3):

1. the **edge** — an `EffectAttribution#callee:` rule that turns a `render` site into a call-graph edge
   to the template's own `view:` unit, plus the unit-level rule for Rails' implicit render;
2. the **lane** — a first-party bundled plugin's discharging row moves from the declared lane to the
   proven one, which is what makes `views: strict` and `views: lenient` differ.

## Method

Both corpus projects were copied out of the survey checkouts first — the survey trees are never run in
place ([`docs/agents/measurement.md`](../agents/measurement.md)):

```sh
rsync -a --exclude .rigor --exclude .git ../rigor-survey/<name>/ tmp/corpus/<name>/
```

Each copy got the same minimal `.rigor.yml` — `paths: [app]`, `plugins: [rigor-activerecord,
rigor-actionpack]`, `effects: {enabled: true}`. The **baseline arm is the base commit unpacked with
`git archive`**, not a second worktree: a worktree checkout's bundler cannot materialise gems for that
worktree's `Gemfile` path, and every baseline run would error to empty JSON and report a bogus
`base=0`. Both arms run under the same Flake shell and the same bundle:

```sh
cd tmp/corpus/<name> &&
BUNDLE_GEMFILE=<w>/Gemfile BUNDLE_APP_CONFIG=<w>/.bundle BUNDLE_PATH=<w>/vendor/bundle \
  bundle exec <engine>/exe/rigor check --format json --no-stats --no-cache
```

All three of those bundler variables are load-bearing and none is in `measurement.md`'s recipe. redmine
ships a `.bundle/config` pointing `BUNDLE_PATH` at its own `vendor/bundle`, and cwd has to be the
target — so without them bundler reads *redmine's* Gemfile ("Please configure your
config/database.yml first") and then dies loading redmine's `json` native extension against a
different nixpkgs Ruby. ADR-90's target-bundle resolution still finds redmine's Erubi, because it reads
the target's config itself rather than the process's.

The `.rigor` cache directory is removed before every arm.

## 1. The false-positive gate

`rigor check --format json --no-stats --no-cache`, differenced as `(path, line, rule, message)`
multisets — and, as it turned out, byte for byte:

| Project | diagnostics before | after | **new** | removed |
| --- | ---: | ---: | ---: | ---: |
| redmine | 435 | 435 | **0** | 0 |
| mastodon | 1180 | 1180 | **0** | 0 |

Both JSON files are **byte-identical** between the arms. That is the expected shape rather than a
lucky one: neither sub-change can produce a diagnostic on its own. The edge adds call-graph edges and
removes taints, and taint is never a finding; the lane move only matters where a project declared an
`effects.envelopes:` stanza, and neither corpus config does. A project that *does* declare one is
exactly who this change is for, and is not measurable here — the fixture in
`spec/integration/plugins/actionpack_template_edge_spec.rb` is.

## 2. What the edge reaches

`rigor effects --format json --full`, same two arms.

| Project | `.erb` | Haml | `view:` units | `template-not-analysed` causes, before → after | **discharged** |
| --- | ---: | ---: | ---: | ---: | ---: |
| redmine | 506 | 0 | 502 | 253 → 144 | **109** |
| mastodon | 46 | 310 | 44 | 329 → 329 | **0** |

**270 of redmine's controller actions gained at least one effect label**, and 314 units in total did.
Every label is one a template it really renders carries: redmine's view units carrying an `io.db.*`
row went from 35 (the #393 count) to 60 once partial edges and the lane move are both in.

**mastodon discharges nothing, and that is the honest answer rather than a gap.** 310 of its 356 views
are Haml, `template_globs:` claims `*.erb` only, and its controllers overwhelmingly render Haml — so
the render sites resolve to keys no unit answers, the edge is dropped, and the row's taint is seeded
back by the propagator. It is the negative control this feature most needed: a render whose template
was never analysed must not read as exhaustive, and 329 of them still do not.

`git archive`-based baselines aside, the two numbers to keep are **109 taints discharged and 0 new
diagnostics**.

### Pooled versus sequential

The **effect table is byte-identical** between `RIGOR_RACTOR_WORKERS=2` and sequential on redmine —
3 579 457 bytes of `effects --format json --full`, the same 502 `view:` rows, the same 144 residual
taints. The edges the new rules record are ordinary `FileCollection::Edge` values sorted by
`freeze_edges`, and `taint_if_unresolved` is in that sort key, which is what a Data member added to an
edge has to be for a marshalled worker collection and a sequential one to stay `==`.

## 3. Why the sub-changes are measured apart

A naïve before/after label diff credits the lane move with gains it did not make, and the reason is the
**rendering rule**: where a summary is printed, a declared label the same summary's proven lane already
admits is dropped. `Settings::ImportsController#create` on mastodon read

```
effects: [io, mutate.self, nondet.time]        declared: [rails.response.write]
```

before, and `io.db.read` / `io.db.write` / `io.db.transaction` after. Nothing was discovered: those
three were *already* in the declared lane and hidden, because the proven lane carried bare `io` and
`io.db.read` is under it. Moving them to proven only made them visible.

So the third arm — the branch with the lane move reverted and the edge kept — was run on both projects,
and the deltas attribute cleanly:

| Project | sub-change | units gaining a label | of them controller actions | taints discharged |
| --- | --- | ---: | ---: | ---: |
| redmine | the edge | 314 | 270 | 109 |
| redmine | the lane | 1 | 0 | 0 |
| mastodon | the edge | 1 | 0 | 0 |
| mastodon | the lane | 9 | 2 | 0 |

Every unit the lane move "gains" is a rendering-rule unmasking of this kind. The edge's own effect is
the whole of redmine's column, and mastodon's near-zero is the Haml result above.

## Not measured, deliberately

- **A project with an `effects.envelopes:` stanza.** The lane move's entire user-visible consequence is
  that an envelope now judges what a first-party plugin says a framework method does. Neither corpus
  config declares one, so the corpus is silent about it by construction and the spec fixture carries
  the `views: strict` / `views: lenient` pair instead.
- **Layouts.** Every layout is still a declined unit ([#1047](https://github.com/rigortype/rigor/issues/1047)),
  so a `render layout:` inside a template keeps its taint. That is deliberate and pinned by spec; it is
  also a floor on the 144 residual taints on redmine rather than a measurement of them.
- **Haml / Slim / Jbuilder.** Same seam, different compiler, still unclaimed — and mastodon is now the
  evidence for how much that costs.
- **`render partial:, collection:` counted rather than reached.** `collection:` changes how many times a
  partial runs and not which one, and an effect summary is an upper bound over the body rather than a
  count, so the rule reads the option and ignores it.
