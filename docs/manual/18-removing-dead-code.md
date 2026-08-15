# Removing dead code with `rigor unused`

This chapter is for the person who has been handed an old codebase and
asked what can go. `rigor unused` narrows "which of these 1,500 classes
is dead?" down to a list you can actually read. It does not tell you
what to delete, and the difference matters enough that the first
section is about nothing else.

The command reference — every flag, every output section — is in
[CLI reference](02-cli-reference.md#rigor-unused). This chapter is the
workflow around it.

## What it can and cannot tell you

`rigor unused` answers one question precisely: **which project classes
and modules can no reachable code name?** It answers a second question
only in part: which of those are actually dead.

The gap between the two is large and measured. On a mid-sized Rails
application, every surviving candidate was hand-checked against the
whole repository: **4 of 57 were genuinely dead — 7%.** The other 53
were live code the analysis could not see reaching.

That ratio is why the output is a review queue and not a work list. If
you take the list to your team as "here are 57 classes we can delete",
you will be wrong 53 times, and the next report you bring will not be
read. Take it as "here are 57 places worth ten minutes each" and it
holds up.

It is also why this is a separate command rather than a `rigor check`
diagnostic. A checker that is wrong 93% of the time trains people to
ignore it, which costs more than the feature returns. The reasoning is
recorded in [ADR-102][adr-102].

Two consequences for how you plan the work:

- **Budget adjudication time, not deletion time.** The expensive part
  is confirming a candidate, not removing it.
- **The list shrinks as you configure it, not as you delete.** Most of
  the first run's rows are missing knowledge, and the next section is
  about supplying it.

## The first run

Run it against the paths you already analyse:

```sh
rigor unused
```

The summary tells you the shape of the answer before you read a single
row:

```
Reachability
  declared (project-owned): 1497
  roots:                    428 (312 from plugins, 0 matched no declaration)
  reachable:                1417
  candidates:               45
  reachable only from tests: 164
  cannot decide:            25
  namespace-only (excluded): 10
```

Read it in this order:

**`roots`** first. A root is a declaration something outside the code
reaches — an entry point, a route, a framework convention. Reachability
is computed *from* roots, so if this number is small relative to your
application, everything downstream is inflated. A Rails app with zero
plugin-supplied roots is the pathological case: nothing references a
controller by name, so every controller you own looks dead.

**`candidates`** second — the rows claiming nothing reachable names
them.

**`reachable only from tests`** third, and do not skip it. These are
classes kept alive solely by their own specs: live test, dead
production path. On one application this section held 22 policy classes
whose only remaining caller was `spec/policies/`. That is often the
most actionable section in the report, because a class with a green
test suite and no production caller is dead code wearing a disguise.

**`cannot decide`** last. These are not candidates and not
confirmations — see [Working the list](#working-the-list).

## Getting the number down honestly

There is one lever that works and one that looks like it should.

### Roots are the lever

Supplying roots removed **40–67% of the candidate list** across three
applications. Nothing else came close. Roots come from three places:

**Your plugins.** `rigor unused` loads the same `plugins:` your
`rigor check` run uses. `rigor-rails-routes` reads `config/routes.rb`
statically and names every controller it dispatches to;
`rigor-pundit` publishes the policies your `authorize` calls actually
name. If your framework has no Rigor plugin, its entry points supply
no roots and its classes will sit in the candidate list — that is a
gap in coverage, not a finding about your code.

**Entry points you declare.** Anything the framework does not reach for
you:

```sh
rigor unused --entry-point='lib/cli.rb' --entry-point='lib/workers/**/*.rb'
```

Repeatable, matched against each declaration's path.

**File-level references.** Code that runs on load — an initializer
naming a class, a `.rake` task — roots what it names, without you
configuring anything.

### Widening `paths:` is not the lever

The obvious first instinct is to analyse more of the project. Measured
across three applications, adding `config/` to the analysed paths
changed the candidate count by **+1, −3, and +2**.

The reason is structural rather than incidental: declarations and
references are gated on the same file set, so widening it adds new
declarations to explain at the same rate it adds references that
explain them. It is still correct to analyse `config/` for other
reasons. It will not shorten this list.

## Working the list

The report separates four things rather than merging them, because they
need different decisions from you.

| Section | What it means | What to do |
| --- | --- | --- |
| **Candidates** | Nothing reachable names it | Adjudicate — most are still live |
| **Reachable only from test code** | Live test, no production caller | Usually the highest-value rows |
| **Cannot decide** | Something can name it at runtime | Read the reason; often genuinely undecidable |
| **Namespace-only** | A module wrapping live code | Excluded, counted only |

### Start with the test-only section

It is smaller, and its rows carry their own evidence: a class with a
passing spec and no production caller is either dead or reached by a
mechanism worth documenting. Either way you learn something. Deleting
one means deleting its spec too, which is usually the correct signal
that you found real dead weight.

### Read the reason on every `cannot decide` row

These were demoted because something can name the class at runtime, and
the report tells you what:

```
  1  Handlers::Alpha                     lib/handlers.rb:2
       constantize on an interpolated string (lib/dispatch.rb:14)
```

The distinction the report draws is worth understanding, because it
determines how much you should trust the row. `"Foo".constantize` names
`Foo` exactly, so it counts as an ordinary reference and `Foo` never
reaches this section. `"Foo::#{key}".constantize` can only bound the
namespace, so everything under `Foo` is demoted. A class name appearing
as a string in a `.yml`, `.json` or template file demotes the same way
— weaker evidence than a constant reference, and neither proof of use
nor grounds to call it dead.

A large `cannot decide` section is usually telling you something true
about the codebase: dynamic dispatch is load-bearing, and no static
tool will ever resolve it. That is worth writing down for whoever asks
why the deletion campaign stopped where it did.

### Candidates: sort by how conventional the class is

The 53 false positives in the hand-adjudicated run fell into a small
number of recurring shapes. Recognising them lets you skip most of a
list quickly:

- **Framework naming conventions** — a helper module paired to a
  controller by name, a Rails generator, a validator resolved from
  `validates ..., date: true`, a `ClassMethods` module auto-extended by
  `ActiveSupport::Concern`. Nothing writes the name; the framework
  derives it. This was 28 of the 53.
- **Self-registering classes** — a class whose body calls a
  registration DSL (`add "link"`, `register :thing`). The evidence of
  use is inside the class, not outside it.
- **Published extension points** — a base class subclassed only by
  out-of-tree plugins. Dead from inside the repository, load-bearing
  from outside. Deleting one breaks people you cannot see.
- **Scaffolding for a feature you never used.** `rails new` generates
  `ApplicationCable::Connection` and `ApplicationCable::Channel`
  whether or not you ever add a channel. The framework reaches them by
  convention, so they are not dead in the sense the report means — but
  if `app/channels` contains nothing else, the honest finding is not
  "this class is unused", it is "this whole feature is unused". Decide
  about the feature, not the class.

Anything not matching a shape like these deserves the ten minutes.

## Before you delete

A candidate row is the *start* of a case, not the case. Confirm each of
these before proposing a deletion:

1. **Grep the whole repository for the name** — including tests,
   fixtures, `.rake` tasks, templates, locale files and `config/`. The
   report already reads these, but a plain grep catches spellings it
   cannot (a snake_cased autoload path, a name split across
   interpolation).
2. **Check it is not reached by convention.** Does the framework derive
   this name from another one? The shapes above are the common cases.
3. **Check nothing outside the repository subclasses or references
   it.** For a library, a gem, or an app with plugins, "unused" means
   "unused by callers I can see", and your public API is exactly the
   part you cannot see.
4. **Check the git history.** A class added recently and never wired up
   is a different situation from one that lost its last caller three
   years ago — the first may be unfinished work.
5. **Delete the tests with it.** If a spec has to be kept for a class
   you are deleting, one of the two is wrong.

### Making the case to someone else

If you need approval rather than just a green build, the useful
artifacts are:

- The candidate row with its declaration site, from `--format json`.
- The result of step 1 — "the declaration is the only occurrence in the
  repository, tests included" is the sentence that ends most
  arguments.
- The date of the last substantive change to the file.

State the report's precision alongside the finding. A reviewer who
knows the tool is right 7% of the time and that you checked the other
93% will trust the specific claim more, not less.

## Running it as a campaign

**Re-run after configuring, not after deleting.** The list moves far
more when you add a root source than when you remove a class.

**Watch `matched no declaration`.** The summary reports how many
plugin-supplied roots named something your project does not declare:

```
  roots:  428 (312 from plugins, 0 matched no declaration)
```

A small number is normal — framework classes like
`Rails::HealthController` are correctly named and correctly not yours.
A number climbing over time means a root source has drifted out of step
with the code, and that matters more than it looks: **an over-claiming
root source silently hides dead code.** Under-supply leaves rows on the
list where you can see them; over-supply removes them where you cannot.

**Expect the report to go stale in one direction.** Adding code adds
candidates; adding routes and entry points removes them. If the count
drifts up over months without anyone adding dead code, look at whether
a plugin stopped loading before you look at the codebase.

**Sanity-check the root count against a run with no signatures.** If
your project ships generated RBS under `signature_paths:`, compare:

```sh
rigor unused                       # your normal run
rigor unused --config no-sig.yml   # the same config with signature_paths: []
```

A large gap means signature files are supplying most of your roots. On
one application this was 48 of 101 roots, hiding seven candidates —
a class's own generated signature is currently counted as a reference
to itself ([issue #363][issue-363]). Until that is fixed, the
signature-free run is the more honest number on a project with
generated RBS.

**`--incremental` is refused.** Reachability is only sound over a
whole-project run — an incremental pass would report classes as unused
merely because the files referencing them were served from cache. The
command exits with an error rather than silently doing the slow thing.

## What is deliberately not reported

- **Value constants** (`TIMEOUT = 30`) are omitted entirely. They do not
  resolve across files, so every one of them would be a false row.
- **Unused *methods*** are not reported. The constant tier is the
  shipped scope; methods carry the same problems at roughly ten times
  the volume and need an API-boundary definition first.
- **Reopened gem or stdlib classes** are never candidates. Reopening
  `String` in an initializer declares it in your project, but it is not
  yours to call unused.

[adr-102]: https://github.com/rigortype/rigor/blob/master/docs/adr/102-unused-code-reachability-report.md
[issue-363]: https://github.com/rigortype/rigor/issues/363
