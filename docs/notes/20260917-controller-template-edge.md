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

| Project | `.erb` | Haml | `view:` units | `template-not-analysed` causes, before → after |
| --- | ---: | ---: | ---: | ---: |
| redmine | 506 | 0 | 502 | 253 → 148 |
| mastodon | 46 | 310 | 44 | 329 → 329 |

The net hides the thing worth reporting, so the causes are split by the row that produced them:

| Project | `ActionController::Base#render` | `ActionController::Base#render_to_string` | `ActionView::Base#render` |
| --- | ---: | ---: | ---: |
| redmine | 251 → **76** | 2 → **0** | 0 → **72** |
| mastodon | 328 → 328 | 0 → 0 | 0 → 0 |

**177 of redmine's controller-side render taints are discharged** — that is the feature. The 72 that
appear on the template side are not a regression and not a loss: before this change a `render` *inside*
a template contributed nothing at all, and a partial-rendering view read exhaustive while saying nothing
about what it rendered. They are the plugin saying, for the first time, "this template renders something
I did not analyse". They propagate into their controllers like any other cause, which is the whole of
the difference between 177 and the net 105.

### What those 72 actually are

Worth listing, because the obvious guess is wrong. 57 `view:` units carry a cause of their own and the
other ~15 are propagations. **No edge in either group points at a unit that exists**, so the resolver is
not dropping anything it could have found — and 34 of the 57 are one shape:

