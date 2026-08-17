# Rails effect layer — corpus measurement, before and after (#387)

Status: measurement note, no design commitments. Taken on branch
`claude/effect-labels/11-rails-layer`. "Before" is its base, commit `426d2e6d` (the declared-lane
slice): plugins carry no effect contract at all. "After" is the same run with the same plugin list,
now that each Rails plugin carries `effect_attributions:` / `effect_edges:` and rigor-activerecord's
bundled `sig/active_record/relation.rbs` carries `%a{…}`. "+railties" adds the new
`rigor-railties` plugin, which is the recommended Rails setup and is what carries the `Rails.`
namespace.

## Harness

The same shape as [`20260817-effect-catalogue-corpus.md`](20260817-effect-catalogue-corpus.md). Each
scratch config is the project's own committed `.rigor.dist.yml` with `baseline:` removed and three
keys added — `effects: {}`, `parallel: {workers: 0}` and a scratch `cache.path`. The cache directory
is wiped before every run, so every measurement is cold. Nothing was written into a survey checkout.

```sh
cd ~/repo/ruby/rigor-survey/<project>
BUNDLE_GEMFILE=<root>/Gemfile bundle exec <root>/exe/rigor \
  effects --format json --full app lib --config <scratch>/<project>-fx.yml

# the WD13 budget
BUNDLE_GEMFILE=<root>/Gemfile /usr/bin/time -l bundle exec <root>/exe/rigor \
  check --no-ci-detect app lib --config <scratch>/<project>-{check,fx-railties}.yml
```

Everything runs inside the Nix Flake (the survey checkouts' own bundles have no native extensions
built for this Ruby). Survey checkouts: redmine `a12198ea0`, mastodon `163f96cee` (v4.6.3). Plugin
lists are each project's own: actionpack, activerecord, actionmailer, rails-routes, rails-i18n,
activesupport-core-ext — plus railties in the third column.

## Coverage

| | redmine | | | mastodon | | |
| --- | --- | --- | --- | --- | --- | --- |
| | before | after | +railties | before | after | +railties |
| methods | 4,029 | 4,683 | 4,683 | 7,361 | 8,355 | 8,355 |
| with ≥1 **declared** label | 0 | **1,320** | **1,575** | 0 | **2,471** | **2,969** |
| declared label instances | 0 | **3,134** | **3,967** | 0 | **3,959** | **7,647** |
| with ≥1 proven label | 1,788 | 2,154 | 2,154 | 2,830 | 3,349 | 3,349 |
| proven label instances | 3,975 | 5,280 | 5,280 | 4,543 | 5,287 | 5,287 |

The method count rises because framework edges materialise as **synthetic units** on the framework
class (`Issue#save` edged to its callbacks, `WelcomeJob.perform_now` to `perform`): 654 on redmine,
994 on mastodon. Everything below that compares like with like is computed on the 4,029 / 7,361
methods common to both runs.

Proven labels rising is the edges' doing, not the attributions': a plugin row lands in the declared
lane only, but a synthetic `Issue#save` unit pulls each model's callbacks into every caller of
`save`, and `UserMailer.welcome(u)` now reaches the mailer body. Redmine's `io.net` 25 → 214 and
`mutate.self` 1,275 → 1,635 are that closure.

### What the Rails layer actually named

Declared label instances, after / +railties:

| label | redmine | mastodon |
| --- | --- | --- |
| `io.db.read` | 680 / 680 | 1,922 / 1,922 |
| `io.db.write` | 238 / 238 | 469 / 469 |
| `io.db.transaction` | 86 / 86 | 78 / 78 |
| `io.db` (raw SQL, verb not literal) | 57 / 57 | 25 / 25 |
| `rails.i18n.translate` | 664 / 664 | 394 / 394 |
| `rails.response.write` | 371 / 371 | 408 / 408 |
| `rails.config.read` | 0 / 502 | 0 / 1,365 |
| `rails.flash.write` | 123 / 123 | 8 / 8 |
| `rails.session.write` / `.read` | 51 / 33 | 2 / 1 |
| `rails.cookie.write` | 11 / 11 | 0 / 0 |
| `cache.read` / `cache.write` | 0 / 0 | 0 / 108 · 408 |
| `telemetry` | 5 / 63 | 1 / 264 |
| `global.read` | 512 / 727 | 362 / 1,263 |

