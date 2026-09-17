# The controller → template effect edge — corpus measurement

Status: measurement note for [#1048](https://github.com/rigortype/rigor/issues/1048); the design
commitments are in the PR and in
[`effect-labels.md`](../type-specification/effect-labels.md) § The plugin stratum. Taken against the
branch `controller-template-effect-edge-1048`, base `00714154` (which carries the #393 ERB template
units), Ruby 4.0.5.

Two things were built. **One shipped:**

1. the **edge** — an `EffectAttribution#callee:` rule that turns a `render` site into a call-graph edge
   to the template's own `view:` unit, plus the unit-level rule for Rails' implicit render.

**One did not.** Moving a first-party bundled plugin's discharging row from the declared lane to the
proven one is what would make `views: strict` and `views: lenient` differ — and it contradicts
[ADR-103](../adr/103-effect-labels.md) WD17, an owner ruling that weighed exactly that and declined it.
It was built and measured and then reverted; § 3 is its measurement, kept because the open question
([#1059](https://github.com/rigortype/rigor/issues/1059)) needs a blast radius and this is it.
**Measured, not shipped.**

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

Both JSON files are **byte-identical** between the arms. That is the expected shape rather than a lucky
one: the edge adds call-graph edges and removes taints, and taint is never a finding. It held for the
unshipped lane move too, for a different reason — that one only matters where a project declared an
`effects.envelopes:` stanza, and neither corpus config does, which is worth knowing on its own: the
corpus is silent about the lane by construction.

## 2. What the edge reaches

`rigor effects --format json --full`, same two arms.

| Project | `.erb` | Haml | `view:` units | `template-not-analysed` causes, before → after | **discharged** |
| --- | ---: | ---: | ---: | ---: | ---: |
| redmine | 506 | 0 | 502 | 253 → 146 | **107** |
| mastodon | 46 | 310 | 44 | 329 → 329 | **0** |

**291 of redmine's controller actions gained at least one effect label**, and 335 units in total did.
Every label is one a template it really renders carries: redmine's view units carrying an `io.db.*`
row went from 35 (the #393 count) to **60**, which is the template → partial edge and nothing else —
the lane move does not move that number.

Three of the rules narrow the count, and each was a false positive found in review rather than in the
corpus:

- a `responds:` call is only recorded at the unit's **top level**. `redirect_to "/" if @user.nil?`
  answers on one path and leaves the other taking Rails' implicit render, so standing the unit rule
  down there would drop the template edge *and* leave the action reading exhaustive. This is what took
  the controller-action count from 270 to 291;
- a **`private` / `protected`** member never takes the implicit render, because Rails'
  `action_methods` is public only — a `private def card` beside an `app/views/users/card.html.erb`
  would otherwise be handed that template's effects. This is what took the discharge count from 109
  to 107;
- a written handler or format is split off the name, so `render template: "users/show.html.erb"` reaches
  `view:users/show.html` rather than the key `view:users/show.html.erb.html`, which nothing could ever
  answer.

**mastodon discharges nothing, and that is the honest answer rather than a gap.** 310 of its 356 views
are Haml, `template_globs:` claims `*.erb` only, and its controllers overwhelmingly render Haml — so
the render sites resolve to keys no unit answers, the edge is dropped, and the row's taint is seeded
back by the propagator. It is the negative control this feature most needed: a render whose template
was never analysed must not read as exhaustive, and 329 of them still do not.

The two numbers to keep are **107 taints discharged and 0 new diagnostics**.

### Pooled versus sequential

The **effect table is byte-identical** between `RIGOR_RACTOR_WORKERS=2` and sequential on redmine —
3 627 649 bytes of `effects --format json --full`, the same 502 `view:` rows, the same 146 residual
taints. The edges the new rules record are ordinary `FileCollection::Edge` values sorted by
`freeze_edges`, and `taint_if_unresolved` is in that sort key, which is what a Data member added to an
edge has to be for a marshalled worker collection and a sequential one to stay `==`.

## 3. The lane move: measured, not shipped

Everything below describes a change this PR **reverted**. `EnvelopeCheck` reads the proven lane, plugin
attributions ride the declared one, so no envelope can judge any label a Rails plugin contributes and
the `views: strict` / `views: lenient` pair cannot differ. Promoting a first-party bundled discharging
row into `proven` fixes that and contradicts ADR-103 WD17's owner ruling, which is not a lane's call to
overturn. The numbers are kept here because [#1059](https://github.com/rigortype/rigor/issues/1059)
needs them.

The measured blast radius is **10 bundled plugins**, not "the Rails layer": rigor-actionpack 12
`discharge: true` rows, railties 8, activejob 3, activerecord 3, actionmailer 2,
activesupport-core-ext 2, rails-i18n 2, sidekiq 2, actioncable 1, activestorage 1 — and each row is a
whole family in the reports, since several are built in a `map` over a selector list. The spec suite's
reaction was 18 examples in `spec/rigor/effects/rails_layer_spec.rb`, all mechanical `declared` →
`proven`. Corpus diagnostics were byte-identical with it as without.

### Why the sub-changes had to be measured apart

A naïve before/after label diff credits the lane move with gains it did not make, and the reason is the
**rendering rule**: where a summary is printed, a declared label the same summary's proven lane already
admits is dropped. `Settings::ImportsController#create` on mastodon read

```
effects: [io, mutate.self, nondet.time]        declared: [rails.response.write]
```

before, and `io.db.read` / `io.db.write` / `io.db.transaction` after. Nothing was discovered: those
three were *already* in the declared lane and hidden, because the proven lane carried bare `io` and
`io.db.read` is under it. Moving them to proven only made them visible.

So a third arm — the edge kept, the lane move reverted — was run on both projects, and the deltas
attribute cleanly (taken before the three narrowing rules above, so the edge column reads 314 / 270 /
109 rather than the shipped 335 / 291 / 107):

| Project | sub-change | units gaining a label | of them controller actions | taints discharged |
| --- | --- | ---: | ---: | ---: |
| redmine | the edge | 314 | 270 | 109 |
| redmine | the lane | 1 | 0 | 0 |
| mastodon | the edge | 1 | 0 | 0 |
| mastodon | the lane | 9 | 2 | 0 |

**Every one of the 10 units the lane move "gains" is a rendering-rule unmasking of this kind, and none
is a new fact.** That is the single most useful thing the run produced for #1059: the promotion's
visible effect on two real Rails applications is to reveal labels that were already there, which is an
argument about presentation rather than about what `proven` means.

## Not measured, deliberately

- **A project with an `effects.envelopes:` stanza.** The lane move's entire user-visible consequence
  would be that an envelope judges what a first-party plugin says a framework method does. Neither
  corpus config declares one, so the corpus is silent about it by construction — which is exactly why
  the decision in #1059 cannot be settled by a corpus sweep.
- **Layouts.** Every layout is still a declined unit ([#1047](https://github.com/rigortype/rigor/issues/1047)),
  so a `render layout:` inside a template keeps its taint. That is deliberate and pinned by spec; it is
  also a floor on the 146 residual taints on redmine rather than a measurement of them.
- **Haml / Slim / Jbuilder.** Same seam, different compiler, still unclaimed — and mastodon is now the
  evidence for how much that costs.
- **`render partial:, collection:` counted rather than reached.** `collection:` changes how many times a
  partial runs and not which one, and an effect summary is an upper bound over the body rather than a
  count, so the rule reads the option and ignores it.
