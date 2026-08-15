# Unused-constant false-positive baseline — three-project corpus measurement for #345

Status: measurement note, no design commitments. Observations taken against the `#345` probe
worktree @ `3b236b8b`, macOS arm64, Ruby 4.0.5, 2026-08-13.

## Why

[#345](https://github.com/rigortype/rigor/issues/345) asks whether Rigor's analysis substrate can
carry a `rigor unused` reachability report. The naive form of the question — "which project-owned
constants did no resolved constant reference point at?" — has a known-terrible false-positive rate
on Rigor's own `lib/` (99.7 %). This note measures the same funnel on three real Rails applications
and, on one of them, hand-adjudicates every survivor so the number has a true-positive ratio
attached to it. A count without that ratio is not a result.

The funnel is shaped after the source article's `631 → 9 → 3 → 2` decay: start from the naive count,
then apply successively more expensive root-set knowledge and watch how much each stage buys.

> **The instrument described below no longer exists in the tree.** It was spike scaffolding in four
> engine files plus `tool/unused_probe/`, kept only until the slices that needed to re-measure against
> this baseline had landed (#348, #349, #350). With those done and `rigor unused` shipping as the real
> implementation, it was removed. To reproduce the runs in this note, check out the harness from git
> history — `3b236b8b` added it and `7a1cfaba` added the stage filter — or, for anything forward-looking,
> use `rigor unused`, which supersedes it and measures the same population more accurately.

## Method

The instrumentation is `lib/rigor/unused_probe.rb` (gated on `RIGOR_UNUSED_PROBE`, five hook sites,
inert when unset) plus `tool/unused_probe/{run.sh,report.rb,stages.rb}`. `run.sh` forces
`--no-cache --workers=0`; `report.rb` **exits 2 rather than printing a number** if the dump shows
workers ≠ 0, a cache store attached, or zero recorded references. Every run below cleared those
guards, and every reference count is reported so a silent-failure run is visible as such.

The corpus projects are read as data. Nothing in them was modified, and no `.rigor.yml` was written
— path widening is expressed as positional arguments to `rigor check`, which override
`configuration.paths`.

### Reproduction

From the probe worktree, inside the Nix flake:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  tool/unused_probe/run.sh ~/repo/ruby/rigor-survey/redmine /tmp/redmine-naive.json

nix --extra-experimental-features 'nix-command flakes' develop --command \
  tool/unused_probe/run.sh ~/repo/ruby/rigor-survey/redmine /tmp/redmine-wide.json app lib config

nix --extra-experimental-features 'nix-command flakes' develop --command \
  ruby tool/unused_probe/stages.rb /tmp/redmine-wide.json \
    --project ~/repo/ruby/rigor-survey/redmine --list
```

Substitute `~/repo/ruby/rigor-survey/mastodon` and `~/repo/ruby/conference-app` for the other two
targets; the argument list `app lib config` is the same for all three (each target's `paths:` is
`app`, `lib`, and each has a `config/` that was not in it). Corpus revisions: redmine `a12198ea0`,
mastodon `163f96cee`, conference-app `3e54d61`.

### The four stages

1. **Naive** — the target's configured `paths:` as-is.
2. **Widened root** — `config/` added to the analysed paths.
3. **Route roots** — subtract controllers reachable from `config/routes.rb`, using the
   **deliberately rough** extractor in `tool/unused_probe/stages.rb`. It is a line-oriented regex
   scan, not a Rails router: `do`/`end` counting for `namespace` / `module:` nesting, `resources` /
   `resource` symbol lists, `:controller =>` / `controller:` options, `controllers x: 'y'` maps, and
   `"controller#action"` strings. `resource :x` (singular) contributes both `XController` and
   `XsController` because there is no inflector; matching is on the full constant name **or** its
   demodulized tail, so it over-subtracts. Over-subtraction is the safe direction for an
   FP-baseline: it makes the surviving number a lower bound on the FP problem, not an upper one.
   The real root extraction is [#349](https://github.com/rigortype/rigor/issues/349).
4. **Dynamic-resolution demotion** — move to a separate "cannot decide" bucket every candidate that
   (d1) has an enclosing namespace appearing as a literal prefix of a `constantize` /
   `safe_constantize` / `const_get` / interpolated construction, (d2) appears verbatim inside a Ruby
   string or symbol literal, or (d3) appears — as FQN, autoload-path form, or underscored tail — in
   an ERB / HAML / SLIM / YAML / locale / JSON file under `app`, `lib`, `config`, `db`.

### Tier reported

The **class/module constant tier** is the headline. The value-constant tier is known-broken:
`Scope#in_source_constants` is per-file by design and value constants are not carried in the
cross-file project seed, so a value constant read from another file never resolves and the candidate
is spurious by construction. Its counts appear below for completeness, labelled UNRELIABLE, and no
adjudication effort was spent on them.

## Run shape (the anti-silence check)

| target | stage | files | declared (owned) | distinct refs | source resolutions |
| --- | --- | ---: | ---: | ---: | ---: |
| redmine | naive | 347 | 697 | 609 | 33,736 |
| redmine | widened | 365 | 715 | 620 | 34,824 |
| mastodon | naive | 1,312 | 2,109 | 1,697 | 175,582 |
| mastodon | widened | 1,388 | 2,144 | 1,733 | 180,022 |
| conference-app | naive | 101 | 105 | 1,438 | 2,405 |
| conference-app | widened | 122 | 107 | 1,442 | 3,048 |

All six runs recorded `workers: 0`, `cache_enabled: false`, and a five- to six-figure resolution
count. conference-app's distinct-reference figure is dominated by the RBS path (1,411 of 1,442 names
come from `signature_paths:`), which is exactly why it is in the corpus: it is the only target that
exercises `record_rbs_decls`.

## Decay table — class/module constant tier

| target | 1 naive | 2 widened root | 3 route roots | 4 dynamic demotion | adjudicated true positives |
| --- | ---: | ---: | ---: | ---: | ---: |
| redmine | 135 | 136 | 82 | **57** | **4** |
| mastodon | 377 | 374 | 142 | **113** | not adjudicated |
| conference-app | 59 | 61 | 20 | **14** | not adjudicated |

Other tiers, for completeness (naive → widened):

| target | value constants (UNRELIABLE) | namespace-prefix artifacts |
| --- | --- | --- |
| redmine | 38 → 38 | 24 → 30 |
| mastodon | 86 → 89 | 91 → 95 |
| conference-app | 0 → 0 | 0 → 0 |

### Stage 2 buys nothing, and the reason is structural

Widening the analysed root moves the **declaration** set and the **reference** set together, because
both are gated on the same analysed-file predicate. The two effects very nearly cancel:

| target | files | declarations | distinct refs | net class candidates |
| --- | ---: | ---: | ---: | ---: |
| redmine | +18 | +18 | +11 | **+1** |
| mastodon | +76 | +35 | +36 | **−3** |
| conference-app | +21 | +2 | +4 | **+2** |

Adding `config/` to redmine added eighteen files, eighteen new project-owned declarations, and
eleven new resolved reference names — and the candidate count went *up* by one. On two of three
targets widening made the report slightly worse. This is worth stating plainly because "just analyse
more of the project" is the obvious first instinct and it is, measured, not a lever. It is still
correct to widen — `config/initializers` is where a lot of real references live — but the payoff has
to come from stage 3 and stage 4, not from stage 2.

Stage 3 is where the money is: −40 % on redmine, −62 % on mastodon, −67 % on conference-app. Stage 4
takes a further −30 %, −20 %, −30 %. The rough extractor is doing crude work and still dominates
every other stage combined.

## Redmine adjudication

All 57 survivors were hand-checked (not sampled), by grepping the whole redmine tree for each name
and reading the declaration site and any framework wiring involved.

**True positives — 4 of 57 (7.0 %).**

| constant | file | why it is genuinely dead |
| --- | --- | --- |
| `ChangesetNotFound` | `app/controllers/repositories_controller.rb:23` | `class ChangesetNotFound < StandardError; end` — the declaration is the only occurrence in the entire repository, tests included. |
| `ScmFetchError` | `app/models/repository.rb:20` | Same shape; never raised, never rescued, never named. |
| `Redmine::SudoMode::SudoRequired` | `lib/redmine/sudo_mode.rb:25` | Declared and mentioned once in a prose comment at line 91. Never raised. |
| `SvgIconHelper` | `app/helpers/svg_icon_helper.rb:20` | An empty `module SvgIconHelper; end`. The controller is `SvgIconsController` (plural), whose convention helper is `SvgIconsHelper`, which does not exist — so nothing ever includes this module. |

**False positives — 53 of 57**, in ten artifact classes:

| # | artifact class | mechanism | why the candidate is wrong |
| ---: | --- | --- | --- |
| 28 | Rails helper-module convention | `FooController` implicitly `helper`s `FooHelper` | The name is derived, never written. Redmine sets `include_all_helpers = false`, so the pairing is one-to-one and checkable — every one of these 28 has a matching controller (`GanttHelper` via an explicit `helper :gantt` in `gantts_controller.rb`). |
| 7 | registry self-registration | `Redmine::FieldFormat::*` call `add 'link'` in the class body, which does `Redmine::FieldFormat.add(name, self)` | The class registers *itself* into a string-keyed registry. The root marker is a DSL call inside the body, not a reference from outside. |
| 4 | Rails generator convention | `lib/generators/redmine_plugin*/…` | Reached by `rails generate redmine_plugin`, i.e. by file path and name. |
| 3 | reopened foreign class | `ActionView::Helpers::DateHelper`, `ActionController::MimeResponds`, `…::Collector` in `config/initializers/10-patches.rb` | **Ownership-predicate artifact, not a finding**: reopening a gem class registers it as a project declaration. These are not project constants at all. |
| 3 | test-runner roots inside `paths:` | `TreeTest*` in `lib/plugins/acts_as_tree/test/` | Minitest classes discovered by the runner. Also a configuration smell — a vendored plugin's `test/` directory is inside redmine's `lib` path. |
| 2 | reference lives in a `.rake` file | `Redmine::IMAP`, `Redmine::POP3`, both used by `lib/tasks/email.rake` | The reference exists inside `paths:` but in a file extension the analyser does not read. |
| 2 | dynamic construction the rough rule missed | `Redmine::WikiFormatting::{CommonMark,Textile}::HtmlParser` | Built by `"Redmine::WikiFormatting::#{name.classify}::#{m}".constantize`. Stage 4's d1 rule keys on the candidate's *immediate* parent namespace; the literal prefix here is two levels up. A correct rule must treat every namespace **at or below** a dynamic prefix as tainted. |
| 1 | inherited-scope constant lookup | `Redmine::Scm::Adapters::AbstractAdapter::ScmCommandAborted` | `rescue ScmCommandAborted` inside `class BazaarAdapter < AbstractAdapter` resolves through the *superclass* scope chain. The resolver's lexical walk does not model that, so a real, in-analysis-set reference is not recorded. This one is an engine gap, not a root-set gap. |
| 1 | `ActiveSupport::Concern` convention | `Redmine::SudoMode::Controller::ClassMethods` | `extend ActiveSupport::Concern` auto-extends a nested `ClassMethods` by name. |
| 1 | published extension point | `Redmine::Hook::ViewListener` | Subclassed only by out-of-tree Redmine plugins (and by `test/`). Exported API, dead only from inside the repository. |
| 1 | Rails validator convention | `DateValidator` | `validates :start_date, :date => true` becomes `"DateValidator".constantize`. Stage 4's top-level dynamic rule was restricted to `*Controller`; the same convention exists for validators, jobs, serializers, and more. |

### What this means arithmetically

The class/module tier's precision on redmine after four stages is **7.0 %** — one true finding for
every thirteen wrong ones. Two of the ten FP classes (helper convention, registry self-registration)
account for 35 of the 53 false positives, i.e. **66 % of the remaining FP mass sits in two rules**.

## Spot checks on the other two targets

Not adjudicated exhaustively; recorded because they identify the same artifact classes elsewhere.

- **conference-app** (14 survivors) reproduces the pattern almost exactly: 4 Rails helper-convention
  modules, 4 `active_decorator` decorators (the gem applies `FooDecorator` to `Foo` by name, so the
  root is a gem convention), 3 `alba` resource classes, `ApplicationCable` (a namespace-only module
  that the prefix-artifact rule failed to fold), `ApplicationMailer` (a Rails scaffold base class
  with no subclasses — arguably a fifth true positive of the same species as `SvgIconHelper`), and
  `TitoApiClient`, referenced only from `lib/tasks/tito.rake` — the identical `.rake` artifact
  redmine produced.
- **mastodon** (113 survivors) is dominated by controllers the rough route extractor did not reach:
  27 of the first 30 survivors are `*Controller` under `Api::V1::…`, `WellKnown::…`, `Auth::…`,
  `OAuth::…`. Mastodon splits routes across `config/routes/{admin,api,fasp,settings,web_app}.rb`
  with heavy `namespace` nesting and `resource … controller:` remapping; the regex scan extracted
  622 roots and still missed these. That is a statement about the extractor, not about mastodon —
  and it is the clearest single argument that #349 needs a real router-shaped extractor rather than
  a heuristic.

## What this means for #347 / #349

1. **The report can never be a diagnostic.** 7.0 % precision after four stages of root knowledge,
   on the most favourable of three targets, is far outside anything ADR-5 and the "false positives
   outrank worst-case static reading" guideline would tolerate as a check. It stays a report — an
   opt-in, human-read listing — and the surviving count is a *review queue*, not a defect count.
2. **Root sets are the whole game (#349).** Stage 3 alone removed 40–67 % of the class tier with a
   regex. Every stage-4 rule combined removed 20–30 %. Whatever budget exists should go to root
   extraction first, and the route extractor should be router-shaped, not regex-shaped — mastodon
   shows the heuristic falling over precisely where a real app is most complex.
3. **Two convention rules retire two thirds of the remaining FP mass.** The helper-module pairing
   (`FooController` ⇒ `FooHelper`, respecting `include_all_helpers`) and "a class whose body calls a
   registration DSL is a root" together cover 35 of redmine's 53 false positives, and the decorator
   and resource groups on conference-app are the same shape. Both are naturally
   plugin-API-shaped — `rigor-actionpack` already knows about controllers — which fits the standing
   guideline of steering convention knowledge out of the core.
4. **Two of the artifact classes are Rigor bugs, not root-set gaps**, and are worth splitting off
   from #347:
   - the **ownership predicate** counts a reopened gem/stdlib class as a project declaration
     (3 redmine candidates came from a single initializer). A declaration whose namespace is
     defined by an RBS the project did not author should never be a candidate.
   - the **superclass constant-scope walk** is missing: `rescue ScmCommandAborted` inside a subclass
     records no reference to `AbstractAdapter::ScmCommandAborted`. Isolated and filed as
     [#354](https://github.com/rigortype/rigor/issues/354), where it turned out to be worse than an
     under-recorded edge. `Reflection.lexical_constant_candidates` implements Ruby's lexical walk and
     its bare-name fallback but not the ancestor step between them, so when the same name also exists
     at top level the **bare-name fallback wins a lookup Ruby gives to the ancestor** — Rigor types
     `KEY` inside `class Sub < Base` as the top-level constant while Ruby resolves it to `Base::KEY`.
     That is a false positive on correct code, independent of this report.
5. **The analysed-file extension set is too narrow for a reachability question.** `.rake` files sit
   inside `paths:` and reference project constants; two redmine candidates and one conference-app
   candidate are pure artifacts of not reading them. A reachability report needs a *reference*
   corpus wider than its *analysis* corpus — reading a file for references is far cheaper than
   type-checking it.
6. **Widening `paths:` is not a mitigation** (stage 2, +1/−3/+2). Do not ship advice that says "add
   `config/` and the report gets better"; it does not, because declarations and references widen
   together.
7. **The value-constant tier stays out of any shipped report** until the cross-file seed carries
   `in_source_constants`. It is 38 / 89 / 0 candidates across the corpus with, by construction, no
   way to be right.

## Addendum 2026-08-15 — the shipped `rigor unused`, with the cannot-decide tier

The measurements above were taken with the throwaway probe. `rigor unused` (#347) and its
`cannot-decide` tier (#348) have since shipped, and the same three targets were re-run through the
real command.

**These numbers are not a continuation of the decay table above, and should not be read as one.**
The instrument changed in two ways that move the denominator: the reference index is now a dedicated
constant-node walk rather than a hook on the typing path, and ownership now excludes names known to
an environment built without the project's own `sig/`. Redmine's project-owned declaration count is
504 here against the probe's 697 for that reason. What the table shows is the shape of the shipped
report, not a further stage of the original funnel.

Run with no `--entry-point`, so roots come only from file-level references:

| target | declared | candidates | cannot decide | test-only | namespace-only |
| --- | ---: | ---: | ---: | ---: | ---: |
| redmine | 504 | 129 | 99 | 2 | 12 |
| mastodon | 1,497 | 278 | 118 | 454 | 8 |
| conference-app | 103 | 2 | 0 | 0 | 0 |

Three things worth recording.

**The cannot-decide tier carries real volume.** 99 rows on redmine and 118 on mastodon are
declarations that would otherwise have been asserted as unused, each now demoted with the reason
that demoted it. On redmine that is 43 % of what the report would otherwise have claimed.

**Mastodon's test-only bucket is inflated, and the inflation is diagnostic rather than alarming.**
454 declarations reachable only from test code is not a finding about mastodon; it is what a Rails
app looks like when route-derived roots are missing. Controllers and models are reached from routes
and the framework, neither of which #347 knows about — the specs are the only thing left referencing
them. The bucket should collapse when #349 lands, and its size is a usable before/after measure for
that slice.

**conference-app is the clean case**: 2 candidates out of 103 declarations, no undecidable rows. A
small app with a real `sig/` tree and few dynamic constructions is the shape the report handles best,
which is worth knowing when setting expectations in the manual.

## Addendum 2026-08-15 — #349, plugin-supplied route roots

Same command, same two Rails targets, same configs; the only change is that `rigor unused` now loads
the project's plugins and seeds the sweep with every published `:reachability_roots` fact, and
`rigor-rails-routes` publishes the controllers `config/routes.rb` dispatches to.

| target | metric | before #349 | after #349 |
| --- | --- | ---: | ---: |
| redmine | roots | 53 | 108 |
| redmine | candidates | 129 | **57** |
| redmine | cannot decide | 99 | 77 |
| redmine | test-only | 2 | 2 |
| mastodon | roots | 125 | 404 |
| mastodon | candidates | 278 | **45** |
| mastodon | cannot decide | 118 | 25 |
| mastodon | test-only | 454 | **186** |

−56 % of redmine's candidates and −84 % of mastodon's, from one root source. That is the same shape
the #345 stage-3 subtraction predicted (40 % / 62 % / 67 % with a regex extractor), and it lands
higher because a router-shaped reading reaches routes the regex could not.

Redmine's 57 survivors are the number the ADR-102 § Context adjudication was performed against, which
is a useful independent check on the extractor: the hand-audited funnel and the shipped one agree.

Mastodon's test-only bucket behaved as the note predicted — 454 → 186 — confirming the diagnosis that
its size was missing route roots rather than a finding about mastodon. The residue is dominated by
models and services, which is the next root source rather than a defect in this one.

### Over-supply check

An over-claiming root source silently hides real dead code, so the count of supplied roots naming
nothing the project declares is now part of the report output.

| target | roots supplied | matched no declaration |
| --- | ---: | ---: |
| redmine | 56 | 1 |
| mastodon | 288 | 0 |

Redmine's single unmatched root is `Rails::HealthController` (`get "/health" => "rails/health#show"`)
— a framework class, correctly named and correctly not project-owned.

Reading it the other way, 288 of mastodon's 309 declared `*Controller` classes are rooted. The 21 that
are not break down as: 11 abstract `*::BaseController` parents (reached through the superclass edge
from a rooted subclass, so not candidates); 3 Devise `Auth::*` and 3 Doorkeeper `OAuth::*` controllers,
whose `controllers:` remapping this slice deliberately does not model; `Admin::SettingsController`;
`Api::V1::Timelines::TopicController`, which the routes genuinely never name — i.e. a real candidate.

Three route shapes were found only by running this measurement, and each is pinned by a spec:
`module:` as an option on `resources` / `resource` (8 uses in mastodon's admin routes alone), a target
inherited from an enclosing `with_options to:`, and `only: []` with an action declared in the block.
Mastodon's `inflect.acronym` declarations are also read out of `config/initializers/inflections.rb`,
without which 19 emitted roots were spelled `Activitypub::…` for an `ActivityPub::…` class.

## Addendum 2026-08-16 — #350, root supply for the remaining plugins

Six plugins were surveyed against one rule: a plugin should contribute exactly those constants its
framework reaches by a name that **never appears as a constant reference in the source**. Two clear it,
four do not, and the four declines are the more consequential half — an over-supplying root source
hides real dead code silently, so publishing a discovered set ("every class under `app/workers`") is
strictly worse than publishing nothing.

| plugin | decision | reason |
| --- | --- | --- |
| `rigor-pundit` | roots | `authorize @post` reaches `PostPolicy`, a name written nowhere. |
| `rigor-factorybot` | **references**, `:test` role | `factory :user, class: "Admin::User"` is a string, but factories are test-tree code. |
| `rigor-sidekiq` | decline | `MyWorker.perform_async` is an ordinary constant reference. String-named workers in queue/cron config would qualify; not parsed yet. *(Superseded by [#367](https://github.com/rigortype/rigor/issues/367): the `class:` key of a schedule file is now read; the queue list is still declined.)* |
| `rigor-rspec`, `rigor-rspec-rails` | decline | Rooting spec references would strip the `:test` role and erase WD8's category outright. |
| `rigor-activejob`, `rigor-actionmailer` | decline | `perform_later` / `welcome` are ordinary constant references. |

### Measurement

`rigor unused --format json`, before and after, cwd = target. Redmine's committed config declares
neither plugin, so it is the control.

| target | metric | before | after |
| --- | --- | ---: | ---: |
| redmine | candidates / test-only / cannot-decide | 57 / 2 / 77 | 57 / 2 / 77 |
| mastodon | candidates / test-only / cannot-decide | 45 / 186 / 25 | 45 / **164** / 25 |
| gitlab | candidates / test-only / cannot-decide | 66 / 1794 / 427 | 66 / **1796** / **425** |

Mastodon (`rigor-pundit` in its committed plugin list) moved 22 policies out of *reachable only from
test code* into production-reachable — `UserPolicy`, `ReportPolicy`, `InvitePolicy` and 19 more, each
previously kept alive only by its own `spec/policies/` file. Roots rose 404 → 428. **No candidate
moved**, which is the point: the contribution corrected a mis-attribution rather than shrinking the
review queue by hiding rows.

GitLab is the FactoryBot target (`spec/factories/`, 249 entries; measured with `rigor-factorybot`
appended to its committed plugin list). Two classes moved out of *cannot decide* into *test-only* —
`SupplyChain::Slsa::ProvenanceStatement::{Builder,BuildMetadata}`, named by a factory `class:` and
otherwise only guessable. Again no candidate moved.

Redmine's numbers are byte-identical before and after. That is the expected result for a project using
neither gem, not a null measurement: the mechanism is pinned by
`spec/integration/plugins/reachability_contribution_plugin_spec.rb`, which drives both plugins through
the real protocol and fails if the plugin never loads, so "no change here" is a control rather than an
absence of signal.

### Over-supply check

| target | roots supplied | matched no declaration |
| --- | ---: | ---: |
| redmine | 56 | 1 (unchanged — `Rails::HealthController`) |
| mastodon | 312 (288 routes + 24 policies) | 0 |
| gitlab | 373 | 14 (unchanged — all from routes) |

Every pundit-supplied root matched a declaration, which is what the intersection in
`Pundit#prepare` buys: a derived policy name that names nothing is dropped before publication. The
supply is deliberately partial — 24 roots against 43 policy files in mastodon's `app/policies`,
because namespaced `Admin::*Policy` classes and non-controller call sites are not derived. Those
policies stay in the report, which is the correct failure direction.

`rigor-factorybot` does not move the roots counter at all, by construction: its contribution is a
reference, so it can move a class between the report's buckets but can never seed production
reachability.
