# Effect labels — what your code *does*

Rigor's usual question is what a method **returns**. Effect labels answer the
other one: what it **does**. `Reports::Nightly#perform` returns a boolean; that
it opens a socket, reads the clock and writes to the database is a different
fact about it, and usually the one a reviewer wants when a pull request touches
a job.

The command reference — every flag, every subcommand — is in
[CLI reference](02-cli-reference.md#rigor-effects), and every configuration key
is in [Configuration § Effect labels](03-configuration.md#effect-labels). This
chapter is the workflow around them: what a label is, what the output really
looks like on a real application, and the order to adopt the three surfaces in.

**Almost none of this tells you that you were wrong.** The report and the
snapshot are observations: they say what your code does, not that doing it was a
mistake — which is why effect labels ship as their own command rather than as
`rigor check` findings. `rigor effects check` does fail a build, but on drift
from a record you committed, never on a judgment Rigor made. The one place Rigor
judges is the last section of this chapter: the bounds you declare yourself.

## Three surfaces, one collection pass

Rigor collects effects once per run and then shows them three ways. Readers
confuse them constantly, so it is worth pinning down before anything else:

| Surface | Command | Answers | Can it fail? |
| --- | --- | --- | --- |
| **The report** | `rigor effects` | "What does every method do, right now?" | Never — always exits 0 |
| **The snapshot** | `rigor effects update` / `check` / `diff` / `explain` | "What changed since we last agreed?" | `check` exits 1 on **any** drift |
| **Declared bounds** | `effects.envelopes:` in `.rigor.yml`, `%a{pure}` / `%a{rigor:v1:effect …}` in signatures | "Did this method's own code exceed what we said it may do?" | A `rigor check` diagnostic, on **proven** labels only |

The report is for reading. The snapshot is for reviewing — it is to effects what
`db/schema.rb` is to your schema: a generated file you commit, whose *diff* is
the artefact. The declared bounds are where you assert a contract about code
Rigor read, and the only place effects behave like the rest of Rigor.

The two failing surfaces answer different questions, and the difference decides
which one your policy belongs in:

| If your policy is… | Write it as | Because |
| --- | --- | --- |
| "this method does nothing but compute" | a declared bound | `mutate.*`, `io.fs.*`, `nondet.*`, `global.*` and `exit` are proven from your own code, so a bound on them fires |
| "this layer must not touch the database / the cache / the mailer / the queue" | a committed snapshot + `rigor effects check` | those labels come from a plugin modelling a framework Rigor did not read, so no bound can fire on them — see [What a bound can and cannot see](#what-a-bound-can-and-cannot-see) |

Adopt them in that order. Each one is useful without the next.

## The label vocabulary

A label is a dot-path of lowercase segments: `io`, `io.net.http`, `nondet.time`.
A bound that names a label admits everything **under** it and nothing above it —
`io` covers `io.db.read`, `io.db.read` does not cover `io.db`. Matching is over
whole segments, so `io` never covers `iota`.

This is the whole shipped vocabulary:

| Root | Labels | Means |
| --- | --- | --- |
| `io` | `io`, `io.db`, `io.db.read`, `io.db.write`, `io.db.transaction`, `io.fs`, `io.fs.read`, `io.fs.write`, `io.net`, `io.net.http`, `io.input`, `io.output`, `io.output.stdout`, `io.output.stderr`, `io.output.buffer`, `io.output.header`, `io.ipc`, `io.process`, `io.signal` | Talks to something outside the process — a file, a socket, a database, a terminal, a subprocess |
| `mutate` | `mutate`, `mutate.local`, `mutate.self`, `mutate.instance`, `mutate.static` | Changes state in place: an object the frame allocated (`local`), the receiver's own state (`self`), some other object (`instance`), or class-level state (`static`) |
| `nondet` | `nondet`, `nondet.random`, `nondet.time` | Reads something that differs between two identical runs |
| `global` | `global.read`, `global.write` | Process-wide state — `ENV`, `$stdout`, a class variable |
| `exit` | `exit` | Can end the process (`exit`, `abort`) |
| `ffi` | `ffi` | Calls out through a foreign-function interface |
| meaning | `telemetry`, `email.send`, `job.enqueue`, `cache.read`, `cache.write` | Application-level meaning rather than transport — what a policy actually names |
| `failure` | `failure`, `failure.environment`, `failure.input`, `failure.resource` | Registered so a policy written for [Steins](https://github.com/rigortype/steins), the sibling PHP analyzer, parses here. Rigor never produces one; a bound naming one is satisfied vacuously |

Two things to internalise now, because everything below depends on them:

- **`mutate.local` is free.** Mutating an object the method itself allocated and
  never let out is not an effect anybody bounds, and every envelope tolerates
  it. A method whose only label is `mutate.local` is a pure method.
- **Plugins add roots.** `rails.i18n.translate`, `rails.session.write`,
  `rails.flash.write` and the rest of `rails.*` come from the Rails plugins, not
  from the shipped file. Your own project can open any root it likes with
  [`effects.labels:`](03-configuration.md#effect-labels).

Your installed Rigor can print all of this, including whatever your plugins and
your own `effects.labels:` opened:

```sh
rigor effects --list-labels
```

It analyses nothing, so it is instant, and it is the answer to "what may I write
in `effects.envelopes:`" — a question four configuration keys and two annotation
forms all ask of you.

The full grammar, the subsumption rules and the registry's evolution policy are
normative in the effect-labels specification, which the gem does not ship:
<https://rigor.typedduck.fail/type-specification/effect-labels/>.

## Turning it on

One line in `.rigor.yml`:

```yaml
effects: {}
```

The *presence* of the block is the switch; the empty hash means "every sub-key
at its default". Nothing else turns collection on — in particular an
`%a{pure}` annotation in your signatures does not, because one line in one file
must not make every run of the project more expensive. A project with
annotations and no block gets told so, once per run:

```
sig/slug.rbs:2:1: info: Effect annotations (`%a{pure}` / `%a{rigor:v1:effect …}`) are present in your project's signatures, but `.rigor.yml` carries no `effects:` block, so effect collection never runs and nothing checks them — they are documentation, not a contract. Add `effects: {}` to have Rigor prove what your methods do and check these bounds against it (ADR-103); an annotation alone never turns collection on, because that would make one line in one signature file more expensive for every run of the project.
```

From **v0.4.0** collection is the default: a config with no `effects:` key at
all behaves as `effects: {}`, and `effects: false` is how you opt out. On the
`0.3.x` line you can preview that with
`bleeding_edge: [effects-on-by-default]`.

One exception to all of this: `rigor effects` — the bare report — runs under an
implicit empty block whether or not you configured one, so you can look before
you commit to anything.

## The report

```sh
rigor effects
```

Set your expectations before you run it. On [Redmine](https://www.redmine.org/)
— 347 analysed files across `app` and `lib`, six Rails plugins, no signatures of
its own — the report is:

| | count | share |
| --- | --- | --- |
| units analysed | 4,683 | |
| rows printed by default | 2,730 | 58% of units |
| rows omitted, because they say nothing at all | 1,953 | 42% |
| lines on stdout | 2,733 | (the rows, plus a three-line footer) |
| printed rows ending in ` …?` | 2,468 | **90% of rows** |
| lines under `--full --why` | 34,680 | |

**Ninety percent hedged is the normal, healthy state of a Rails application**,
not a sign that something is broken. Rails resolves an enormous amount at
runtime, and Rigor reports what it proved rather than what it feared. If you
were expecting an exhaustive answer for every method, recalibrate here rather
than at the end of the chapter.

The report closes with a footer, and it counts the two lanes apart on purpose:

```
──
2730 of 4683 units printed; 1953 omitted (--full)
2183 carry a proven label · 1555 carry a declared (≤) one · 262 are exhaustive
```

Those two numbers have different powers, and the rest of this chapter is about
the difference. A **proven** label can fail a build. A **declared** one cannot —
it is a claim by a plugin about a framework Rigor never read, and the snapshot
is what enforces it.

### Reading a row

```
IssuesController#create: [global.read, io, mutate.instance, mutate.local, mutate.self, mutate.static] ≤ [email.send, job.enqueue, mutate, rails.flash.write, rails.i18n.translate, rails.response.write] …? (21 reasons, --why)
```

Four fields, and they answer four different questions:

1. **The key** — `Owner#instance_method` or `Owner.singleton_method`. Rows are
   sorted by it.
2. **The proven list** — what Rigor *established*, following your call graph
   transitively. `IssuesController#create` reads a class variable somewhere
   below it, writes an ivar, writes class-level state, and mutates objects of
   its own. This is the only lane a diagnostic will ever read.
3. **The `≤` declared lane** — what a source Rigor trusts, but did not read,
   *claims*. It is a claim, never a proof, and it is printed apart from the
   proven labels for exactly that reason. On a framework application this is
   overwhelmingly your **plugins** speaking: `rails.flash.write` and
   `rails.i18n.translate` above are Action Pack's and rails-i18n's rows, not
   anything you wrote. Your own
   [`effects.attribution:`](03-configuration.md#effect-labels) table lands in the
   same lane, and on most projects contributes far less than the plugins do.
   Declared labels follow call edges just as proven ones do, so a controller two
   hops above an attributed gem call carries the claim rather than a shrug. A
   row you wrote yourself leaves a `plugin-attribution (Owner.method)` reason
   line naming the call; a row a bundled plugin contributed does not, because a
   trusted row discharges its own taint.
4. **` …?`** — "these effects, and **possibly more**". Some call could not be
   resolved, and the count says how many kinds. `--why` expands them under the
   row, along with the plugin row behind each declared label:

   ```
   IssuesController#create: … …?
       dynamic-receiver (inferred_return_untyped)
       template-not-analysed (ActionController::Base#render)
       plugin:ActionController::Base#redirect_to → [mutate.self, rails.response.write]
   ```

   They are collapsed by default because on Redmine they are 30,000 of the
   34,680 lines a full report prints, and they answer a question you ask about
   one row after having read many.

Two kinds of row are **omitted** by default:

- a method that proves nothing beyond `mutate.local` and claims nothing — the
  reading of `%a{pure}`;
- a method with no label in either lane, which exists only to record that
  something below it was unresolved. That is 1,953 rows on Redmine, and the
  footer counts them.

`--full` prints both. But the first group is worth asking for by name:

```sh
rigor effects --pure
```

436 methods on Redmine, and they are your `%a{pure}` candidates — the on-ramp to
the last section of this chapter.

### Asking it a question

**By label.** The question this chapter opens with, in one command:

```sh
$ rigor effects --label io.net
Redmine::IMAP.check: [exit, global.read, io, io.fs.read, io.fs.write, io.net, …] ≤ [email.send, job.enqueue, …] …? (121 reasons, --why)
Redmine::POP3.check: …
WebhookEndpointValidator#validate_each: …
──
5 of 4683 units printed; 4678 not selected
```

`--label` matches a label and everything under it — `--label io` selects the
`io.net` rows above and the `io.fs.read` ones too — and it looks in **both**
lanes, because "what talks to the network" is a question about your code rather
than about which lane happens to know it. The row's own rendering keeps the two
apart.

**By path.**

```
$ rigor effects app/controllers/issues_controller.rb
rigor: showing 20 of 4683 units, selected by app/controllers/issues_controller.rb;
       a path narrows the printing and not the analysis, so every label is the one
       the whole-project run reports
IssuesController#create: [global.read, io, mutate.instance, mutate.local, mutate.self, mutate.static] ≤ [email.send, job.enqueue, …] …?
```

It is a **view**, not a scope. Rigor still analyses your configured `paths:`, so
the twenty rows it prints are the same twenty lines the whole-project run
prints. That costs a full analysis — the note on stderr is there so you know
what you paid for and what you got — and it is the only honest way to do it: an
effect summary is transitive, so analysing less would not filter this report, it
would lower every answer in it. A path that names no method says so rather than
printing an empty report.

**By count.** `--limit N` prints the first N rows and the footer says how many
it cut.

And `grep`, `sort` and `--format=json` piped into `jq` all still work — the text
is stable and sorted, the JSON payload carries the same totals the footer
prints, and the path note goes to stderr so a redirect gets the report alone.

## Direct and transitive

The same method key appears in two places with two different answers, and this
is the single idea in the feature most likely to trip you up. From one
`rigor effects update` on Redmine:

```yaml
methods:
  "IssuesController#create":
    effects: []
    declared: ["mutate", "mutate.self", "rails.flash.write", "rails.response.write"]
    exhaustive: false

reach:
  "IssuesController#create":
    effects: ["global.read", "mutate.local", "mutate.self", "mutate.static"]
    declared: ["mutate", "rails.flash.write", "rails.i18n.translate", "rails.response.write"]
    exhaustive: false
```

- `methods:` is the **direct** summary — what this method's own body does,
  including block literals and catalogued calls, but *not* what the project
  methods it calls do. `effects: []` says the controller action's own lines
  perform nothing; everything happens below it.
- `reach:` is the **transitive** footprint, and is identical to what
  `rigor effects` printed for that method.

The split is deliberate. A direct entry moves only when its own lines change,
so its diff is attributable to the pull request that caused it; a transitive
entry is the blast radius, and is where a leaf change is supposed to fan out.
`rigor effects` shows you the transitive number because that is the one you want
when *reading*; the snapshot records both because they fail differently when
reviewing.

## The snapshot

```sh
rigor effects update
```

```
rigor: wrote .rigor-effects.yml (1529 method(s), 0 reach entries)
rigor: note — `effects.snapshot.reach:` is empty, so the snapshot records `methods:` only (presets registered in this project: rails, rails-channels, rails-controllers, rails-jobs, rails-mailers).
```

The note lists the preset names *your* plugins registered, so the fix is the
line it already printed: put one of them in `effects.snapshot.reach:`. A project
whose plugins register none is told that instead.

Commit the file. Its header pins the Rigor version, the vocabulary version and a
digest of your `effects:` block, so an upgrade or a policy edit shows up as a
*regeneration event* rather than as a silent reinterpretation:

```yaml
# .rigor-effects.yml — generated by `rigor effects update`. Commit it; review its diff.
schema: 2
rigor: "0.3.5"
vocabulary: 1
config_digest: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
methods:
  "Change#init_path":
    effects: ["mutate.self"]
```

Two notes on reading the file:

- **`unresolved:` is a count, not a list.** It says how many calls the analyzer
  could not follow, which is why `exhaustive:` is false. The causes themselves
  are not recorded — they are inference-quality metadata that churns on Rigor
  upgrades and on unrelated edits — so ask for them when you need them:
  `rigor effects explain` names them, including for an `exhaustive → not` row.
  The lines a reviewer reads are `effects:` and `declared:`.
- Trivial and synthesised entries are left out, as in the report. `--full`
  records everything, and produces a much larger and much noisier file.

### `reach:` and entry-point presets

**It starts empty, and that is deliberate.** Rigor could guess — on a Rails
application with `rigor-railties` loaded, `reach: [rails]` is almost certainly
what you want — but a snapshot is a record you agree to and then review the diff
of, and one whose contents changed because your plugin list changed would be a
worse artefact than one you configured. So `rigor effects update` writes the
direct half, names the presets your plugins actually registered, and leaves the
same hint in the file:

```
# `reach:` is empty. It records the TRANSITIVE footprint at your entry points —
# what a controller action or a job causes, rather than what its own body does …
```


Out of the box the snapshot records **no `reach:` table at all** — that is what
the `0 reach entries` note above is telling you. The framing question the
feature is usually sold on ("which controllers reach the network, which jobs
write") needs you to name the entry points:

```yaml
effects:
  snapshot:
    reach: [rails-controllers]
```

Each entry is either a project-relative glob (`**` is the only way across a
directory boundary) or the name of a **preset** a plugin registered. On Redmine
that stanza takes the snapshot from 0 to 482 reach entries.

A preset name is registered by the plugin that models the framework, so which
names exist depends on which plugins you listed:

| Preset | Registered by | Covers |
| --- | --- | --- |
| `rails` | `rigor-railties` | `app/controllers/**`, `app/jobs/**`, `app/mailers/**`, `app/channels/**` |
| `rails-controllers` | `rigor-actionpack` | `app/controllers/**/*.rb` |
| `rails-jobs` | `rigor-activejob` | `app/jobs/**/*.rb` |
| `rails-mailers` | `rigor-actionmailer` | `app/mailers/**/*.rb` |
| `rails-channels` | `rigor-actioncable` | `app/channels/**/*.rb` |

`reach: [rails]` is the one you want on a Rails app — but it needs
`rigor-railties` in `plugins:`, and naming a preset nothing registered is an
error when the snapshot is built rather than when the config loads (the plugins
that register presets load *from* that config). If you get that error, the plugin
list is what to fix.

## The review loop

This is the part that pays. Someone adds an audit-log write to a model:

```rb
  def init_path
    self.path ||= ""
    File.open(Rails.root.join("log", "change_audit.log"), "a") do |f|
      f.puts("#{Time.now.utc.iso8601} #{changeset_id} #{path}")
    end
  end
```

CI runs `rigor effects check` and fails, exit 1:

```
Effect drift against .rigor-effects.yml:

methods:
  Change#init_path  + io.fs.write  (app/models/change.rb:41)
  Change#init_path  + nondet.time  (app/models/change.rb:41)
  Change#init_path  exhaustive → not  (app/models/change.rb:41)

Run `rigor effects explain` to see what caused this, and `rigor effects update` to accept it.
```

`+ label` and `- label` are the proven lane; `≤+` / `≤-` the declared one;
`materialised` means a declared label became proven; `exhaustive → not` means
someone introduced a call Rigor cannot follow; `+symbol` / `-symbol` are methods
that appeared or vanished, and a rename is one of each.

The parenthetical is where the method is defined — the file, and the `def`'s own
line when the file has one. A method defined by a reopening spans several files
and the row names them all; a `-symbol` row carries no position, because a method
this run no longer sees is one it cannot locate.

Before regenerating, ask why:

```sh
rigor effects explain
```

```
methods:
  Change#init_path [io.fs.write] ← catalogue:File#puts
  Change#init_path [nondet.time] ← catalogue:Time.now
```

`--symbol KEY` explains one unit instead of the changed ones, and prints its
reach path as well:

```
$ rigor effects explain --symbol "Change#init_path"
reach:
  Change#init_path → File#puts [io.fs.write]
  Change#init_path → receiver-mutation [mutate.self]
  Change#init_path → Time.now [nondet.time]
methods:
  Change#init_path [io.fs.write] ← catalogue:File#puts
  Change#init_path [mutate.self] ← construct:receiver-mutation
  Change#init_path [nondet.time] ← catalogue:Time.now
```

Then `rigor effects update` and commit the regenerated file alongside the code
change. **Intent is expressed by committing the snapshot**, not by annotating
the code: the reviewer reads a three-line diff next to the change that caused it
and either nods or pushes back. A bundle update that moves effects with no code
diff of its own goes through exactly the same gate, and is the case most worth
seeing.

`rigor effects diff` prints the identical comparison and always exits 0 — use it
locally, or in a reporting job you do not want to gate.

## In CI

Add one step to [the Rigor job](11-ci.md). It is a separate step from
`rigor check` because it answers a separate question and fails for separate
reasons:

```yaml
# .github/workflows/rigor.yml
      - run: gem install rigortype
      - run: rigor check
      - run: rigor effects check
```

Exit codes, all verified unpiped:

| Situation | `effects check` |
| --- | --- |
| Snapshot matches | `0` |
| Any drift under `gate: symmetric` (the default) | `1` |
| Growth only, under `gate: additions` | `1` on additions, `0` on removals |
| Difference confined to `effects.tolerated:` labels | `0`, printed under a `tolerated:` heading — `--strict-tolerated` makes it `1` |
| `.rigor-effects.yml` missing from the checkout | `1`, under a `snapshot:` heading telling you to run `rigor effects update` |

That last row is the one that saves you: someone who edits code and forgets to
regenerate the snapshot, and someone who never committed one, both fail the same
way.

**Reviewing against the base branch.** `--baseline` compares against a file
other than the configured one, which is how a bot reports "what this branch
changes" without regard to how stale `master` is:

```sh
rigor effects diff --baseline <(git show origin/main:.rigor-effects.yml)
```

`diff` never gates, so this is safe as a comment-posting step; swap in `check`
if you want it to fail. `--format=json` is accepted by every subcommand if you
would rather post structured output.

**`--no-tolerated-effects`** re-judges as if `effects.tolerated:` were empty. It
is the audit switch for your own policy — worth a scheduled non-gating job, so
that what you decided to stop looking at is still visible once a week. The run
itself is identical either way, so it never costs a re-analysis.

## Declaring what a method may do

Everything so far observes. This section asserts — and is the only part of the
feature that produces a `rigor check` diagnostic. Do it last, once the report
has told you what your code actually does.

### Envelopes by convention

The cheapest bound needs no signatures at all. One stanza bounds a whole
architectural layer:

```yaml
effects:
  envelopes:
    - match: "app/helpers/**/*.rb"    # a helper builds strings
      effect: []
```

Each stanza names exactly one of `match:` (a path glob over the files a class is
defined in) or `namespace:` (a constant glob), plus `effect:` — the labels those
classes may perform, `[]` for pure. Nearest wins: a per-method annotation beats
a class-level one, which beats a stanza; among stanzas the first match wins.

A method that exceeds its bound gets one diagnostic per (method, label) pair, at
its `def`, naming the route:

```
app/helpers/application_helper.rb:59:1: warning: Method ApplicationHelper#link_to_principal performs io.fs.read (Dir.glob via IconsHelper#principal_icon → IconsHelper#sprite_icon → IconsHelper#sprite_source → Redmine::Themes::Helper#current_theme → Redmine::Themes.theme → Redmine::Themes.themes → Redmine::Themes.scan_themes), but is declared effect: [] at .rigor.yml effects.envelopes[0], so io.fs.read exceeds the envelope. [effect.envelope-exceeded]
```

**Budget for a big first number.** That one stanza, on Redmine, is **343
warnings across 18 files** — 91 `mutate.self`, 86 `mutate.static`, 83
`io.fs.read`, 38 `mutate.instance`, 16 `global.read`, 13 `io.output.stderr`,
13 `exit`, 3 `nondet.time`.

That is not a failure of the stanza — it is the layer telling you what it really
does, and a helper reaching a theme scanner eight hops down is a genuine
finding. But 343 is not a work list. Work down in this order:

1. **Read before you bound.** `rigor effects app/helpers` (or the whole report,
   filtered) shows you the same facts without any diagnostics. Write the stanza
   you mean rather than the aspirational one.
2. **Discharge whole categories with `tolerated:`.** Adding
   `tolerated: [mutate.self]` takes the 343 to **252** — every warning whose
   origin was a receiver mutation, and nothing else.
3. **Narrow the stanza**, or carve out the deliberate exception with a tighter
   envelope on the one method. `except:` does not exist and is not needed:
   nearest wins.

Discharge works **per origin**, not per label. `Logger#info` carries `io` and
`telemetry` together, so `tolerated: [telemetry]` frees the `io` that came with
the logging and leaves an `io.fs.read` from a `File.read` two lines down exactly
where it was. An added label is discharged only when every origin that
introduced it is discharged.

### Annotations on one method

Where a stanza is too coarse, bound one method. Two annotations do it —
`%a{pure}`, rbs' own purity annotation, read as "nothing at all", and
`%a{rigor:v1:effect <labels>}`, a comma-separated list of bare labels the method
may not exceed. Both attach to a method or to a `class` / `module`, where they
distribute to that class's own methods. Full syntax is in
[RBS::Extended annotations](16-rbs-extended-annotations.md) § *Effect
envelopes*; two things that surprise people belong here instead:

- **Hanging an envelope on one method in `.rbs` costs you its whole signature.**
  RBS has no way to annotate a method without declaring it, so you end up
  writing `def init_path: () -> untyped` purely to carry the annotation. The
  rbs-inline form (`# @rbs %a{pure}` above the `def`, in the `.rb` file) does
  not have that problem, and is the better lane when the bound is all you want.
- **A declared label never makes a diagnostic fire.** A method whose report row
  reads `[] ≤ [global.read, rails.i18n.translate]` passes `%a{pure}` in silence,
  because the `≤` lane is a claim and a claim must never manufacture a finding.
  Correct, and thoroughly counter-intuitive at the point of use — if you
  annotate a method and nothing happens, check which lane its labels are in.

A misspelled label makes the **whole** annotation read as unbounded, so a typo
can never manufacture a finding either. Where the spelling is evidently meant to
be a label, Rigor says so:

```
sig/slug.rbs:2:1: info: Effect envelope on Slug#load names io.bd.read, which is not a known effect label (did you mean io.db.read?); the annotation now bounds nothing.
```

### `attribution:` for gems nobody has written a plugin for

```yaml
effects:
  attribution:
    "Acme::Http.get": [io.net.http]
    "Acme::Metrics.count": [telemetry]
```

Keys are method keys — `Owner#instance_method` or `Owner.singleton_method`, and
anything else is a load error. The labels land in the **declared** lane, never
the proven one, so an attribution can never make a diagnostic fire; the call
still counts as unresolved, because you told Rigor what that code does and Rigor
did not read it.

Check whether a plugin already covers the gem before writing rows by hand — on a
framework application the plugins supply most of the declared lane, and a table
that duplicates them is a table you have to maintain.

### What a bound can and cannot see

A bound is checked against the method's **proven** labels — the ones Rigor got by
reading code. It is never checked against the `≤` lane, and on a Rails
application that distinction decides almost everything.

Take a serializer under a `effect: []` stanza that ends up calling
`UserRole.create!`:

```
app/serializers/rest/v1/instance_serializer.rb:89:1: warning: Method
  REST::V1::InstanceSerializer#invites_enabled performs mutate.self
  (receiver-mutation via UserRole.everyone → UserRole.create! → UserRole#set_position),
  but is declared effect: [] at .rigor.yml effects.envelopes[0], so mutate.self
  exceeds the envelope. [effect.envelope-exceeded]
```

Rigor walked *through* the database write and reported the ivar assignment beyond
it. The row for that method says `≤ [io.db.read, io.db.write]`, so the write is
not hidden — it is in the lane a bound may not read, because `io.db.write` there
is what `rigor-activerecord` says `create!` does, not something Rigor saw. A
claim about code the analyzer never read must not be able to fail your build; if
it could, every plugin upgrade would be a build risk.

So on a Rails application:

- **`mutate.*`, `io.fs.*`, `io.net`, `nondet.*`, `global.*`, `exit`** are proven
  from your own code. A bound on these fires.
- **`io.db.*`, `cache.*`, `telemetry`, `email.send`, `job.enqueue`, every
  `rails.*`**, and anything you write in `effects.attribution:`, are declared. A
  bound naming them is satisfied vacuously.

**The enforcement path for the second group is the snapshot.** `rigor effects
check` diffs both lanes and marks a declared-lane addition with `≤+`:

```
reach:
  IssuesController#index  + io.net
  IssuesController#index  ≤+ io.db.write
```

That is how you enforce "the issue list must not start writing to the database":
commit the snapshot, review the diff, and let `rigor effects check` fail the
build when a `≤+` appears where you did not want one. It is a ratchet on
observed state rather than a declared policy — which is why `effects.snapshot.gate`
exists, and why this chapter puts the snapshot before this section.

The rule and the evidence behind it are
[ADR-103](../adr/103-effect-labels.md) § WD17.

## The diagnostics

Four rules. Three of them need an `effects:` block; the fourth exists to tell
you that you have not written one. The default text output does not print rule
IDs — `--format json` carries the `rule` field, and `rigor explain <rule>`
prints the catalogue entry for any of them.

| Rule | Fires when | Severity |
| --- | --- | --- |
| [`effect.envelope-exceeded`](04-diagnostics.md#rule-effect-envelope-exceeded) | A method's proven labels are not covered by the envelope declared on it, on its class, or by a stanza | `warning` |
| [`effect.liskov-widened`](04-diagnostics.md#rule-effect-liskov-widened) | An override escapes the envelope written on the method it overrides — an implementation may be purer than the bound it inherits, never less pure | `warning` |
| [`effect.unknown-label`](04-diagnostics.md#rule-effect-unknown-label) | A declaration names a label the registry does not know, so the whole tag reads as unbounded | `info` |
| [`effect.annotations-unchecked`](04-diagnostics.md#rule-effect-annotations-unchecked) | Your signatures carry envelopes but `.rigor.yml` has no `effects:` block | `info` |

They take `disable:` and `severity_overrides:` by ID like any other rule
([Diagnostics](04-diagnostics.md)). `# rigor:disable` comments are not read out
of `.rbs` or `.rigor.yml`, so for a declaration site use `disable:` or the
baseline. Setting `effects.check: false` keeps the report and the snapshot while
silencing the first three.

Unproven effects never fire any of them. "Possibly more" is not evidence, and a
check that fired on a shrug would teach you to route around it. Nor does a
declared (`≤`) label fire one — see
[What a bound can and cannot see](#what-a-bound-can-and-cannot-see) for which
labels that rules out and where to enforce them instead.
