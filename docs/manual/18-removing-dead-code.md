# Removing dead code with `rigor unused`

This chapter is for the person handed an old codebase and asked what
can go. `rigor unused` turns "which of these 1,500 classes is dead?"
into a finite list of specific questions. It does not answer them.

The command reference — every flag, every output section — is in
[CLI reference](02-cli-reference.md#rigor-unused). This chapter is the
workflow around it.

**Before you start** you need a working `rigor check` setup: a config
file with `paths:`, and the plugins for your framework enabled. See
[Configuration](03-configuration.md) and [Using plugins](07-plugins.md).
`rigor unused` reads the same config and loads the same `plugins:`, and
the plugin half is not optional — the section on
[roots](#roots-are-the-lever) explains why a Rails app without
`rigor-rails-routes` produces a report that is mostly noise.

## What it can and cannot tell you

`rigor unused` answers one question exactly: **which project classes
and modules does no reachable code name?** That is not the same
question as "what is dead", and the gap between them is the whole
subject of this chapter.

On one mid-sized Rails application, every surviving candidate was
hand-checked against the whole repository: **4 of 57 were genuinely
dead.** The other 53 were live code reached by means the analysis
cannot see.

Treat that ratio as an order of magnitude, not a constant. It is one
adjudication of one codebase; your rate depends on how much of your
framework has plugin coverage. What generalises is the shape: most
rows will be live code, so the output is a review queue and not a work
list. That is also why this ships as its own command rather than a
`rigor check` diagnostic — see [ADR-102][adr-102].

Three limits are worth knowing before you plan any work:

- **Naming is not calling.** A class whose constant is named once and
  whose every method is dead counts as fully reachable. This is a
  constant-level report; unused *methods* are not reported at all.
- **It under-reports, by an unknown amount.** An over-claiming root
  source removes rows silently — see
  [watching for drift](#running-it-as-a-campaign). There is no recall
  figure, and no way to measure one short of adjudicating classes the
  report never showed you.
- **Value constants** (`TIMEOUT = 30`) are omitted entirely; they do
  not resolve across files, so every one would be a false row.
  **Reopened gem or stdlib classes** are never candidates — reopening
  `String` in an initializer declares it in your project, but it is
  not yours to call unused.

## The first run

```sh
rigor unused
```

It analyses the whole project every time; there is no incremental
mode, because reachability computed over a subset is not sound. Budget
roughly the cost of a full `rigor check`: about 14 seconds for 1,300
files, about 4 minutes for 11,000.

The summary tells you whether the rest of the report is worth reading:

```
Reachability
  declared (project-owned): 1497
  roots:                    428 (312 from plugins, 3 matched no declaration)
  reachable:                1417
  candidates:               45
  reachable only from tests: 164
  cannot decide:            25
  namespace-only (excluded): 10
```

`reachable`, `candidates`, `cannot decide` and `namespace-only`
partition `declared` — they sum to 1497. **`reachable only from tests`
is a subset of `reachable`**, not a fifth bucket, so do not add it in.

Read `roots` first. A root is a declaration something outside your code
reaches — an entry point, a route, a framework convention.
Reachability is computed *from* roots, so a thin root set inflates
everything below it. The pathological case is a Rails application with
`0 from plugins`: nothing in Ruby source names a controller, so every
controller you own appears dead. There is no published healthy ratio
to compare against; what you are checking is whether the number is
plausible for your framework, and `0 from plugins` on a framework app
never is.

## Getting the number down

Two things change the count. Only one of them helps.

### Roots are the lever

Wiring up root sources took one application's candidate list from 129
to 57, and another's from 278 to 45 — **56% and 84%**.

**Your plugins**, first and most of it. `rigor-rails-routes` reads
`config/routes.rb` statically and names every controller it dispatches
to, including routes written under a conditional; it follows
`draw(:admin)` into `config/routes/*.rb`. `rigor-pundit` publishes the
policies your `authorize` calls actually name. Mounted engines, and
Devise/Doorkeeper controller remappings, are not covered — those
controllers will still appear as candidates. If your framework has no
Rigor plugin at all, its entry points supply nothing, and that is a
gap in coverage rather than a finding about your code.

**Entry points you declare**, for anything no plugin reaches:

```sh
rigor unused --entry-point='lib/cli.rb' --entry-point='lib/workers/**/*.rb'
```

Repeatable. Each glob is matched against every declaration's path, and
roots every declaration in a matching file.

**File-level references**, free. Code that runs on load — an
initializer naming a class, a `.rake` task — roots what it names. This
happens whether or not those directories are in `paths:`, because
references are harvested from the whole project while declarations come
only from `paths:`.

### Widening `paths:` is not the lever

The obvious first move is to analyse more of the project. Measured on
three applications, adding `config/` to `paths:` moved the candidate
count by **+0.7%, −0.8% and +3.4%** — nothing, in two directions.

The reason follows from the asymmetry above: references already came
from the whole project, so widening `paths:` adds *declarations* to
explain without adding references that explain them. Analyse `config/`
if you want it type-checked. It will not shorten this list.

## Working the list

Four sections, needing four different decisions:

| Section | What it means | What to do |
| --- | --- | --- |
| **Reachable only from test code** | Live test, no production caller Rigor can see or suspect | Work these first |
| **Candidates** | Nothing reachable names it | Adjudicate — most are still live |
| **Cannot decide** | Something can name it at runtime | Read the reason; do not delete from here |
| **Namespace-only** | A module wrapping live code | Excluded from candidates; count only |

Work them in that order — which is not the order you *read* the
summary in, where `roots` comes first because it tells you whether to
trust the rest.

### Test-only rows first

Not because the section is smaller — in the sample above it is 164
rows against 45 candidates — but because each row carries its own
evidence. A class with a passing spec and no production caller is
either dead or reached by a mechanism worth writing down, and either
way you can settle it from the spec file. On one application this
section held 22 policy classes whose only remaining caller was
`spec/policies/`. Those 22 were not adjudicated, so treat the section
as high-signal rather than high-yield; the yield is unmeasured.

### Candidates: sort by how conventional the class is

A candidate row is its name and declaration site:

```
Candidates — nothing reachable references these (45)
    1  Api::V1::Timelines::TopicController   app/controllers/api/v1/timelines/topic_controller.rb:3
```

The 53 false positives in the adjudicated run fell into a few recurring
shapes, and 28 of them were the first one. Recognising these lets you
skip most of a list quickly:

- **Framework naming conventions** — a helper module paired to a
  controller by name, a Rails generator, a `ClassMethods` module
  auto-extended by `ActiveSupport::Concern`, a decorator a gem applies
  to a model by name, a join model reached through
  `has_many :speakers_talks`, or a custom validator derived from an
  option key (`validates :start_date, date: true` resolves the name
  `DateValidator`). Nothing writes the name; the framework derives it.
  Two of these clear whole clusters at once, so check them before
  working through rows one at a time: **`include_all_helpers` defaults
  to true**, so unless the app disables it every `app/helpers/*Helper`
  is live; and a decorator gem's convention covers `app/decorators`
  wholesale.
- **Named as a string in configuration** — a recurring-job schedule
  (`config/recurring.yml`, `config/schedule.yml`, a `sidekiq.yml`
  scheduler block), a queue definition, a class name in a settings
  file. The scheduler resolves it by name, so no Ruby code has to, and
  a scheduled job commonly has no `perform_later` call anywhere in the
  repository. Check that the file is actually loaded — a `Procfile` or
  deploy config passing `--recurring_schedule_file` is the confirming
  evidence.
- **Called from a view** — `app/views/**/*.erb` is not Ruby and is not
  analysed, so a helper used only from templates has no caller the
  report can see. Grep the view tree before believing any helper row.
- **Self-registering classes** — a class whose body calls a
  registration DSL (`add "link"`, `register :thing`). The evidence of
  use is inside the class, not outside it.
- **Published extension points** — a base class subclassed only from
  outside your repository. Dead from within, load-bearing without.
- **Scaffolding for a feature you never used** — `rails new` generates
  `ApplicationCable::Connection` and `ApplicationCable::Channel`
  whether or not you add a channel. If `app/channels` holds nothing
  else, the honest finding is that the feature is unused, not the
  class. Decide about the feature.

### Cannot decide: read the reason, do not delete

These were demoted because something can name the class at runtime —
out of `candidates`, or out of **reachable only from test code**. Each
row says what:

```
  1  Handlers::Alpha                     lib/handlers.rb:2
       constantize on an interpolated string (lib/dispatch.rb:14)
```

A row demoted out of the test-only section is the second kind, and it
is the one worth knowing about: a class your specs reference and a
data file also names — a job in `config/recurring.yml`, a class named
from a YAML setting — is not a dead production path, because the
configuration may well be what drives it. The test-only section makes
a claim about production, so a row Rigor holds evidence against
belongs here instead, with the file named.

`"Foo".constantize` names `Foo` exactly, so it counts as an ordinary
reference and never reaches this section. `"Foo::#{key}".constantize`
can only bound the namespace, so everything under `Foo` is demoted. A
class name appearing as a string in a `.yml`, `.json` or template file
demotes the same way — weaker evidence than a constant reference, and
neither proof of use nor grounds to call it dead.

A large section here is telling you that dynamic dispatch is
load-bearing in this codebase, which is the honest reason a deletion
campaign stops where it does.

## Before you delete

A candidate row is the start of a case. Confirm each of these:

1. **Search for spellings the report cannot match.** Do not re-grep
   the fully-qualified name — a row would not be in `candidates` if
   the FQN appeared anywhere the report reads. Grep instead for the
   forms it cannot: the snake_cased autoload path
   (`admin/reports_controller`), the demodulized leaf, any name
   assembled by interpolation, and the view tree.
2. **Check it is not reached by convention** — the shapes above.
3. **Check nothing outside the repository references it.** For a gem,
   a library, or an app with third-party extensions, "unused" means
   "unused by callers I can see", and your public API is exactly what
   you cannot see.
4. **Read the git history** — but check it is real first. A class
   added recently and never wired up is unfinished work rather than
   dead code. In a shallow clone, or one whose history is all
   dependency bumps, the "last change" date is an artifact and proves
   nothing; say so instead of quoting a bot commit as the file's age.
5. **Delete its tests with it.** A spec that must survive the class it
   tests is testing nothing.

**Empty is not the same as dead.** A module the framework includes
everywhere but which declares no methods is live by every measure this
report uses, and still worth deleting — as generator residue, not as
dead code. Say which of the two you found; they justify different
amounts of care from a reviewer.

### Making the case to someone else

The useful artifacts are the candidate row with its declaration site,
the result of step 1, and the date of the file's last substantive
change.

State the precision figure yourself rather than waiting to be asked. A
reviewer who knows the report is mostly false positives, and that you
checked this row by hand, has more reason to trust the specific claim —
not less. Be equally direct that the tool under-reports: it will not
have shown you everything.

## Running it as a campaign

**Re-run after configuring, not after deleting.** The list moves far
more when you add a root source than when you remove a class.

**Watch `matched no declaration`.** This counts plugin-supplied roots
naming something your project does not declare:

```
  roots:  428 (312 from plugins, 3 matched no declaration)
```

A few are normal — framework classes such as `Rails::HealthController`
are correctly named and correctly not yours. There is no threshold to
quote; what matters is the trend, because **an over-claiming root
source silently hides dead code**. Under-supply leaves rows on the list
where you can see them; over-supply removes them where you cannot.

**Expect drift in one direction.** New code adds candidates; new routes
and entry points remove them. If the count climbs over months with
nobody adding dead code, suspect a plugin stopped loading before you
suspect the codebase.

To track any of this you have to keep the numbers yourself — commit the
`--format json` output, or record the summary line. There is no
baseline file for this command.

### If your project ships generated RBS

Signature files both declare and reference, and only the references
count. `class Talk < ApplicationRecord` in `sig/` references
`ApplicationRecord`; the `Talk` it declares is not a reference to
`Talk`. If it were, every class with a generated signature would root
itself and the report would be empty of exactly the rows you want.

That is worth knowing because it was wrong until recently, and the
symptom was silent: on one application 48 of 101 roots came from `sig/`
and eleven rows never appeared. If you are on a release before this was
fixed ([issue #363][issue-363]), compare against a run with
`signature_paths:` emptied — a large gap between the two is the tell.

## Automating it

**Do not gate a build on this.** The command always exits 0 when it
runs, precisely so that it cannot become a check; the only non-zero
exit is a usage error, such as passing `--incremental`. A threshold on
the candidate count would fire on your own tooling as often as on your
code — the count climbing usually means a plugin stopped loading.

Running it as a **reporting** job is fine, and is the intended way to
notice the drift described above: run it on a schedule, publish the
JSON, and let a person read the trend.

[adr-102]: https://github.com/rigortype/rigor/blob/master/docs/adr/102-unused-code-reachability-report.md
[issue-363]: https://github.com/rigortype/rigor/issues/363