| Group | units | What |
| --- | ---: | --- |
| `.js.erb` rendering an HTML-only partial | **34** | `watchers/_set_watcher.js.erb` does `render partial: 'watchers/watchers'`, which exists only as `_watchers.html.erb`. The format travels from the enclosing unit, so the key is `view:watchers/_watchers.js` — and Rails resolves it, because a request for `[:js]` falls back through `[:js, :html]`. Filed as [#1065](https://github.com/rigortype/rigor/issues/1065). |
| `.html.erb`, mixed | 22 | dynamic partial names (`render partial: @thing`), the view-side `render :layout => "…"` form, and layouts, which are still declined units ([#1047](https://github.com/rigortype/rigor/issues/1047)). |
| one `.js` layout render | 1 | the same as the row above, one format over. |

So the largest single remaining gap is a **format fallback**, not the layout gap. That was the useful
thing this attribution produced, and it was not visible from the net.

**298 of redmine's controller actions gained at least one effect label**, and 342 units in total did.
Every label is one a template it really renders carries: redmine's view units carrying an `io.db.*`
row went from 35 (the #393 count) to **60**, which is the template → partial edge and nothing else —
the lane move does not move that number.

Four of the rules move the count, and every one of them came out of review rather than out of the
corpus — which is worth saying plainly: **the corpus could not have found any of them**, because each
is a shape whose cost is a missing or a spurious label and neither is a diagnostic.

- a `responds:` call is only recorded at the unit's **top level**, and a **block or lambda is
  branching**.
  `redirect_to "/" if @user.nil?` answers on one path and leaves the other taking the implicit render;
  so does `User.transaction { redirect_to "/" }`, and so does the HTML arm of
  `respond_to { |f| f.html; f.json { render json: @user } }` — the single most common Rails idiom,
  where the JSON arm's answer was standing the HTML arm's template down. So does `@after = -> {
  redirect_to "/" }`, which stores a response rather than performing one. Recording a response in any
  of them drops the template edge *and* leaves the action reading exhaustive. Took the
  controller-action count from 270 to 298;
- the exception is `respond_to`'s **own** block, which is a format dispatcher rather than a branch. Its
  arms are ordinary blocks, so `format.html { render :show }` keeps the conventional edge beside the
  one the `render` names — an accepted over-approximation, since an edge is labels and never a taint;
- a **`private` / `protected`** member never takes the implicit render, because Rails'
  `action_methods` is public only — a `private def card` beside an `app/views/users/card.html.erb`
  would otherwise be handed that template's effects. `public :foo` subtracts and a `def self.x` inside
  a region marks nothing, or the same rule would mark public actions private from the other side;
- a written handler or format is split off the name, so `render template: "users/show.html.erb"` reaches
  `view:users/show.html` rather than the key `view:users/show.html.erb.html`, which nothing could ever
  answer.

**mastodon discharges nothing, and that is the honest answer rather than a gap.** 310 of its 356 views
are Haml, `template_globs:` claims `*.erb` only, and its controllers overwhelmingly render Haml — so
the render sites resolve to keys no unit answers, the edge is dropped, and the row's taint is seeded
back by the propagator. It is the negative control this feature most needed: a render whose template
was never analysed must not read as exhaustive, and 329 of them still do not.

The two numbers to keep are **177 controller-side render taints discharged and 0 new diagnostics**.

### Pooled versus sequential

The **effect table is byte-identical** between `RIGOR_RACTOR_WORKERS=2` and sequential on redmine —
3 653 853 bytes of `effects --format json --full`, the same 502 `view:` rows, the same 148 residual
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
attribute cleanly (taken before the four rules above, so the edge column reads 314 / 270 / 109
rather than the shipped 342 / 298 / 175-minus-72):

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
  part of the 148 residual taints on redmine rather than a measurement of them — and a smaller part
  than the `.js` → `.html` format fallback of
  [#1065](https://github.com/rigortype/rigor/issues/1065), which is 34 of the 57 tainted `view:` units.
- **Haml / Slim / Jbuilder.** Same seam, different compiler, still unclaimed — and mastodon is now the
  evidence for how much that costs.
- **`render partial:, collection:` counted rather than reached.** `collection:` changes how many times a
  partial runs and not which one, and an effect summary is an upper bound over the body rather than a
  count, so the rule reads the option and ignores it.

## 2026-09-18 — the `.js` → `.html` format fallback ([#1065](https://github.com/rigortype/rigor/issues/1065))

Taken against the branch `js-format-html-fallback-1065`, base `121620ed` (which carries #1066's
render-site locals and layout units, so the base numbers are not § 2's), with the method above: private
`rsync` copies, the baseline arm unpacked with `git archive`, the same bundler variables, `.rigor`
removed before every arm.

The change: rigor-actionpack's view `render` row carries `callee_fallbacks: { "js" => ["html"] }`,
`rails_render_partial` copies it onto the edge for a format it inherited from the enclosing unit, and
the propagator takes the first of `js`, `html` that a unit answers, seeding the row's taint only when
neither does.

### The false-positive gate

| Project | diagnostics before → after | effects off |
| --- | ---: | --- |
| redmine | 435 → 435, **byte-identical** | byte-identical |
| mastodon | 1180 → 1180, **byte-identical** | not run — its effect table is byte-identical too |

### Taints, by the producing row

| Project | `ActionController::Base#render` | `#render_to_string` | `ActionView::Base#render` | total |
| --- | ---: | ---: | ---: | ---: |
| redmine | 76 → 76 | 0 → 0 | 64 → **31** | 140 → 107 |
| mastodon | 328 → 328 | 0 → 0 | 0 → 0 | 329 → 329 (one `render_to_body`) |

`view:` units carrying a `template-not-analysed` cause on redmine: **50 → 17**. Of the 64 `.js` units,
**34 carried one and 1 still does** — `imports/mapping.js.erb`, whose
`render :partial => "#{import_partial_prefix}_mapping"` is a computed name the rule declines before any
format question arises. The 15 `.html` units are untouched. mastodon's whole `effects --format json
--full` output is byte-identical, which is the expected answer: it has no `.js.erb` view.

### What the 33 resolved edges bought

Less than the taint count suggests, and worth saying so:

- **0 units became exhaustive.** Each of the 33 swaps its `template-not-analysed` cause for the causes
  the HTML partial really carries — 348 `unresolved-self-call`, 30 `dynamic-receiver`, 10
  `unknown-ownership` entries across them. That is the honest direction: the old cause said "not
  analysed", the new ones say what the analysis found.
- **4 units gained a label**, all views: `groups/add_users.js` and `members/edit.js` gain `io.db.read`,
  `issues/edit.js` and `issues/new.js` gain `io.db.read` and `mutate.self`. No unit lost a label.
- **0 controller actions gained anything.** redmine reaches its `.js.erb` templates through
  `respond_to { |format| format.js }`, and the implicit-render rule edges an action to
  `<controller>/<action>.html` only. So a partial's effects now reach the `.js` template, and stop
  there until an action's `format.js` arm is edged to its `.js` unit — a separate change to the unit
  rule, not to the fallback.

One over-approximation the fallback makes newly reachable: a partial reached through it renders its
own partials in `html`, while Action View's context is still `[:js, :html]` and would try `.js` first.
Where a nested partial exists in both formats, the `.js` template gets the `.html` one's labels. The
count on redmine is **0** — its only dual-format partials, `imports/_{issues,users,time_entries}_mapping`,
are rendered only through a computed name.

Two shapes the fallback must NOT resolve past, found in review and fixed before landing: a template
whose file exists and whose plugin produced no unit — an ERB whose compiled Ruby does not parse, and a
handler the plugin does not compile at all. Action View runs those files, so the other format's effects
are not what the render produces. `TemplateUnits#declined_unit_keys` carries them (derived from the
paths the plugin read and the root prefix its own logical names imply) and the propagator stops there.
rigor-actionpack now claims `app/views/**/*.{haml,slim,jbuilder,builder,rabl,ruby}` and declines every
one of them, which is how the engine learns those templates exist: **313 declined keys on mastodon**
(its Haml views) and **2 on redmine** (`common/feed.atom.builder`, `journals/index.builder`). Neither
project has a case where the block changes an edge — redmine's 33 resolutions are unchanged and
mastodon's effect table is byte-identical — so the block is protection rather than a measured recovery.
An unclaimed handler stays invisible and its fallback fires as if no template were there.

The zero in the controller-actions row is [#1071](https://github.com/rigortype/rigor/issues/1071):
a `respond_to { |format| format.js }` arm is how redmine reaches a `.js.erb`, and the implicit-render
unit rule edges only to `<action>.html`.

### Pooled versus sequential

redmine's `effects --format json --full` is **byte-identical** between `RIGOR_RACTOR_WORKERS=2` and `0`
— 3 562 580 bytes. `fallback_selectors` is in `freeze_edges`' sort key.