Two readings worth keeping. First, **the framework labels are the ones that moved**: a Rails app's
effect surface is overwhelmingly `io.db.read`, translation and response writing, and none of those
was visible at all before. Second, **railties is where the ambient half lives**: `rails.config.read`,
`cache.*` and most of `telemetry` are zero without it, which is the whole argument for it being its
own plugin rather than rows scattered across whichever Rails plugin a project happened to enable.

`io.db` at 57 / 25 is raw SQL whose leading verb was not a literal — the `sql_verb` handler's honest
degradation. Redmine's `IssueQuery` is where nearly all of it is.

## Exhaustiveness

| | redmine | mastodon |
| --- | --- | --- |
| before | 649 / 4,029 (16.1%) | 1,288 / 7,361 (17.5%) |
| after | 655 (16.3%, **+0.2pp**) | 1,289 (17.5%, **+0.0pp**) |
| +railties | 667 (16.6%, **+0.5pp**) | 1,298 (17.6%, **+0.1pp**) |

**First-party discharge barely moves the whole-method exhaustive ratio, and that is not a
disappointment — it is the metric being the wrong shape for the effect.** Discharge is per *site*:
it stops `Rails.env` and `user.save` from tainting, which is real and is why `Report#environment`-shaped
methods now read exhaustive at all. But a method is exhaustive only when *every* site in it is, and
on a Rails app the dominant cause is `unresolved-self-call` (10,281 → 15,652 on redmine), which is a
Ruby-dispatch fact the Rails layer has nothing to say about. The 654 synthetic units are themselves
only 98/654 exhaustive, because a callback body is ordinary application code with ordinary unresolved
self-calls in it.

`template-not-analysed` appears for the first time: 249 on redmine, 329 on mastodon — one per
controller method that renders. That is the ADR-103 WD11 debt made visible and countable, which is
what a taint cause is for.

## The WD13 budget: cost when effects are on

Cold `rigor check` over `app lib`, sequential, same cache-wiped conditions, with and without the
`effects:` block (the `+railties` config, i.e. the fullest plugin set):

| | wall | Δ | peak RSS | Δ |
| --- | --- | --- | --- | --- |
| redmine, effects off | 8.77 s | | 393.6 MB | |
| redmine, effects on | 9.07 s | **+3.4 %** | 406.5 MB | **+3.3 %** |
| mastodon, effects off | 12.82 s | | 663.8 MB | |
| mastodon, effects on | 13.26 s | **+3.4 %** | 666.3 MB | **+0.4 %** |

Both inside WD13's ≤ 5 % working budget, and the plugin layer adds nothing measurable over the
collection cost the previous slices already measured: the compiled tables are per-process, the
per-call lookup is two Hash reads plus a capped superclass walk, and `Registry#effect_contributions`
is lazy, so a run with effects **off** does not even read `config/application.rb` for the queue
adapter.

## One bug this measurement found

The first pass showed redmine's `io.db.read` at **7**, against 680 here. The cause was the runner
memoising the compiled plugin tables unconditionally on first use: on the sequential path the
cross-file discovery pre-pass fills the superclass table *after* the first file has already asked, so
the whole run was pinned to an empty ancestry and `Issue.find` on a
`Issue < ApplicationRecord < ActiveRecord::Base` matched nothing. A pooled run hid it completely —
its workers are seeded with the finished table before they fork — which is exactly the shape of
defect a corpus run exists to catch. The memo is now keyed on the ancestry table's identity, and
`spec/rigor/effects/rails_layer_spec.rb` runs the fixture with `workers: 0` to keep it caught.
